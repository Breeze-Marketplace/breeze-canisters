import Map "mo:core/Map";
import Nat32 "mo:core/Nat32";
import List "mo:core/List";

/// Per-order limit on the ledger reads that `checkPaymentICP` makes (BRE-70). Each order's payment
/// account is read at most once every `COOLDOWN_NANOS`; a check inside that window gets the balance
/// the last read returned instead of a new ledger call. The payment watcher reads accounts on its own
/// timer, so a buyer's browser never needs to check more often than this.
///
/// Kept in transient state: after an upgrade the limit starts again from empty, which costs at most
/// one extra read per order. Takes `Nat32` order IDs rather than `OrderId` so it does not import
/// `../types` (which imports `canister:xrc`) and can run under `mops test`.
module PaymentCheck {
    /// Shortest time between two ledger reads for the same order, in nanoseconds (5 seconds).
    public let COOLDOWN_NANOS : Int = 5_000_000_000;

    /// The last ledger read for one order: when it started, and the balance it returned (null while
    /// the read is in flight, or if it failed).
    public type LastRead = { startedAt : Int; balance : ?Nat };

    public type State = Map.Map<Nat32, LastRead>;

    public func empty() : State = Map.empty<Nat32, LastRead>();

    /// `#read`: go ahead and read the ledger (the read is recorded as started). `#recent`: the order
    /// was read less than `COOLDOWN_NANOS` ago; carries that read's balance, if it has returned.
    public type Decision = { #read; #recent : ?Nat };

    /// Decides whether a check of order `orderId` at `now` may read the ledger, and if so records the
    /// read as started, so concurrent checks of the same order make one ledger call between them.
    /// Drops every entry older than the cooldown first, so the state holds only recent reads.
    public func begin(state : State, orderId : Nat32, now : Int) : Decision {
        prune(state, now);
        switch (Map.get(state, Nat32.compare, orderId)) {
            case (?last) #recent(last.balance);
            case null {
                Map.add(state, Nat32.compare, orderId, { startedAt = now; balance = null });
                #read;
            };
        };
    };

    /// Records the balance returned by the read of `orderId` that `begin` started at `startedAt`.
    /// Ignored when a newer read has replaced that entry (or it has been pruned).
    public func record(state : State, orderId : Nat32, startedAt : Int, balance : Nat) {
        switch (Map.get(state, Nat32.compare, orderId)) {
            case (?last) {
                if (last.startedAt == startedAt) {
                    Map.add(state, Nat32.compare, orderId, { startedAt; balance = ?balance });
                };
            };
            case null {};
        };
    };

    /// Forgets order `orderId`, once it no longer awaits payment.
    public func forget(state : State, orderId : Nat32) {
        Map.remove(state, Nat32.compare, orderId);
    };

    /// Removes every read that started `COOLDOWN_NANOS` or more before `now`.
    func prune(state : State, now : Int) {
        let stale = List.empty<Nat32>();
        for ((orderId, last) in Map.entries(state)) {
            if (now - last.startedAt >= COOLDOWN_NANOS) {
                List.add(stale, orderId);
            };
        };
        for (orderId in List.values(stale)) {
            Map.remove(state, Nat32.compare, orderId);
        };
    };
};
