import Int "mo:core/Int";
import List "mo:core/List";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Order "mo:core/Order";
import Principal "mo:core/Principal";
import Set "mo:core/Set";

import Decimals "../../../lib/Decimals";

/// When unpaid orders expire, and what to do with the funds in an order's invoice subaccount.
/// Takes structural order fields rather than `Order` so it does not import `../types` (which imports
/// `canister:xrc`) and can run under `mops test`.
module OrderExpiry {
    /// How long a buyer has to pay an order, in nanoseconds (10 minutes).
    public let PAYMENT_WINDOW_NANOS : Int = 600_000_000_000;

    /// How long to wait before retrying an expiry check whose ledger call failed, in seconds.
    public let RETRY_DELAY_SECONDS : Nat = 60;

    /// How often the shop reads unpaid orders' payment accounts for incoming funds, in seconds.
    public let PAYMENT_WATCH_INTERVAL_SECONDS : Nat = 30;

    /// Fewest payment accounts the watcher reads each time its timer fires (every
    /// `PAYMENT_WATCH_INTERVAL_SECONDS`), when that many orders are watched.
    public let MIN_ORDERS_PER_WATCH : Nat = 50;

    /// Most payment accounts the watcher reads each time its timer fires. Anyone signed in can create
    /// orders, so this caps the ledger calls (and cycles) a burst of unpaid orders can cost: at most
    /// this many balance reads every `PAYMENT_WATCH_INTERVAL_SECONDS`.
    public let MAX_ORDERS_PER_WATCH : Nat = 200;

    /// Balance reads the watcher has in flight at once. Every call in flight holds a prepayment of
    /// the shop's cycles (about 60B on mainnet), so a wide burst would leave none for the shop's
    /// other calls (BRE-109).
    public let WATCH_READS_IN_FLIGHT : Nat = 5;

    /// The watcher aims to read every watched order's account within this many passes (2 minutes at
    /// 30 s each), growing its batch from `MIN_ORDERS_PER_WATCH` up to `MAX_ORDERS_PER_WATCH`.
    public let WATCH_SWEEP_PASSES : Nat = 4;

    /// Same constructors as `OrderStatus` in `../types`.
    public type OrderStatus = {
        #created;
        #awaitingPayment;
        #paid;
        #processing;
        #partiallyFulfilled;
        #fulfilled;
        #canceled;
        #refunded;
    };

    /// The time an order created at `createdAt` expires if still unpaid.
    public func expiresAt(createdAt : Int) : Int {
        createdAt + PAYMENT_WINDOW_NANOS;
    };

