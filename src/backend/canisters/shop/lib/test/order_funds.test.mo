import { expect } "mo:test";
import { suite; test } "mo:test";

import Blob "mo:core/Blob";
import Principal "mo:core/Principal";

import Subaccount "../../../../lib/Subaccount";
import OrderExpiry "../order_expiry";
import OrderFunds "../order_funds";

let sweepable : [OrderExpiry.OrderStatus] = [#paid, #processing, #partiallyFulfilled, #fulfilled];
let notSweepable : [OrderExpiry.OrderStatus] = [#created, #awaitingPayment, #canceled, #refunded];

func isOk(result : { #ok; #err : Text }) : Bool {
    switch (result) {
        case (#ok) true;
        case (#err(_)) false;
    };
};

suite(
    "OrderFunds.orderIdOfSubaccount",
    func() {
        test(
            "reads the order ID back from its payment subaccount",
            func() {
                for (id in ([1, 255, 256, 70_000, 4_294_967_295] : [Nat32]).values()) {
                    expect.bool(OrderFunds.orderIdOfSubaccount(?Subaccount.fromNat32(id)) == ?id).isTrue();
                };
            },
        );
        test(
            "ignores the main account",
            func() {
                expect.bool(OrderFunds.orderIdOfSubaccount(null) == null).isTrue();
                expect.bool(OrderFunds.orderIdOfSubaccount(?Subaccount.fromNat32(0)) == null).isTrue();
            },
        );
        test(
            "ignores subaccounts that aren't order payment accounts",
            func() {
                let userSubaccount = Subaccount.fromPrincipal(Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai"));
                expect.bool(OrderFunds.orderIdOfSubaccount(?userSubaccount) == null).isTrue();
                expect.bool(OrderFunds.orderIdOfSubaccount(?Blob.fromArray([0, 0, 0, 1])) == null).isTrue();
            },
        );
    },
);

suite(
    "OrderFunds.canSweepToMain",
    func() {
        test(
            "allows paid orders",
            func() {
                for (status in sweepable.values()) {
                    expect.bool(OrderFunds.canSweepToMain(status)).isTrue();
                };
            },
        );
        test(
            "refuses unpaid, cancelled and refunded orders",
            func() {
                for (status in notSweepable.values()) {
                    expect.bool(OrderFunds.canSweepToMain(status)).isFalse();
                };
            },
        );
    },
);

suite(
    "OrderFunds.sweepDecision",
    func() {
        test(
            "allows accounts that aren't an order's",
            func() {
                expect.bool(isOk(OrderFunds.sweepDecision(null))).isTrue();
            },
        );
        test(
            "allows paid orders' accounts",
            func() {
                for (status in sweepable.values()) {
                    expect.bool(isOk(OrderFunds.sweepDecision(?{ id = 7; status }))).isTrue();
                };
            },
        );
        test(
            "refuses a cancelled order's account and points to reclaimOrderPayment",
            func() {
                switch (OrderFunds.sweepDecision(?{ id = 7; status = #canceled })) {
                    case (#ok) { expect.bool(true).isFalse() };
                    case (#err(message)) {
                        expect.text(message).contains("Order 7");
                        expect.text(message).contains("reclaimOrderPayment");
                    };
                };
            },
        );
        test(
            "refuses unpaid orders' accounts",
            func() {
                for (status in notSweepable.values()) {
                    expect.bool(isOk(OrderFunds.sweepDecision(?{ id = 7; status }))).isFalse();
                };
            },
        );
    },
);
