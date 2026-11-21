import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Set "mo:core/Set";

import OrderEvents "../order_events";

func kinds(events : [OrderEvents.OrderEvent]) : Text = debug_show (events.map(func(e : OrderEvents.OrderEvent) : OrderEvents.OrderEventKind = e.kind));

func seqs(events : [OrderEvents.OrderEvent]) : [Nat] = events.map(func(e : OrderEvents.OrderEvent) : Nat = e.seq);

func lines(indexes : [Nat]) : Set.Set<Nat> = Set.fromIter(indexes.vals(), Nat.compare);

suite(
    "OrderEvents.append and history",
    func() {
        test(
            "numbers events across the shop and keeps each order's own history in order",
            func() {
                let log = OrderEvents.empty();
                ignore OrderEvents.append(log, 1, 10, #buyer, #created);
                ignore OrderEvents.append(log, 2, 11, #buyer, #created);
                ignore OrderEvents.append(log, 1, 12, #automatic, #paid({ provider = #ICRC1 }));
                let fulfilled = OrderEvents.append(log, 1, 13, #merchant, #fulfilled({ method = ?#inPerson }));

                expect.nat(fulfilled.seq).equal(3);
                expect.nat(log.nextSeq).equal(4);
                expect.text(kinds(OrderEvents.history(log, 1))).equal(
                    kinds([
                        {
                            seq = 0;
                            orderId = 1;
                            at = 10;
                            by = #buyer;
                            kind = #created;
                        },
                        {
                            seq = 2;
                            orderId = 1;
                            at = 12;
                            by = #automatic;
                            kind = #paid({ provider = #ICRC1 });
                        },
                        fulfilled,
                    ])
                );
                expect.array<Nat>(seqs(OrderEvents.history(log, 1)), Nat.toText, Nat.equal).equal([0, 2, 3]);
                expect.array<Nat>(seqs(OrderEvents.history(log, 2)), Nat.toText, Nat.equal).equal([1]);
            },
        );
        test(
            "returns no history for an order with no events",
            func() {
                let log = OrderEvents.empty();
                ignore OrderEvents.append(log, 1, 10, #buyer, #created);
                expect.nat(OrderEvents.history(log, 0).size()).equal(0);
                expect.nat(OrderEvents.history(log, 2).size()).equal(0);
            },
        );
    },
);

suite(
    "OrderEvents.listAfter",
    func() {
        let log = OrderEvents.empty();
        for (i in Nat.range(0, 5)) {
            ignore OrderEvents.append(log, 1, i, #automatic, #created);
        };
        test(
            "pages the whole log oldest first from a cursor",
            func() {
                let first = OrderEvents.listAfter(log, null, ?2);
                expect.array<Nat>(seqs(first.items), Nat.toText, Nat.equal).equal([0, 1]);
                expect.option<Nat>(first.next, Nat.toText, Nat.equal).equal(?1);
                let second = OrderEvents.listAfter(log, first.next, ?2);
                expect.array<Nat>(seqs(second.items), Nat.toText, Nat.equal).equal([2, 3]);
                let last = OrderEvents.listAfter(log, second.next, ?2);
                expect.array<Nat>(seqs(last.items), Nat.toText, Nat.equal).equal([4]);
                expect.option<Nat>(last.next, Nat.toText, Nat.equal).isNull();
            },
        );
        test(
            "is empty after the last event",
            func() {
                expect.nat(OrderEvents.listAfter(log, ?4, null).items.size()).equal(0);
            },
        );
    },
);

suite(
    "OrderEvents.deliveredLines",
    func() {
        test(
            "collects each delivered line once",
            func() {
                let log = OrderEvents.empty();
                ignore OrderEvents.append(log, 1, 0, #buyer, #lineDelivered({ lineIndex = 2; method = #digital }));
                ignore OrderEvents.append(log, 2, 0, #buyer, #lineDelivered({ lineIndex = 0; method = #digital }));
                ignore OrderEvents.append(log, 1, 1, #buyer, #lineDelivered({ lineIndex = 0; method = #digital }));
                expect.array<Nat>(Set.toArray(OrderEvents.deliveredLines(log, 1)), Nat.toText, Nat.equal).equal([0, 2]);
            },
        );
    },
);

suite(
    "OrderEvents.fulfilmentStatus",
    func() {
        test(
            "is unchanged with nothing delivered",
            func() {
                expect.bool(OrderEvents.fulfilmentStatus(2, lines([])) == null).isTrue();
            },
        );
        test(
            "is partially fulfilled with some lines delivered",
            func() {
                expect.bool(OrderEvents.fulfilmentStatus(2, lines([1])) == ?#partiallyFulfilled).isTrue();
            },
        );
        test(
            "is fulfilled once every line is delivered",
            func() {
                expect.bool(OrderEvents.fulfilmentStatus(2, lines([0, 1])) == ?#fulfilled).isTrue();
            },
        );
        test(
            "ignores line indexes past the end of the order",
            func() {
                expect.bool(OrderEvents.fulfilmentStatus(1, lines([3])) == null).isTrue();
            },
        );
    },
);

suite(
    "OrderEvents.commonMethod",
    func() {
        test(
            "is the shared method when every line went out the same way",
            func() {
                expect.bool(OrderEvents.commonMethod([#digital, #digital]) == ?#digital).isTrue();
            },
        );
        test(
            "is null for mixed methods or none",
            func() {
                expect.bool(OrderEvents.commonMethod([#digital, #inPerson]) == null).isTrue();
                expect.bool(OrderEvents.commonMethod([]) == null).isTrue();
            },
        );
    },
);
