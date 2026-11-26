import Error "mo:core/Error";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import Pagination "../../../lib/Pagination";

/// Automatic cycle top-ups for the shop and its vault, paid in ICP from the shop's main account
/// through the CMC (BRE-212). The Owner opts in and sets a threshold, the ICP per top-up and a cap
/// over 30 days. Only the main account pays: order subaccounts hold buyers' payments (BRE-31).
///
/// A run first asks the CMC again about top-ups whose ICP was sent but whose cycles weren't
/// confirmed, then checks the shop and the vault in turn. Every top-up that moved ICP is logged;
/// checks that sent nothing are only in the last run's result. `AutoTopUpApi` checks callers and
/// holds the one-run-at-a-time lock.
module AutoTopUp {
    public let E8S_PER_ICP = 100_000_000;

    public type TopUpSettings = {
        /// A canister below this many cycles is topped up.
        thresholdCycles : Nat;
        /// ICP (e8s) converted per top-up, the ledger fee not included.
        topUpE8s : Nat;
        /// The most ICP (e8s) converted in any 30 days, ledger fees not included.
        maxE8sPer30Days : Nat;
    };

    public type TopUpLimits = {
        minThresholdCycles : Nat;
        maxThresholdCycles : Nat;
        minTopUpE8s : Nat;
        maxTopUpE8s : Nat;
        maxE8sPer30Days : Nat;
    };

    public let limits : TopUpLimits = {
        minThresholdCycles = 500_000_000_000;
        maxThresholdCycles = 50_000_000_000_000;
        // The CMC refunds transfers too small to cover its fee; 0.1 ICP is well above it.
        minTopUpE8s = 10_000_000;
        maxTopUpE8s = 10_000_000_000;
        maxE8sPer30Days = 100_000_000_000;
    };

    public func validate(settings : TopUpSettings) : Result<(), Text> {
        if (settings.thresholdCycles < limits.minThresholdCycles or settings.thresholdCycles > limits.maxThresholdCycles) {
            return #err("The threshold must be 0.5T to 50T cycles");
        };
        if (settings.topUpE8s < limits.minTopUpE8s or settings.topUpE8s > limits.maxTopUpE8s) {
            return #err("Each top-up must be 0.1 to 100 ICP");
        };
        if (settings.maxE8sPer30Days < settings.topUpE8s or settings.maxE8sPer30Days > limits.maxE8sPer30Days) {
            return #err("The 30-day cap must cover at least one top-up and be at most 1,000 ICP");
        };
        #ok;
    };

    public let WINDOW_NANOS : Int = 2_592_000_000_000_000; // 30 days

    /// At most this many top-ups in any 30 days, whatever their size: a canister burning cycles
    /// unusually fast stops being fed long before the cap if top-ups are small.
    public let MAX_TOP_UPS_PER_WINDOW = 60;

    /// Log entries kept. Above `MAX_TOP_UPS_PER_WINDOW`, so the last 30 days are always all there
    /// when the cap is counted. Entries still waiting on the CMC are never dropped.
    public let MAX_KEPT = 200;

    /// After this many unanswered notifications a top-up is given up on (about three days of runs).
    public let MAX_NOTIFY_ATTEMPTS = 72;

