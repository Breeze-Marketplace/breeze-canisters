import Array "mo:core/Array";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Set "mo:core/Set";

/// Core's ICP and ckUSDC balances across all of its subaccounts, for the admin page.
module {
    /// Which of core's subaccounts an account is.
    public type AccountKind = {
        /// Core's main account (no subaccount): paid shop creation fees end up here.
        #main;
        /// The deposit account of a shop creation quote.
        #shopCreationDeposit : Nat;
    };

    public type AccountBalance = {
        kind : AccountKind;
        subaccount : ?Blob;
        /// e8s.
        icp : Nat;
        /// 6 decimals.
        ckusdc : Nat;
    };

    public type Balances = {
        /// Sums over every account read, not only those in `accounts`. Settled quotes' deposit
        /// accounts already found empty aren't read (see `read`).
        icp : Nat;
        ckusdc : Nat;
        /// The main account, then every other account that holds ICP or ckUSDC.
        accounts : [AccountBalance];
    };

    public type Operations = {
        /// The (ICP, ckUSDC) balance of each of `subaccounts`, in order. `list` passes at most
        /// `BATCH_SIZE`; an implementation should send all their ledger calls before awaiting any,
        /// and directly rather than through local `async` functions (which are self-calls).
        balances : ([?Blob]) -> async* [(Nat, Nat)];
    };

    /// Accounts read at once, two ledger calls each. Every call in flight holds a prepayment of
    /// core's cycles (about 60B on mainnet), and too many at once leave too few for the next call
    /// (BRE-109).
    public let BATCH_SIZE = 2;

    /// Shop creation quotes' deposit accounts, as `read` sees them.
    public type Deposits = {
        /// Every quote's ID.
        ids : Iter.Iter<Nat>;
        /// Whether the quote's deposit is settled (see `ShopCreationAPI.depositSettled`), read live.
        settled : (Nat) -> Bool;
        /// Settled quotes whose deposit was found empty on both ledgers. `read` skips them and adds to it.
        empty : Set.Set<Nat>;
        subaccount : (Nat) -> Blob;
    };

    /// Core's balances: the main account and each quote's deposit
    /// account except settled ones already found empty, so after the first read the deposit
    /// accounts read are the open quotes' and those still holding funds, not every quote ever
    /// made (BRE-101). A quote counts as found empty only if it was settled both before its
    /// balances were read and after, so a payment racing the read isn't dropped.
    public func read(ops : Operations, deposits : Deposits) : async* Balances {
        let settledBefore = Set.empty<Nat>();
        let toRead = List.empty<Nat>();
        for (id in deposits.ids) {
            if (deposits.settled(id)) {
                if (not Set.contains(deposits.empty, Nat.compare, id)) {
                    Set.add(settledBefore, Nat.compare, id);
                    List.add(toRead, id);
                };
            } else {
                List.add(toRead, id);
            };
        };
        await* list(
            ops,
            accounts(List.values(toRead), deposits.subaccount),
            func(kind : AccountKind) {
                switch (kind) {
                    case (#shopCreationDeposit(id)) {
                        if (Set.contains(settledBefore, Nat.compare, id) and deposits.settled(id)) {
                            Set.add(deposits.empty, Nat.compare, id);
                        };
                    };
                    case (_) {};
                };
            },
        );
    };

    /// The balance of each of `accounts` (which should start with `#main`) on both ledgers.
    /// `onEmpty` is called with each account that holds neither ICP nor ckUSDC.
    public func list(ops : Operations, accounts : [(AccountKind, ?Blob)], onEmpty : (AccountKind) -> ()) : async* Balances {
        var icp = 0;
        var ckusdc = 0;
        let rows = List.empty<AccountBalance>();
        var start = 0;
        while (start < accounts.size()) {
            let batch = accounts.sliceToArray(start, Nat.min(start + BATCH_SIZE, accounts.size()));
            let balances = await* ops.balances(batch.map<(AccountKind, ?Blob), ?Blob>(func((_, subaccount)) = subaccount));
            for (i in batch.keys()) {
                let (kind, subaccount) = batch[i];
                let (accountIcp, accountCkusdc) = balances[i];
                let row = {
                    kind;
                    subaccount;
                    icp = accountIcp;
                    ckusdc = accountCkusdc;
                };
                icp += row.icp;
                ckusdc += row.ckusdc;
                if (kind == #main or row.icp > 0 or row.ckusdc > 0) {
                    List.add(rows, row);
                };
                if (row.icp == 0 and row.ckusdc == 0) {
                    onEmpty(kind);
                };
            };
            start += batch.size();
        };
        { icp; ckusdc; accounts = List.toArray(rows) };
    };

    /// Core's accounts: the main account, then each quote's deposit account. Core keeps no
    /// accounts for users (BRE-83).
    public func accounts(
        quoteIds : Iter.Iter<Nat>,
        depositSubaccount : (Nat) -> Blob,
    ) : [(AccountKind, ?Blob)] {
        let result = List.singleton<(AccountKind, ?Blob)>((#main, null));
        for (id in quoteIds) {
            List.add(result, (#shopCreationDeposit(id), ?depositSubaccount(id)));
        };
        List.toArray(result);
    };
};
