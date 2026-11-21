// @testmode replica
// Replica mode, for the real Candid decoder: core reads a shop's order events and orders with
// smaller types than the shop sends (BRE-203).
import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Principal "mo:core/Principal";

import ShopInterface "../../../../../interfaces/shop";

// What a shop sends: its full event and order types (`shop/lib/order_events.mo`, `shop/types.mo`),
// with a kind core doesn't know yet. Core's smaller types must decode them (BRE-203).
persistent actor {
    type ShopEvent = {
        seq : Nat;
        orderId : Nat32;
        at : Int;
        by : { #buyer; #merchant; #automatic };
        kind : {
            #created;
            #awaitingPayment : { provider : { #ICRC1; #Manual; #Stripe } };
            #paid : { provider : { #ICRC1; #Manual; #Stripe } };
            #lineDelivered : {
                lineIndex : Nat;
                method : { #digital; #inPerson };
            };
            #fulfilled : { method : ?{ #digital; #inPerson } };
            #partiallyFulfilled;
            #canceled : {
                reason : ?{ #expired; #buyer; #merchant; #paymentMismatch };
            };
            #refunded;
            #disputed : { note : Text };
        };
    };

    type Page<E> = { items : [E]; next : ?Nat };

    public func runTests() : async () {
        await suite(
            "Order log Candid (BRE-203)",
            func() : async () {
                await test(
                    "core reads a shop's order events, and a kind it doesn't know as null",
                    func() : async () {
                        let page : Page<ShopEvent> = {
                            items = [
                                {
                                    seq = 0;
                                    orderId = 7;
                                    at = 10;
                                    by = #buyer;
                                    kind = #paid({ provider = #Stripe });
                                },
                                {
                                    seq = 1;
                                    orderId = 7;
                                    at = 11;
                                    by = #merchant;
                                    kind = #canceled({ reason = ?#merchant });
                                },
                                {
                                    seq = 2;
                                    orderId = 7;
                                    at = 12;
                                    by = #automatic;
                                    kind = #disputed({ note = "x" });
                                },
                            ];
                            next = null;
                        };
                        let ?decoded : ?Page<ShopInterface.OrderEvent> = from_candid (to_candid (page)) else {
                            assert false;
                            return;
                        };
                        expect.nat(decoded.items.size()).equal(3);
                        expect.bool(decoded.items[0].kind == ?#paid({})).isTrue();
                        expect.bool(decoded.items[1].kind == ?#canceled({})).isTrue();
                        expect.bool(decoded.items[2].kind == null).isTrue();
                        expect.nat(decoded.items[2].seq).equal(2);
                    },
                );

                await test(
                    "core reads a shop's full order as its order listing",
                    func() : async () {
                        let money = {
                            currency = {
                                class_ = #FiatCurrency;
                                symbol = "USD";
                            };
                            amount = 100 : Nat64;
                            metadata = { decimals = 2 : Nat32 };
                        };
                        let buyer = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
                        let response : {
                            #ok : {
                                id : Nat32;
                                buyer : Principal;
                                items : [ShopInterface.LineItemSnapshot];
                                totals : ShopInterface.Totals;
                                status : ShopInterface.OrderStatus;
                                shippingAddress : ?{ name : Text; line1 : Text };
                                payment : ?{ #ICRC1 : { token : Text } };
                                createdAt : Int;
                                updatedAt : Int;
                                canceledAt : ?Int;
                                expiresAt : Int;
                                notes : ?Text;
                            };
                            #err : {
                                #NotFoundError : Text;
                                #Unauthorized : Text;
                            };
                        } = #ok({
                            id = 3;
                            buyer;
                            items = [{
                                productId = 1;
                                variantId = 2;
                                title = "Tee";
                                sku = null;
                                options = [("Size", "M")];
                                unitPrice = money;
                                listedPrices = [money];
                                quantity = 1;
                            }];
                            totals = {
                                subtotal = money;
                                discounts = money;
                                tax = money;
                                shipping = money;
                                total = money;
                            };
                            status = #paid;
                            shippingAddress = ?{ name = "A"; line1 = "B" };
                            payment = ?#ICRC1({ token = "ICP" });
                            createdAt = 5;
                            updatedAt = 6;
                            canceledAt = null;
                            expiresAt = 7;
                            notes = null;
                        });
                        let ?decoded : ?ShopInterface.GetOrderResponse = from_candid (to_candid (response)) else {
                            assert false;
                            return;
                        };
                        switch (decoded) {
                            case (#ok(order)) {
                                expect.nat32(order.id).equal(3);
                                expect.principal(order.buyer).equal(buyer);
                                expect.bool(order.status == #paid).isTrue();
                                expect.int(order.createdAt).equal(5);
                                expect.nat(order.items.size()).equal(1);
                            };
                            case (#err(_)) assert false;
                        };
                    },
                );
            },
        );
    };
};
