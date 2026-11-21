import { expect } "mo:test";
import { suite; test } "mo:test";

import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import Set "mo:core/Set";

import OrderExpiry "../order_expiry";

let buyer = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let staff = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let stranger = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");
let anonymous = Principal.anonymous();
let otherAccount = { owner = stranger; subaccount = null : ?Blob };

let createdAt : Int = 1_000_000_000_000;
let deadline = OrderExpiry.expiresAt(createdAt);

// 1 ICP, as order totals store it (8 decimals).
let oneIcp = {
    amount = 100_000_000 : Nat64;
    metadata = { decimals = 8 : Nat32 };
};
// 5 USDC, stored with 2 decimals.
let fiveUsdc = { amount = 500 : Nat64; metadata = { decimals = 2 : Nat32 } };

suite(
    "OrderExpiry.expiresAt",
    func() {
        test(
            "is 10 minutes after creation",
            func() {
                expect.int(deadline - createdAt).equal(600_000_000_000);
            },
        );
    },
);

suite(
    "OrderExpiry.isExpired",
    func() {
        test(
            "unpaid orders expire at the deadline, not before",
            func() {
                let order = { status = #created; expiresAt = deadline };
                expect.bool(OrderExpiry.isExpired(order, deadline - 1)).isFalse();
                expect.bool(OrderExpiry.isExpired(order, deadline)).isTrue();
                expect.bool(OrderExpiry.isExpired({ order with status = #awaitingPayment }, deadline + 1)).isTrue();
            },
        );
        test(
            "paid, fulfilled and cancelled orders never expire",
            func() {
                for (status in [#paid, #processing, #partiallyFulfilled, #fulfilled, #canceled, #refunded].vals()) {
                    expect.bool(OrderExpiry.isExpired({ status; expiresAt = deadline }, deadline + 1)).isFalse();
                };
            },
        );
    },
);

suite(
    "OrderExpiry.isPaidInFull",
    func() {
        test(
            "true when the balance covers the total",
            func() {
                expect.bool(OrderExpiry.isPaidInFull(100_000_000, 8, oneIcp)).isTrue();
                expect.bool(OrderExpiry.isPaidInFull(150_000_000, 8, oneIcp)).isTrue();
            },
        );
        test(
            "false when nothing or too little was paid",
            func() {
                expect.bool(OrderExpiry.isPaidInFull(0, 8, oneIcp)).isFalse();
                expect.bool(OrderExpiry.isPaidInFull(99_999_999, 8, oneIcp)).isFalse();
            },
        );
        test(
            "compares across decimals (ckUSDC ledger has 6, the total has 2)",
            func() {
                expect.bool(OrderExpiry.isPaidInFull(5_000_000, 6, fiveUsdc)).isTrue();
                expect.bool(OrderExpiry.isPaidInFull(4_999_999, 6, fiveUsdc)).isFalse();
            },
        );
        test(
            "an empty account never counts, even for a zero total",
            func() {
                let free = {
                    amount = 0 : Nat64;
                    metadata = { decimals = 8 : Nat32 };
                };
                expect.bool(OrderExpiry.isPaidInFull(0, 8, free)).isFalse();
            },
        );
    },
);

suite(
    "OrderExpiry.ledgerDecimals",
    func() {
        test(
            "knows the ICP and ckUSDC ledgers only",
            func() {
                expect.bool(OrderExpiry.ledgerDecimals("ICP") == ?8).isTrue();
                expect.bool(OrderExpiry.ledgerDecimals("ckUSDC") == ?6).isTrue();
                expect.bool(OrderExpiry.ledgerDecimals("USD") == null).isTrue();
            },
        );
    },
);

suite(
    "OrderExpiry.refundableAmount",
    func() {
        test(
            "returns the balance minus the fee",
            func() {
                expect.bool(OrderExpiry.refundableAmount(50_000, 10_000) == ?40_000).isTrue();
            },
        );
        test(
            "returns nothing when the balance doesn't cover the fee",
            func() {
                expect.bool(OrderExpiry.refundableAmount(10_000, 10_000) == null).isTrue();
                expect.bool(OrderExpiry.refundableAmount(0, 10_000) == null).isTrue();
            },
        );
    },
);

suite(
    "OrderExpiry.reclaimDestination",
    func() {
        test(
            "the buyer gets the funds in their own account by default",
            func() {
                let result = OrderExpiry.reclaimDestination(buyer, buyer, false, null);
                expect.bool(result == #ok({ owner = buyer; subaccount = null })).isTrue();
            },
        );
        test(
            "the buyer may choose another destination",
            func() {
                let result = OrderExpiry.reclaimDestination(buyer, buyer, false, ?otherAccount);
                expect.bool(result == #ok(otherAccount)).isTrue();
            },
        );
        test(
            "staff can send the funds back to the buyer only",
            func() {
                expect.bool(OrderExpiry.reclaimDestination(staff, buyer, true, null) == #ok({ owner = buyer; subaccount = null })).isTrue();
                switch (OrderExpiry.reclaimDestination(staff, buyer, true, ?otherAccount)) {
                    case (#ok(_)) { expect.bool(true).isFalse() };
                    case (#err(_)) {};
                };
            },
        );
        test(
            "other callers are refused",
            func() {
                for (caller in [stranger, anonymous].vals()) {
                    switch (OrderExpiry.reclaimDestination(caller, buyer, false, null)) {
                        case (#ok(_)) { expect.bool(true).isFalse() };
                        case (#err(_)) {};
                    };
                };
            },
        );
        test(
            "funds of an anonymous buyer are never sent to the anonymous account",
            func() {
                for (caller in [anonymous, staff].vals()) {
                    switch (OrderExpiry.reclaimDestination(caller, anonymous, true, null)) {
                        case (#ok(_)) { expect.bool(true).isFalse() };
                        case (#err(_)) {};
                    };
                };
            },
        );
    },
);

suite(
    "OrderExpiry.isWatched",
    func() {
        test(
            "watches unpaid orders until their deadline, then leaves them to the expiry timer",
            func() {
                let order = { status = #created; expiresAt = deadline };
                expect.bool(OrderExpiry.isWatched(order, createdAt)).isTrue();
                expect.bool(OrderExpiry.isWatched({ order with status = #awaitingPayment }, deadline - 1)).isTrue();
                expect.bool(OrderExpiry.isWatched(order, deadline)).isFalse();
            },
        );
        test(
            "never watches paid or cancelled orders",
            func() {
                for (status in [#paid, #fulfilled, #canceled, #refunded].vals()) {
                    expect.bool(OrderExpiry.isWatched({ status; expiresAt = deadline }, createdAt)).isFalse();
                };
            },
        );
    },
);

func idSet(ids : [Nat32]) : OrderExpiry.AwaitingPaymentIds = Set.fromArray(ids, Nat32.compare);
func showIds(ids : [Nat32]) : Text = debug_show ids;
func all(_ : Nat32) : Bool = true;

suite(
    "OrderExpiry.nextWatchBatch",
    func() {
        let ids = idSet([1, 2, 3, 4, 5]);
        func expectBatch(batch : [Nat32], expected : [Nat32]) {
            expect.text(showIds(batch)).equal(showIds(expected));
        };
        test(
            "reads every order when they fit in one pass",
            func() {
                expectBatch(OrderExpiry.nextWatchBatch(ids, null, 10, all), [1, 2, 3, 4, 5]);
            },
        );
        test(
            "starts after the cursor and wraps around",
            func() {
                expectBatch(OrderExpiry.nextWatchBatch(ids, ?3, 10, all), [4, 5, 1, 2, 3]);
            },
        );
        test(
            "reads at most `limit` orders, and successive passes reach all of them",
            func() {
                expectBatch(OrderExpiry.nextWatchBatch(ids, null, 2, all), [1, 2]);
                expectBatch(OrderExpiry.nextWatchBatch(ids, ?2, 2, all), [3, 4]);
                expectBatch(OrderExpiry.nextWatchBatch(ids, ?4, 2, all), [5, 1]);
            },
        );
        test(
            "a cursor on an order that is no longer in the set still continues after it",
            func() {
                expectBatch(OrderExpiry.nextWatchBatch(idSet([2, 5, 9]), ?4, 2, all), [5, 9]);
            },
        );
        test(
            "skips orders the watcher doesn't read (expired ones, left to their expiry timer)",
            func() {
                let notExpired = func(id : Nat32) : Bool = id % 2 == 1;
                expectBatch(OrderExpiry.nextWatchBatch(ids, null, 2, notExpired), [1, 3]);
                expectBatch(OrderExpiry.nextWatchBatch(ids, ?3, 2, notExpired), [5, 1]);
                expectBatch(OrderExpiry.nextWatchBatch(ids, null, 10, func _ = false), []);
            },
        );
        test(
            "is empty when no order awaits payment",
            func() {
                expectBatch(OrderExpiry.nextWatchBatch(idSet([]), ?7, 10, all), []);
            },
        );
    },
);

suite(
    "OrderExpiry.watchBatchSize",
    func() {
        test(
            "reads at least the minimum, so small shops are read every pass",
            func() {
                expect.nat(OrderExpiry.watchBatchSize(0)).equal(OrderExpiry.MIN_ORDERS_PER_WATCH);
                expect.nat(OrderExpiry.watchBatchSize(10)).equal(OrderExpiry.MIN_ORDERS_PER_WATCH);
            },
        );
        test(
            "grows so every watched order is read within a few passes",
            func() {
                expect.nat(OrderExpiry.watchBatchSize(600)).equal(150);
                expect.nat(OrderExpiry.watchBatchSize(601)).equal(151);
            },
        );
        test(
            "never reads more than the cap in one pass",
            func() {
                expect.nat(OrderExpiry.watchBatchSize(1_000_000)).equal(OrderExpiry.MAX_ORDERS_PER_WATCH);
                expect.nat(OrderExpiry.MAX_ORDERS_PER_WATCH).lessOrEqual(200);
                expect.nat(OrderExpiry.PAYMENT_WATCH_INTERVAL_SECONDS).equal(30);
            },
        );
    },
);

suite(
    "OrderExpiry.syncAwaitingPayment",
    func() {
        func contains(ids : OrderExpiry.AwaitingPaymentIds, id : Nat32) : Bool = Set.contains(ids, Nat32.compare, id);
        test(
            "a new order joins the set",
            func() {
                let ids = idSet([]);
                OrderExpiry.syncAwaitingPayment(ids, 1, #created);
                OrderExpiry.syncAwaitingPayment(ids, 2, #awaitingPayment);
                expect.text(showIds(Set.toArray(ids))).equal(showIds([1, 2]));
            },
        );
        test(
            "a paid order leaves it, and stays out once fulfilled",
            func() {
                let ids = idSet([1, 2]);
                OrderExpiry.syncAwaitingPayment(ids, 1, #paid);
                expect.bool(contains(ids, 1)).isFalse();
                OrderExpiry.syncAwaitingPayment(ids, 1, #fulfilled);
                expect.bool(contains(ids, 1)).isFalse();
                expect.bool(contains(ids, 2)).isTrue();
            },
        );
        test(
            "a cancelled or expired order leaves it",
            func() {
                // Expiry stores the order as #canceled, like cancelOrder.
                let ids = idSet([1, 2]);
                OrderExpiry.syncAwaitingPayment(ids, 1, #canceled);
                OrderExpiry.syncAwaitingPayment(ids, 2, #canceled);
                expect.nat(Set.size(ids)).equal(0);
            },
        );
        test(
            "a refunded order leaves it",
            func() {
                let ids = idSet([3]);
                OrderExpiry.syncAwaitingPayment(ids, 3, #refunded);
                expect.bool(contains(ids, 3)).isFalse();
            },
        );
        test(
            "holds exactly the orders awaiting payment after any sequence of status changes",
            func() {
                let ids = idSet([]);
                let history : [(Nat32, OrderExpiry.OrderStatus)] = [
                    (1, #created),
                    (2, #created),
                    (3, #created),
                    (4, #created),
                    (5, #created),
                    (1, #paid),
                    (2, #canceled),
                    (1, #fulfilled),
                    (3, #awaitingPayment),
                    (4, #paid),
                    (4, #refunded),
                    // A repeated write of the same status changes nothing.
                    (2, #canceled),
                    (5, #created),
                ];
                for ((id, status) in history.vals()) {
                    OrderExpiry.syncAwaitingPayment(ids, id, status);
                };
                expect.text(showIds(Set.toArray(ids))).equal(showIds([3, 5]));
                // Every status agrees with isAwaitingPayment.
                for (status in [#created, #awaitingPayment, #paid, #processing, #partiallyFulfilled, #fulfilled, #canceled, #refunded].vals()) {
                    OrderExpiry.syncAwaitingPayment(ids, 9, status);
                    expect.bool(contains(ids, 9)).equal(OrderExpiry.isAwaitingPayment(status));
                };
            },
        );

        test(
            "the expiry queue hands out due orders earliest first, a batch at a time",
            func() {
                let queue : OrderExpiry.ExpiryQueue = Set.empty();
                expect.bool(OrderExpiry.nextExpiry(queue) == null).isTrue();
                // Seven orders due at once (a burst), one due later.
                for (id in [7, 3, 5, 1, 6, 2, 4].vals()) {
                    OrderExpiry.scheduleExpiry(queue, deadline, Nat32.fromNat(id));
                };
                OrderExpiry.scheduleExpiry(queue, deadline + 1_000, 9);
                expect.bool(OrderExpiry.nextExpiry(queue) == ?deadline).isTrue();

                // Nothing is due before the deadline.
                expect.text(showIds(OrderExpiry.takeDue(queue, deadline - 1, 5))).equal(showIds([]));

                expect.text(showIds(OrderExpiry.takeDue(queue, deadline, OrderExpiry.EXPIRY_READS_IN_FLIGHT))).equal(showIds([1, 2, 3, 4, 5]));
                expect.text(showIds(OrderExpiry.takeDue(queue, deadline, OrderExpiry.EXPIRY_READS_IN_FLIGHT))).equal(showIds([6, 7]));
                expect.text(showIds(OrderExpiry.takeDue(queue, deadline, OrderExpiry.EXPIRY_READS_IN_FLIGHT))).equal(showIds([]));
                expect.bool(OrderExpiry.nextExpiry(queue) == ?(deadline + 1_000)).isTrue();
            },
        );

        test(
            "an order requeued for a retry comes due again at the retry time",
            func() {
                let queue : OrderExpiry.ExpiryQueue = Set.empty();
                OrderExpiry.scheduleExpiry(queue, deadline, 1);
                expect.text(showIds(OrderExpiry.takeDue(queue, deadline, 5))).equal(showIds([1]));
                let retryAt = deadline + OrderExpiry.RETRY_DELAY_SECONDS * 1_000_000_000;
                OrderExpiry.scheduleExpiry(queue, retryAt, 1);
                expect.text(showIds(OrderExpiry.takeDue(queue, retryAt - 1, 5))).equal(showIds([]));
                expect.text(showIds(OrderExpiry.takeDue(queue, retryAt, 5))).equal(showIds([1]));
                expect.nat(Set.size(queue)).equal(0);
            },
        );
    },
);
