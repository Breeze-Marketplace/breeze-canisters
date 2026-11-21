// @testmode replica
// Replica mode, for real callbacks: a subscriber's callback stored with the old `OrderUpdated` event
// type is re-typed by the migration and still takes the new event, extra field and all (BRE-203).
import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Map "mo:map/Map";
import Principal "mo:core/Principal";

import Migration "../migrations/20261121_120650_OrderLogEvents";

persistent actor Self {
    type Money = {
        currency : {
            class_ : { #Cryptocurrency; #FiatCurrency };
            symbol : Text;
        };
        amount : Nat64;
        metadata : { decimals : Nat32 };
    };
    type OldEvent = {
        data : {
            orderId : Nat32;
            buyer : Principal;
            items : [{
                productId : Nat32;
                variantId : Nat32;
                title : Text;
                sku : ?Text;
                options : [(Text, Text)];
                unitPrice : Money;
                listedPrices : [Money];
                quantity : Nat32;
            }];
            totals : {
                subtotal : Money;
                discounts : Money;
                tax : Money;
                shipping : Money;
                total : Money;
            };
            status : {
                #created;
                #awaitingPayment;
                #paid;
                #processing;
                #partiallyFulfilled;
                #fulfilled;
                #canceled;
                #refunded;
            };
            createdAt : Int;
        };
    };

    var received : [Nat32] = [];

    /// A subscriber that knows only the old event, as core's `trackOrder` before BRE-203.
    public shared func oldListener(event : OldEvent) : async () {
        received := [event.data.orderId];
    };

    public func runTests() : async () {
        await suite(
            "OrderLogEvents migration (BRE-203)",
            func() : async () {
                await test(
                    "keeps every OrderUpdated subscription, and an old callback takes the new event",
                    func() : async () {
                        let subscriber = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
                        let old = Map.new<Principal, shared OldEvent -> async ()>();
                        Map.set(old, Map.phash, subscriber, Self.oldListener);

                        let next = Migration.migration({
                            orderUpdatedSubscribers = old;
                        });
                        expect.nat(Map.size(next.orderUpdatedSubscribers)).equal(1);

                        let ?listener = Map.get(next.orderUpdatedSubscribers, Map.phash, subscriber) else {
                            assert false;
                            return;
                        };
                        let money = {
                            currency = {
                                class_ = #FiatCurrency;
                                symbol = "USD";
                            };
                            amount = 0 : Nat64;
                            metadata = { decimals = 2 : Nat32 };
                        };
                        await listener({
                            data = {
                                orderId = 42;
                                buyer = subscriber;
                                items = [];
                                totals = {
                                    subtotal = money;
                                    discounts = money;
                                    tax = money;
                                    shipping = money;
                                    total = money;
                                };
                                status = #paid;
                                createdAt = 1;
                                logEvent = ?{ seq = 7; at = 1 };
                            };
                        });
                        expect.bool(received == [42]).isTrue();
                    },
                );
            },
        );
    };
};
