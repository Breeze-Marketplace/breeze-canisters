import Blob "mo:core/Blob";
import Int "mo:core/Int";
import Nat64 "mo:core/Nat64";
import List "mo:core/List";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Map "mo:map/Map";

import Ledger "canister:icp_ledger";
import CkUsdcLedger "canister:ckusdc_ledger";

import Hex "./Hex";
import TokenLib "./Token";

module Wallet {
    public type Token = Text;

    /// The ICRC-1 calls the wallet makes; both the ICP and ckUSDC ledgers provide them.
    public type LedgerActor = actor {
        icrc1_balance_of : shared query Ledger.Account -> async Ledger.Icrc1Tokens;
        icrc1_fee : shared query () -> async Ledger.Icrc1Tokens;
        icrc1_transfer : shared Ledger.TransferArg -> async Ledger.Icrc1TransferResult;
    };

    /// Every token symbol the wallet can hold.
    public let supportedTokens : [Token] = TokenLib.supported;

    /// The ledger canister for `token`, or null for an unsupported token.
    /// Every balance, fee and transfer for a token must go through this ledger.
    public func ledgerForToken(token : Token) : ?LedgerActor {
        switch (TokenLib.ledgerFor(token)) {
            case (?#ICP) { ?Ledger };
            case (?#ckUSDC) { ?CkUsdcLedger };
            case null { null };
        };
    };

    private func identifier(account : Ledger.Account) : Text {
        Hex.encode(Blob.toArray(Principal.toLedgerAccount(account.owner, account.subaccount)));
    };

    public module Account {
        public type Account = Ledger.Account and {
            identifier : Text;
            name : ?Text;
        };

        public func new(args : Ledger.Account and { name : ?Text }) : Account {
            let { owner; subaccount; name } = args;
            let accountId = identifier({ owner; subaccount });
            return {
                owner;
                subaccount;
                name;
                identifier = accountId;
            };
        };

        public func toLedgerAccount(account : Account) : Ledger.Account {
            { owner = account.owner; subaccount = account.subaccount };
        };

        /// Balance of `account` on `token`'s ledger; 0 for an unsupported token.
        public func balance(account : Account, token : Token) : async Nat {
            switch (ledgerForToken(token)) {
                case (?ledger) {
                    await ledger.icrc1_balance_of(toLedgerAccount(account));
                };
                case null { 0 };
            };
        };
    };

    public type Wallet = {
        owner : Principal;
        accounts : Map.Map<Text, Account.Account>;
        accountsByIdentifier : Map.Map<Text, Text>;
    };

    public func new(owner : Principal) : Wallet {
        let accounts = Map.new<Text, Account.Account>();
        let accountsByIdentifier = Map.new<Text, Text>();
        return { owner; accounts; accountsByIdentifier };
    };

    public func createAccount(
        wallet : Wallet,
        args : ?{
            name : ?Text;
            subaccount : ?Blob;
        },
    ) : Account.Account {
        let { subaccount; name } = Option.get(args, { name = null; subaccount = null });
        let account = Account.new({ owner = wallet.owner; subaccount; name });
        let _ = Map.put(wallet.accounts, Map.thash, account.identifier, account);
        account;
    };

    public func deleteAccount(wallet : Wallet, accountId : Text) : async Result<(), { #NotFoundError : Text; #NonZeroBalanceError : { msg : Text; balance : Nat } }> {
        let account = switch (Map.get(wallet.accounts, Map.thash, accountId)) {
            case (null) { return #err(#NotFoundError("Account not found")) };
            case (?account) { account };
        };
        // An account may hold any supported token, so check them all, not just ICP.
        for (token in supportedTokens.values()) {
            let balance = await Account.balance(account, token);
            if (balance != 0) {
                return #err(#NonZeroBalanceError({ msg = "Account has non-zero " # token # " balance"; balance }));
            };
        };
        let _ = Map.remove(wallet.accounts, Map.thash, accountId);
        #ok(());
    };

    /// Stops tracking the account with this subaccount, without reading its balance. For accounts whose
    /// funds aren't the wallet owner's, such as a cancelled order's payment account (BRE-31).
    public func untrackAccount(wallet : Wallet, subaccount : ?Blob) {
        Map.delete(wallet.accounts, Map.thash, identifier({ owner = wallet.owner; subaccount }));
    };

    public func getAccount(wallet : Wallet, accountId : Text) : ?Account.Account {
        Map.get(wallet.accounts, Map.thash, accountId);
    };

    public func listAccounts(wallet : Wallet) : [Account.Account] {
        let mainAccount : Account.Account = {
            owner = wallet.owner;
            subaccount = null;
            identifier = identifier({ owner = wallet.owner; subaccount = null });
            name = ?"Main";
        };
        let accounts = List.fromArray<Account.Account>([mainAccount]);

        for ((_, entry) in Map.entries(wallet.accounts)) {
            let { owner; subaccount; identifier; name } = entry;
            List.add(
                accounts,
                {
                    owner;
                    subaccount;
                    name;
                    identifier;
                },
            );
        };

        return List.toArray(accounts);
    };

    public func transfer(
        wallet : Wallet,
        args : {
            token : Token;
            fromAccountId : Text;
            to : Ledger.Account;
            amount : Nat;
        },
    ) : async Result<Nat, { #NotFoundError : Text; #UnsupportedToken : Token; #TransferError : Text; #InsufficientFunds : { balance : Nat; fee : Nat } }> {
        let { token; fromAccountId; to; amount } = args;
        // The balance, the fee and the transfer all go through the token's own ledger (BRE-30).
        let ledger = switch (ledgerForToken(token)) {
            case (null) { return #err(#UnsupportedToken(token)) };
            case (?l) { l };
        };
        let account = Wallet.getAccount(wallet, fromAccountId);
        let sourceAccount = switch (account) {
            case (null) {
                return #err(#NotFoundError("Account not found"));
            };
            case (?acc) acc;
        };
        let balance = await ledger.icrc1_balance_of(Account.toLedgerAccount(sourceAccount));
        let fee = await ledger.icrc1_fee();
        if (balance < amount + fee) {
            return #err(#InsufficientFunds({ balance; fee }));
        };
        switch (await ledger.icrc1_transfer({ to = to; amount = amount; fee = ?fee; memo = null; from_subaccount = sourceAccount.subaccount; created_at_time = ?Nat64.fromNat(Int.abs(Time.now())) })) {
            case (#Ok(_)) { #ok(amount) };
            case (#Err(e)) { #err(#TransferError(debug_show (e))) };
        };
    };
};
