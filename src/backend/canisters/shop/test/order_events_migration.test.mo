import { expect; suite; test } "mo:test";

import Map "mo:map/Map";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import Array "mo:core/Array";
import CoreMap "mo:core/Map";
import Nat "mo:core/Nat";
import Set "mo:core/Set";

import Initial "../migrations/20261101_000000";
import OrderEventsMigration "../migrations/20261116_090000_OrderEvents";

let icp = {
    amount = 100_000_000 : Nat64;
    currency = { class_ = #Cryptocurrency; symbol = "ICP" };
    metadata = { decimals = 8 : Nat32 };
};

// An order as the chain stores it; each test copies it with its own `id` and `status`.
let baseOrder = {
    id : Nat32 = 0;
    buyer = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
    createdAt : Int = 0;
    updatedAt : Int = 0;
    canceledAt : ?Int = null;
    expiresAt : Int = 600_000_000_000;
    items = [];
    totals = {
        subtotal = icp;
        discounts = icp;
        shipping = icp;
        tax = icp;
        total = icp;
    };
    status = #created;
    payment = null;
    shippingAddress = null;
    fulfillment = null;
    notes : ?Text = null;
};

suite(
    "Shop migration OrderEvents (BRE-133)",
    func() {
        test(
            "a fresh install starts with an empty history",
            func() {
                let installed = OrderEventsMigration.migration({
                    orders = Initial.migration({}).orders;
                });
                expect.nat(CoreMap.size(installed.orderEvents.events)).equal(0);
                expect.nat(installed.orderEvents.nextSeq).equal(0);
            },
        );
        test(
            "an upgrade rebuilds each order's recorded times as events, numbered in time order",
            func() {
                let orders = Initial.migration({}).orders;
                // Order 1: created at 100, paid at 300, shipped at 500.
                Map.set(
                    orders,
                    Map.n32hash,
                    1 : Nat32,
                    {
                        baseOrder with id = 1 : Nat32;
                        createdAt = 100;
                        status = #fulfilled;
                        payment = ?{
                            provider = #ICRC1;
                            reference = "ref";
                            amount = icp;
                            status = #captured;
                            paidAt = ?300;
                        };
                        fulfillment = ?{
                            carrier = ?"UPS";
                            trackingNumber = null;
                            date = 500;
                        };
                    },
                );
                // Order 2: created at 200, cancelled at 400.
                Map.set(orders, Map.n32hash, 2 : Nat32, { baseOrder with id = 2 : Nat32; createdAt = 200; status = #canceled; canceledAt = ?400 });
                // Order 3: created at 200 too, still unpaid: ties are broken by order ID.
                Map.set(orders, Map.n32hash, 3 : Nat32, { baseOrder with id = 3 : Nat32; createdAt = 200 });

                let upgraded = OrderEventsMigration.migration({ orders });
                let events = CoreMap.toArray(upgraded.orderEvents.events);
                expect.text(debug_show (events.map(func((seq, e)) = (seq, e.orderId, e.at, e.kind)))).equal(
                    debug_show ([
                        (0, 1 : Nat32, 100 : Int, #created),
                        (1, 2 : Nat32, 200 : Int, #created),
                        (2, 3 : Nat32, 200 : Int, #created),
                        (3, 1 : Nat32, 300 : Int, #paid({ provider = #ICRC1 })),
                        (4, 2 : Nat32, 400 : Int, #canceled({ reason = null })),
                        (5, 1 : Nat32, 500 : Int, #fulfilled({ method = ?#shipped({ carrier = ?"UPS"; trackingNumber = null }) })),
                    ])
                );
                expect.nat(upgraded.orderEvents.nextSeq).equal(6);
                expect.nat(Set.size(upgraded.orderEvents.bySubject)).equal(6);
                expect.nat(Map.size(upgraded.orders)).equal(3);
            },
        );
        test(
            "a fulfilment with no carrier or tracking number is rebuilt with no method",
            func() {
                let orders = Initial.migration({}).orders;
                Map.set(orders, Map.n32hash, 1 : Nat32, { baseOrder with id = 1 : Nat32; status = #fulfilled; fulfillment = ?{ carrier = null; trackingNumber = null; date = 5 } });
                let upgraded = OrderEventsMigration.migration({ orders });
                let ?last = CoreMap.get(upgraded.orderEvents.events, Nat.compare, 1) else return expect.bool(false).isTrue();
                expect.text(debug_show (last.kind)).equal(debug_show (#fulfilled({ method = null })));
            },
        );
    },
);