    public type CanisterKind = { #shop; #vault };

    public type TopUpTrigger = { #timer; #manual : Principal };

    public type TopUpOutcome = {
        /// The ICP reached the CMC; its `notify_top_up` hasn't confirmed the cycles yet. Retried
        /// each run.
        #notifying;
        /// The CMC minted this many cycles for the canister.
        #minted : Nat;
        /// The CMC sent the ICP back to the main account, minus its fee.
        #refunded : Text;
        /// The CMC refused the block, or never answered within `MAX_NOTIFY_ATTEMPTS`.
        #failed : Text;
    };

    /// A top-up that moved ICP out of the main account.
    public type TopUp = {
        id : Nat;
        at : Int;
        trigger : TopUpTrigger;
        kind : CanisterKind;
        canisterId : Principal;
        balanceBefore : Nat;
        e8s : Nat;
        /// The ledger block of the transfer to the CMC.
        blockIndex : Nat;
        outcome : TopUpOutcome;
        notifyAttempts : Nat;
    };

    public type State = {
        /// Null while auto top-up is off.
        var settings : ?TopUpSettings;
        var nextId : Nat;
        topUps : Map.Map<Nat, TopUp>;
    };

    public type TopUpSkipReason = {
        /// A top-up of this canister is still waiting on the CMC.
        #notifyPending;
        /// The 30-day cap (amount or count) leaves less than a minimum top-up.
        #capReached;
        /// The main account can't cover the top-up and the ledger fee.
        #insufficientFunds : { balance : Nat; needed : Nat };
    };

    public type TopUpCheckStatus = {
        #healthy;
        #toppedUp : { e8s : Nat; outcome : TopUpOutcome };
        #skipped : TopUpSkipReason;
        /// The vault's balance couldn't be read (an older vault, or it didn't answer).
        #balanceUnavailable : Text;
        /// Nothing was sent: the ledger couldn't be read or refused the transfer.
        #transferFailed : Text;
    };

    public type TopUpCheck = {
        kind : CanisterKind;
        canisterId : Principal;
        balance : ?Nat;
        status : TopUpCheckStatus;
    };

    public type TopUpRun = {
        startedAt : Int;
        finishedAt : Int;
        trigger : TopUpTrigger;
        /// Earlier top-ups the CMC confirmed, refunded or refused during this run.
        resolved : Nat;
        checks : [TopUpCheck];
    };

    /// Transient: a run in progress and the last one's result.
    public type TopUpRunState = {
        var running : Bool;
        var lastRun : ?TopUpRun;
    };

    public func emptyRunState() : TopUpRunState = {
        var running = false;
        var lastRun = null;
    };

    /// What the CMC said about a top-up, sorted by what to do next.
    public type NotifyResult = {
        #minted : Nat;
        #refunded : Text;
        /// Final: the block will never be accepted.
        #failed : Text;
        /// Ask again on the next run.
        #retry : Text;
    };

    public type Operations = {
        ownBalance : () -> Nat;
        vaultBalance : (Principal) -> async* Nat;
        mainBalanceE8s : () -> async* Nat;
        feeE8s : () -> async* Nat;
        /// Sends `e8s` from the main account to the CMC's top-up account for the canister, paying
        /// `fee`. Returns the block index, or the ledger's error.
        transferToCmc : (canisterId : Principal, e8s : Nat, fee : Nat, createdAtTime : Nat64) -> async* Result<Nat, Text>;
        notifyTopUp : (blockIndex : Nat, canisterId : Principal) -> async* NotifyResult;
        now : () -> Int;
    };

    public func empty() : State = {
        var settings = null;
        var nextId = 0;
        topUps = Map.empty();
    };

    /// ICP converted and top-ups made in the 30 days up to `now`.
    public func spentInWindow(state : State, now : Int) : {
        e8s : Nat;
        count : Nat;
    } {
        var e8s = 0;
        var count = 0;
        label newestFirst for ((_, topUp) in state.topUps.reverseEntries()) {
            if (topUp.at <= now - WINDOW_NANOS) break newestFirst;
            e8s += topUp.e8s;
            count += 1;
        };
        { e8s; count };
    };

    public func hasPendingNotify(state : State, canisterId : Principal) : Bool {
        for ((_, topUp) in state.topUps.entries()) {
            if (topUp.canisterId == canisterId and topUp.outcome == #notifying) return true;
        };
        false;
    };

    public type Plan = { #healthy; #topUp : Nat; #skip : TopUpSkipReason };

    /// Whether a canister holding `balance` gets a top-up and how much, before the ledger is read.
    public func plan(settings : TopUpSettings, state : State, canisterId : Principal, balance : Nat, now : Int) : Plan {
        if (balance >= settings.thresholdCycles) return #healthy;
        if (hasPendingNotify(state, canisterId)) return #skip(#notifyPending);
        let spent = spentInWindow(state, now);
        if (spent.count >= MAX_TOP_UPS_PER_WINDOW or spent.e8s >= settings.maxE8sPer30Days) return #skip(#capReached);
        let amount = Nat.min(settings.topUpE8s, settings.maxE8sPer30Days - spent.e8s);
        if (amount < limits.minTopUpE8s) return #skip(#capReached);
        #topUp(amount);
    };

    /// Null when the main account's live `balance` covers `amount` plus the ledger `fee`.
    public func fundsShortfall(amount : Nat, fee : Nat, balance : Nat) : ?TopUpSkipReason {
        if (balance >= amount + fee) null else ?#insufficientFunds({
            balance;
            needed = amount + fee;
        });
    };

    func record(state : State, entry : TopUp) {
        state.topUps.add(Nat.compare, entry.id, entry);
    };

    func update(state : State, id : Nat, outcome : TopUpOutcome, notifyAttempts : Nat) {
        switch (state.topUps.get(Nat.compare, id)) {
            case (?entry) record(state, { entry with outcome; notifyAttempts });
            case null {};
        };
    };

    /// Drops the oldest entries beyond `MAX_KEPT`, keeping any still waiting on the CMC.
    func prune(state : State) {
        if (state.topUps.size() <= MAX_KEPT) return;
        let droppable = List.empty<Nat>();
        var excess : Nat = state.topUps.size() - MAX_KEPT;
        label oldestFirst for ((id, topUp) in state.topUps.entries()) {
            if (excess == 0) break oldestFirst;
            if (topUp.outcome != #notifying) {
                droppable.add(id);
                excess -= 1;
            };
        };
        for (id in droppable.values()) state.topUps.remove(Nat.compare, id);
    };

    func outcomeOf(result : NotifyResult, attempts : Nat) : TopUpOutcome {
        switch (result) {
            case (#minted(cycles)) #minted(cycles);
            case (#refunded(reason)) #refunded(reason);
            case (#failed(reason)) #failed(reason);
            case (#retry(reason)) {
                if (attempts >= MAX_NOTIFY_ATTEMPTS) #failed("The CMC didn't confirm the top-up after " # Nat.toText(attempts) # " attempts: " # reason) else #notifying;
            };
        };
    };

    func notify(ops : Operations, state : State, id : Nat, blockIndex : Nat, canisterId : Principal, attemptsBefore : Nat) : async* TopUpOutcome {
        let attempts = attemptsBefore + 1;
        let result = try {
            await* ops.notifyTopUp(blockIndex, canisterId);
        } catch (e) {
            #retry(Error.message(e));
        };
        let outcome = outcomeOf(result, attempts);
        update(state, id, outcome, attempts);
        outcome;
    };

    /// Asks the CMC again about every top-up still `#notifying`. Returns how many got an answer.
    func retryPending(ops : Operations, state : State) : async* Nat {
        let pending = List.empty<TopUp>();
        for ((_, topUp) in state.topUps.entries()) {
            if (topUp.outcome == #notifying) pending.add(topUp);
        };
        var resolved = 0;
        for (topUp in pending.values()) {
            if ((await* notify(ops, state, topUp.id, topUp.blockIndex, topUp.canisterId, topUp.notifyAttempts)) != #notifying) {
                resolved += 1;
            };
        };
        resolved;
    };

    /// Checks one canister and tops it up if it's low. Settings, the shop's balance and whether
    /// `canisterId` is still the target (`stillTarget`: the Owner can relink the vault) are re-read
    /// after every await, so a change during the run applies before any ICP is sent.
    func check(ops : Operations, state : State, kind : CanisterKind, canisterId : Principal, stillTarget : () -> Bool, trigger : TopUpTrigger) : async* ?TopUpCheck {
        if (state.settings == null) return null;
        let balanceBefore = switch (kind) {
            case (#shop) ops.ownBalance();
            case (#vault) {
                try { await* ops.vaultBalance(canisterId) } catch (e) {
                    if (not stillTarget()) return null;
                    return ?{
                        kind;
                        canisterId;
                        balance = null;
                        status = #balanceUnavailable(Error.message(e));
                    };
                };
            };
        };
        func result(status : TopUpCheckStatus) : ?TopUpCheck = ?{
            kind;
            canisterId;
            balance = ?balanceBefore;
            status;
        };
        let ?settingsAfterBalance = state.settings else return null;
        if (not stillTarget()) return null;
        switch (plan(settingsAfterBalance, state, canisterId, balanceBefore, ops.now())) {
            case (#healthy) return result(#healthy);
            case (#skip(reason)) return result(#skipped(reason));
            case (#topUp(_)) {};
        };
        let (mainBalance, fee) = try {
            (await* ops.mainBalanceE8s(), await* ops.feeE8s());
        } catch (e) {
            return result(#transferFailed("Couldn't read the ICP ledger: " # Error.message(e)));
        };
        let ?settings = state.settings else return null;
        if (not stillTarget()) return null;
        // The shop's own balance may have grown during the ledger reads (a manual top-up); the
        // vault's can't be re-read without another await, and its threshold check just ran.
        let balance = switch (kind) {
            case (#shop) ops.ownBalance();
            case (#vault) balanceBefore;
        };
        let amount = switch (plan(settings, state, canisterId, balance, ops.now())) {
            case (#healthy) return result(#healthy);
            case (#skip(reason)) return result(#skipped(reason));
            case (#topUp(amount)) amount;
        };
        switch (fundsShortfall(amount, fee, mainBalance)) {
            case (?reason) return result(#skipped(reason));
            case null {};
        };
        let now = ops.now();
        let blockIndex = try {
            switch (await* ops.transferToCmc(canisterId, amount, fee, Nat64.fromNat(Int.abs(now)))) {
                case (#ok(blockIndex)) blockIndex;
                case (#err(message)) return result(#transferFailed(message));
            };
        } catch (e) {
            return result(#transferFailed(Error.message(e)));
        };
        let id = state.nextId;
        state.nextId += 1;
        record(
            state,
            {
                id;
                at = now;
                trigger;
                kind;
                canisterId;
                balanceBefore = balance;
                e8s = amount;
                blockIndex;
                outcome = #notifying;
                notifyAttempts = 0;
            },
        );
        prune(state);
        // Retries of a sent transfer always use its recorded canister, whatever the vault is now.
        let outcome = await* notify(ops, state, id, blockIndex, canisterId, 0);
        result(#toppedUp({ e8s = amount; outcome }));
    };

    /// One run: retry pending notifications (even with auto top-up off, since that ICP has left
    /// the account), then check the shop and, if it has one, its vault. `vaultId` is read live:
    /// the vault checked is the one linked when its check starts, and the check stops if the link
    /// changes before ICP is sent.
    public func run(ops : Operations, state : State, shopId : Principal, vaultId : () -> ?Principal, trigger : TopUpTrigger) : async* TopUpRun {
        let startedAt = ops.now();
        let resolved = await* retryPending(ops, state);
        let checks = List.empty<TopUpCheck>();
        switch (await* check(ops, state, #shop, shopId, func() = true, trigger)) {
            case (?done) checks.add(done);
            case null {};
        };
        switch (vaultId()) {
            case (?vault) {
                switch (await* check(ops, state, #vault, vault, func() = vaultId() == ?vault, trigger)) {
                    case (?done) checks.add(done);
                    case null {};
                };
            };
            case null {};
        };
        {
            startedAt;
            finishedAt = ops.now();
            trigger;
            resolved;
            checks = checks.toArray();
        };
    };

    /// Top-ups newest first, before id `after`.
    public func page(state : State, after : ?Nat, limit : ?Nat) : Pagination.Page<TopUp, Nat> {
        let entries = switch (after) {
            case null state.topUps.reverseEntries();
            case (?id) state.topUps.reverseEntriesFrom(Nat.compare, id).filter(func((entryId, _) : (Nat, TopUp)) : Bool = entryId < id);
        };
        Pagination.take<TopUp, Nat>(entries.map(func((_, topUp) : (Nat, TopUp)) : TopUp = topUp), limit, func(topUp) = topUp.id);
    };

    /// The CMC's answer to `notify_top_up`, sorted by what to do next.
    public func classifyNotify(result : { #Ok : Nat; #Err : { #Refunded : { reason : Text; block_index : ?Nat64 }; #Processing; #TransactionTooOld : Nat64; #InvalidTransaction : Text; #Other : { error_code : Nat64; error_message : Text } } }) : NotifyResult {
        switch (result) {
            case (#Ok(cycles)) #minted(cycles);
            case (#Err(#Refunded({ reason }))) #refunded(reason);
            case (#Err(#Processing)) #retry("The CMC is still processing the block");
            case (#Err(#TransactionTooOld(_))) #failed("The CMC says the block is too old");
            case (#Err(#InvalidTransaction(message))) #failed("The CMC refused the block: " # message);
            case (#Err(#Other({ error_message }))) #retry(error_message);
        };
    };
};
