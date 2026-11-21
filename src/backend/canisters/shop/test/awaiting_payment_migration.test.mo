import { expect; suite; test } "mo:test";

import Map "mo:map/Map";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import Set "mo:core/Set";

import Initial "../migrations/20261101_000000";
import AwaitingPaymentSet "../migrations/20261108_010734_AwaitingPaymentSet";

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
    "Shop migration AwaitingPaymentSet (BRE-100)",
    func() {
        test(
            "a fresh install starts with no order awaiting payment",
            func() {
                let installed = AwaitingPaymentSet.migration(Initial.migration({}));
                expect.nat(Set.size(installed.awaitingPaymentOrderIds)).equal(0);
            },
        );
        test(
            "an upgrade collects exactly the existing orders awaiting payment and keeps every order",
            func() {
                let orders = Initial.migration({}).orders;
                let statuses = [#created, #awaitingPayment, #paid, #processing, #partiallyFulfilled, #fulfilled, #canceled, #refunded, #created];
                var id : Nat32 = 0;
                for (status in statuses.vals()) {
                    id += 1;
                    Map.set(orders, Map.n32hash, id, { baseOrder with id; status });
                };
                let upgraded = AwaitingPaymentSet.migration({ orders });
                expect.text(debug_show (Set.toArray(upgraded.awaitingPaymentOrderIds))).equal(debug_show ([1, 2, 9] : [Nat32]));
                expect.nat(Map.size(upgraded.orders)).equal(statuses.size());
                Set.assertValid(upgraded.awaitingPaymentOrderIds, Nat32.compare);
            },
        );
    },
);