    /// True while the order can still be paid or cancelled.
    public func isAwaitingPayment(status : OrderStatus) : Bool {
        switch (status) {
            case (#created or #awaitingPayment) true;
            case _ false;
        };
    };

    /// True when an unpaid order's payment window has closed at `now`.
    public func isExpired(order : { status : OrderStatus; expiresAt : Int }, now : Int) : Bool {
        isAwaitingPayment(order.status) and now >= order.expiresAt;
    };

    /// True when the payment watcher should read the order's payment account: unpaid and not yet
    /// expired. From `expiresAt` on, the expiry sweep decides instead.
    public func isWatched(order : { status : OrderStatus; expiresAt : Int }, now : Int) : Bool {
        isAwaitingPayment(order.status) and now < order.expiresAt;
    };

    /// How many accounts the watcher reads in one pass when `watched` orders await payment: enough to
    /// read them all every `WATCH_SWEEP_PASSES` passes, at least `MIN_ORDERS_PER_WATCH` and at most
    /// `MAX_ORDERS_PER_WATCH`.
    public func watchBatchSize(watched : Nat) : Nat {
        let perSweep = (watched + WATCH_SWEEP_PASSES - 1) / WATCH_SWEEP_PASSES;
        if (perSweep < MIN_ORDERS_PER_WATCH) MIN_ORDERS_PER_WATCH else if (perSweep > MAX_ORDERS_PER_WATCH) MAX_ORDERS_PER_WATCH else perSweep;
    };

    /// IDs of the orders still awaiting payment (`isAwaitingPayment`), ascending. The shop keeps it
    /// stable and current, so the payment watcher and the timer re-arming after an upgrade cost time
    /// proportional to open orders, not to every order the shop ever took (BRE-100).
    public type AwaitingPaymentIds = Set.Set<Nat32>;

    /// Keeps `ids` in step with order `orderId`'s new `status`: in the set while it awaits payment,
    /// out of it once paid, cancelled (including by expiry) or refunded. Call it on every status change.
    public func syncAwaitingPayment(ids : AwaitingPaymentIds, orderId : Nat32, status : OrderStatus) {
        if (isAwaitingPayment(status)) {
            Set.add(ids, Nat32.compare, orderId);
        } else {
            Set.remove(ids, Nat32.compare, orderId);
        };
    };

    /// The orders to read the next time the watcher fires: up to `limit` of the orders in `ids` that
    /// `isWatchedId` accepts, ascending from just after `cursor` (the last order read) and wrapping
    /// around, so every watched order is read even when there are more than `limit` of them. Visits
    /// each ID in `ids` at most once.
    public func nextWatchBatch(ids : AwaitingPaymentIds, cursor : ?Nat32, limit : Nat, isWatchedId : Nat32 -> Bool) : [Nat32] {
        let batch = List.empty<Nat32>();
        func take(id : Nat32) : Bool {
            if (List.size(batch) >= limit) return false;
            if (isWatchedId(id)) List.add(batch, id);
            true;
        };
        switch (cursor) {
            case null {
                label all for (id in Set.values(ids)) {
                    if (not take(id)) break all;
                };
            };
            case (?last) {
                var full = false;
                label after for (id in Set.valuesFrom(ids, Nat32.compare, last)) {
                    if (id != last and not take(id)) {
                        full := true;
                        break after;
                    };
                };
                if (not full) {
                    label wrap for (id in Set.values(ids)) {
                        if (id > last or not take(id)) break wrap;
                    };
                };
            };
        };
        List.toArray(batch);
    };

    /// Expired orders the expiry sweep reads at once, one ledger call each. Every call in flight
    /// holds a prepayment of the shop's cycles, so expiring a burst of orders one timer each would
    /// leave the shop none for anything else (BRE-110).
    public let EXPIRY_READS_IN_FLIGHT : Nat = 5;

    /// Unpaid orders by when the expiry sweep should look at them next: `expiresAt`, or a retry time
    /// after a failed ledger read. Transient: the shop rebuilds it from `AwaitingPaymentIds` on every
    /// install and upgrade. An order that is paid or cancelled before its entry comes due stays in
    /// the queue until then, and the sweep drops it.
    public type ExpiryQueue = Set.Set<(Int, Nat32)>;

    func compareDue((at1, id1) : (Int, Nat32), (at2, id2) : (Int, Nat32)) : Order.Order {
        switch (Int.compare(at1, at2)) {
            case (#equal) Nat32.compare(id1, id2);
            case order order;
        };
    };

    /// Queues order `orderId` for the sweep to look at from `at` on.
    public func scheduleExpiry(queue : ExpiryQueue, at : Int, orderId : Nat32) {
        Set.add(queue, compareDue, (at, orderId));
    };

    /// When the earliest queued order comes due, if any is queued.
    public func nextExpiry(queue : ExpiryQueue) : ?Int {
        switch (Set.min(queue)) {
            case (?(at, _)) ?at;
            case null null;
        };
    };

    /// Removes and returns up to `limit` orders due at `now`, earliest first.
    public func takeDue(queue : ExpiryQueue, now : Int, limit : Nat) : [Nat32] {
        let due = List.empty<(Int, Nat32)>();
        label scan for (entry in Set.values(queue)) {
            if (List.size(due) >= limit or entry.0 > now) break scan;
            List.add(due, entry);
        };
        for (entry in List.values(due)) {
            Set.remove(queue, compareDue, entry);
        };
        List.toArray(List.map<(Int, Nat32), Nat32>(due, func((_, id)) = id));
    };

    /// Decimals of the ICRC-1 ledger used for `symbol`, or null when the shop has no ledger for it.
    public func ledgerDecimals(symbol : Text) : ?Nat32 {
        switch (symbol) {
            case "ICP" ?8;
            case "ckUSDC" ?6;
            case _ null;
        };
    };

    /// True when a ledger `balance` (in units with `balanceDecimals`) pays the order total in full. An
    /// empty account never counts, even for an order whose total is zero.
    public func isPaidInFull(
        balance : Nat,
        balanceDecimals : Nat32,
        total : { amount : Nat64; metadata : { decimals : Nat32 } },
    ) : Bool {
        balance > 0 and Decimals.compare(balance, balanceDecimals, total.amount.toNat(), total.metadata.decimals) != #less;
    };

    /// Amount that can be sent out of an account holding `balance` after paying the ledger `fee`.
    public func refundableAmount(balance : Nat, fee : Nat) : ?Nat {
        if (balance > fee) ?(balance - fee) else null;
    };

    /// Who may reclaim funds sent to a cancelled order's invoice subaccount, and where they go.
    /// The buyer may pick a destination (default: their own account). An Owner or Admin may only send
    /// them back to the buyer. Funds of an anonymous buyer cannot be returned to the anonymous account,
    /// which anyone could spend from.
    public func reclaimDestination(
        caller : Principal,
        buyer : Principal,
        callerManagesOrders : Bool,
        requested : ?{ owner : Principal; subaccount : ?Blob },
    ) : { #ok : { owner : Principal; subaccount : ?Blob }; #err : Text } {
        if (Principal.isAnonymous(buyer)) {
            return #err("Orders placed anonymously cannot be refunded automatically");
        };
        let isBuyer = Principal.equal(caller, buyer);
        if (not isBuyer and not callerManagesOrders) {
            return #err("Only the order buyer, Owner or Admin can reclaim this payment");
        };
        switch (requested) {
            case null #ok({ owner = buyer; subaccount = null });
            case (?account) {
                if (not isBuyer) {
                    return #err("Only the buyer can choose where a refund goes");
                };
                #ok(account);
            };
        };
    };
};
