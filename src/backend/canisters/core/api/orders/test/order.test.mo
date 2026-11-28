import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Array "mo:core/Array";
import Error "mo:core/Error";
import Iter "mo:core/Iter";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Time "mo:core/Time";

import CoreSet "mo:core/Set";
import Map "mo:map/Map";
import Set "mo:map/Set";

import MockLogger "../../../../../lib/Logger/mock";
import OrderAPI "../lib";
import ShopInterface "../../../../../interfaces/shop";

/// The order IDs in `buyer`'s index, in index order (newest first).
func buyerOrderIds(dependencies : OrderAPI.Dependencies, buyer : Principal) : [Nat32] {
    switch (Map.get(dependencies.ordersByBuyer, Map.phash, buyer)) {
        case (?cursors) {
            CoreSet.values(cursors).map(func(c : OrderAPI.UserOrderCursor) : Nat32 = c.orderId).toArray();
        };
        case null { [] };
    };
};

suite(
    "OrderAPI",
    func() : async () {
        await suite(
            "getUserOrders",
            func() : async () {
                let userA = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
                let userB = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
                let usd = {
                    class_ = #FiatCurrency;
                    symbol = "USD";
                };
                let usdAmount = func(amount : Nat64) : ShopInterface.Money {
                    {
                        currency = usd;
                        amount = amount;
                        metadata = { decimals = 2 };
                    };
                };
                let orders : [(OrderAPI.OrderKey, OrderAPI.Order)] = [
                    (
                        "aaaaa-aa:1",
                        {
                            id = 1;
                            shopId = Principal.fromText("aaaaa-aa");
                            buyer = userA;
                            items = [];
                            totals = {
                                subtotal = usdAmount(0);
                                discounts = usdAmount(0);
                                tax = usdAmount(0);
                                shipping = usdAmount(0);
                                total = usdAmount(0);
                            };
                            status = #created;
                            createdAt = Time.now();
                        },
                    ),
                    (
                        "aaaaa-aa:2",
                        {
                            id = 2;
                            shopId = Principal.fromText("aaaaa-aa");
                            buyer = userA;
                            items = [];
                            totals = {
                                subtotal = usdAmount(0);
                                discounts = usdAmount(0);
                                tax = usdAmount(0);
                                shipping = usdAmount(0);
                                total = usdAmount(0);
                            };
                            status = #created;
                            createdAt = Time.now();
                        },
                    ),
                    (
                        "aaaaa-aa:3",
                        {
                            id = 3;
                            shopId = Principal.fromText("aaaaa-aa");
                            buyer = userB;
                            items = [];
                            totals = {
                                subtotal = usdAmount(0);
                                discounts = usdAmount(0);
                                tax = usdAmount(0);
                                shipping = usdAmount(0);
                                total = usdAmount(0);
                            };
                            status = #created;
                            createdAt = Time.now();
                        },
                    ),
                ];

                let defaultDependencies : OrderAPI.Dependencies = {
                    orders = Map.fromIter<OrderAPI.OrderKey, OrderAPI.Order>(Array.values(orders), Map.thash);
                    ordersByBuyer = Map.new<Principal, CoreSet.Set<OrderAPI.UserOrderCursor>>();
                    unsubscribedShops = Set.new<Principal>();
                    catchUp = OrderAPI.emptyCatchUpState();
                    shopApi = {
                        getShopName = func(_ : Principal) : Text {
                            "Test Shop";
                        };
                        isRegisteredShop = func(_ : Principal) : Bool {
                            true;
                        };
                    };
                    logger = MockLogger.bind(MockLogger.new(Principal.fromText("aaaaa-aa")));
                };
                for ((_, order) in orders.values()) {
                    OrderAPI.indexOrderForBuyer(OrderAPI.API(defaultDependencies), order);
                };

                await test(
                    "returns error for unauthenticated caller",
                    func() : async () {
                        let api = OrderAPI.API(defaultDependencies);
                        let caller = Principal.anonymous();
                        let res = OrderAPI.getUserOrders(api, caller, null, null);
                        assert (res == #err(#Unauthenticated));
                    },
                );

                await test(
                    "returns empty list for authenticated caller with no orders",
                    func() : async () {
                        let api = OrderAPI.API(defaultDependencies);
                        let caller = Principal.fromText("aaaaa-aa");
                        let res = OrderAPI.getUserOrders(api, caller, null, null);
                        assert (res == #ok({ items = []; next = null }));
                    },
                );

                await test(
                    "returns orders for authenticated caller, newest first",
                    func() : async () {
                        let api = OrderAPI.API(defaultDependencies);
                        let res = switch (OrderAPI.getUserOrders(api, userA, null, null)) {
                            case (#ok(page)) { page.items };
                            case (#err(_)) {
                                assert false;
                                return;
                            };
                        };
                        let expected : [OrderAPI.UserOrderListing] = [
                            {
                                shopCanisterId = Principal.fromText("aaaaa-aa");
                                shopName = "Test Shop";
                                order = {
                                    id = 2;
                                    shopId = Principal.fromText("aaaaa-aa");
                                    buyer = userA;
                                    items = [];
                                    totals = {
                                        subtotal = usdAmount(0);
                                        discounts = usdAmount(0);
                                        tax = usdAmount(0);
                                        shipping = usdAmount(0);
                                        total = usdAmount(0);
                                    };
                                    status = #created;
                                    createdAt = Time.now();
                                };
                            },
                            {
                                shopCanisterId = Principal.fromText("aaaaa-aa");
                                shopName = "Test Shop";
                                order = {
                                    id = 1;
                                    shopId = Principal.fromText("aaaaa-aa");
                                    buyer = userA;
                                    items = [];
                                    totals = {
                                        subtotal = usdAmount(0);
                                        discounts = usdAmount(0);
                                        tax = usdAmount(0);
                                        shipping = usdAmount(0);
                                        total = usdAmount(0);
                                    };
                                    status = #created;
                                    createdAt = Time.now();
                                };
                            },
                        ];

                        func validateOrderListing(actual : OrderAPI.UserOrderListing, expected : OrderAPI.UserOrderListing) {
                            expect.principal(actual.shopCanisterId).equal(expected.shopCanisterId);
                            expect.text(actual.shopName).equal(expected.shopName);
                            expect.nat32(actual.order.id).equal(expected.order.id);
                            expect.principal(actual.order.shopId).equal(expected.order.shopId);
                            expect.principal(actual.order.buyer).equal(expected.order.buyer);
                            expect.nat64(actual.order.totals.total.amount).equal(expected.order.totals.total.amount);
                            expect.text(actual.order.totals.total.currency.symbol).equal(expected.order.totals.total.currency.symbol);
                            expect.nat32(actual.order.totals.total.metadata.decimals).equal(expected.order.totals.total.metadata.decimals);
                            assert (actual.order.status == expected.order.status);
                            assert (actual.order.createdAt > 0 and actual.order.createdAt <= expected.order.createdAt); // allow for slight timing differences in test setup
                        };

                        validateOrderListing(res.get(0), expected[0]);
                        validateOrderListing(res.get(1), expected[1]);
                    },
                );
            },
        );

        await suite(
            "trackOrder",
            func() : async () {
                let shopId = Principal.fromText("aaaaa-aa");
                let buyer = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
                let usd = {
                    class_ = #FiatCurrency;
                    symbol = "USD";
                };
                let usdAmount = func(amount : Nat64) : ShopInterface.Money {
                    {
                        currency = usd;
                        amount = amount;
                        metadata = { decimals = 2 };
                    };
                };
                let zeroTotals = {
                    subtotal = usdAmount(0);
                    discounts = usdAmount(0);
                    tax = usdAmount(0);
                    shipping = usdAmount(0);
                    total = usdAmount(1000);
                };
                let createdAt = Time.now();

                func makeTrackOrderRequest(orderId : Nat32, status : ShopInterface.OrderStatus) : OrderAPI.TrackOrderRequest {
                    {
                        data = {
                            orderId;
                            buyer;
                            items = [];
                            totals = zeroTotals;
                            status;
                            createdAt;
                            logEvent = null;
                        };
                    };
                };

                func makeDependencies(isRegisteredShop : ?(Principal -> Bool)) : OrderAPI.Dependencies {
                    {
                        orders = Map.new<OrderAPI.OrderKey, OrderAPI.Order>();
                        ordersByBuyer = Map.new<Principal, CoreSet.Set<OrderAPI.UserOrderCursor>>();
                        unsubscribedShops = Set.new<Principal>();
                        catchUp = OrderAPI.emptyCatchUpState();
                        shopApi = {
                            getShopName = func(_ : Principal) : Text {
                                "Test Shop";
                            };
                            isRegisteredShop = switch (isRegisteredShop) {
                                case (?fn) { fn };
                                case (null) {
                                    func(_ : Principal) : Bool { true };
                                };
                            };
                        };
                        logger = MockLogger.bind(MockLogger.new(shopId));
                    };
                };

                await test(
                    "no-ops for anonymous shop caller",
                    func() : async () {
                        let dependencies = makeDependencies(null);
                        let api = OrderAPI.API(dependencies);
                        let req = makeTrackOrderRequest(1, #created);

                        OrderAPI.trackOrder(api, Principal.anonymous(), req);

                        expect.nat(Map.size(dependencies.orders)).equal(0);
                        expect.nat(Map.size(dependencies.ordersByBuyer)).equal(0);
                    },
                );

                await test(
                    "no-ops when shop is not registered",
                    func() : async () {
                        func isRegisteredShop(_ : Principal) : Bool {
                            false;
                        };
                        let dependencies = makeDependencies(?isRegisteredShop);
                        let api = OrderAPI.API(dependencies);
                        let req = makeTrackOrderRequest(1, #created);

                        OrderAPI.trackOrder(api, shopId, req);

                        expect.nat(Map.size(dependencies.orders)).equal(0);
                        expect.nat(Map.size(dependencies.ordersByBuyer)).equal(0);
                    },
                );

                await test(
                    "no-ops for anonymous buyer",
                    func() : async () {
                        let dependencies = makeDependencies(null);
                        let api = OrderAPI.API(dependencies);
                        let req = {
                            data = {
                                orderId = 1 : Nat32;
                                buyer = Principal.anonymous();
                                items = [];
                                totals = zeroTotals;
                                status = #created;
                                createdAt;
                                logEvent = null;
                            };
                        };

                        OrderAPI.trackOrder(api, shopId, req);

                        expect.nat(Map.size(dependencies.orders)).equal(0);
                        expect.nat(Map.size(dependencies.ordersByBuyer)).equal(0);
                    },
                );

                await test(
                    "stores new order and indexes buyer",
                    func() : async () {
                        let dependencies = makeDependencies(null);
                        let api = OrderAPI.API(dependencies);
                        let req = makeTrackOrderRequest(42, #created);
                        let expectedKey = OrderAPI.buildOrderKey(shopId, 42);

                        OrderAPI.trackOrder(api, shopId, req);

                        let storedOrder = Option.unwrap(Map.get(dependencies.orders, Map.thash, expectedKey));
                        expect.nat32(storedOrder.id).equal(42);
                        expect.principal(storedOrder.shopId).equal(shopId);
                        expect.principal(storedOrder.buyer).equal(buyer);
                        expect.nat64(storedOrder.totals.total.amount).equal(1000);
                        assert (storedOrder.status == #created);

                        let buyerKeys = buyerOrderIds(dependencies, buyer);
                        expect.array(buyerKeys, Nat32.toText, Nat32.equal).equal([storedOrder.id]);
                    },
                );

                await test(
                    "updates existing order without duplicating buyer index",
                    func() : async () {
                        let dependencies = makeDependencies(null);
                        let api = OrderAPI.API(dependencies);
                        let expectedKey = OrderAPI.buildOrderKey(shopId, 7);

                        OrderAPI.trackOrder(api, shopId, makeTrackOrderRequest(7, #created));
                        OrderAPI.trackOrder(api, shopId, makeTrackOrderRequest(7, #paid));

                        let storedOrder = Option.unwrap(Map.get(dependencies.orders, Map.thash, expectedKey));
                        assert (storedOrder.status == #paid);

                        let buyerKeys = buyerOrderIds(dependencies, buyer);
                        expect.array(buyerKeys, Nat32.toText, Nat32.equal).equal([storedOrder.id]);
                    },
                );

                await test(
                    "tracked order appears in getUserOrders",
                    func() : async () {
                        let dependencies = makeDependencies(null);
                        let api = OrderAPI.API(dependencies);

                        OrderAPI.trackOrder(api, shopId, makeTrackOrderRequest(99, #awaitingPayment));

                        let listings = switch (OrderAPI.getUserOrders(api, buyer, null, null)) {
                            case (#ok(page)) { page.items };
                            case (#err(_)) {
                                assert false;
                                return;
                            };
                        };

                        expect.nat(listings.size()).equal(1);
                        expect.nat32(listings[0].order.id).equal(99);
                        expect.text(listings[0].shopName).equal("Test Shop");
                        assert (listings[0].order.status == #awaitingPayment);
                    },
                );

                await test(
                    "getUserOrders pages newest first from the cursor (BRE-96)",
                    func() : async () {
                        let dependencies = makeDependencies(null);
                        let api = OrderAPI.API(dependencies);
                        for (id in ([1, 2, 3] : [Nat32]).vals()) {
                            OrderAPI.trackOrder(api, shopId, makeTrackOrderRequest(id, #paid));
                        };
                        var after : ?OrderAPI.UserOrderCursor = null;
                        var ids : [Nat32] = [];
                        var pages = 0;
                        label walk loop {
                            let #ok(page) = OrderAPI.getUserOrders(api, buyer, after, ?1) else return assert false;
                            pages += 1;
                            ids := Array.concat(ids, Array.map<OrderAPI.UserOrderListing, Nat32>(page.items, func(l) = l.order.id));
                            switch (page.next) {
                                case null { break walk };
                                case (?c) { after := ?c };
                            };
                        };
                        // Same createdAt: ties go to the higher order ID first.
                        expect.array(ids, Nat32.toText, Nat32.equal).equal([3, 2, 1]);
                        expect.nat(pages).equal(3);
                    },
                );
            },
        );

        await suite(
            "indexOrderForBuyer",
            func() : async () {
                let shopId = Principal.fromText("aaaaa-aa");
                let buyerA = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
                let buyerB = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
                let zero = {
                    currency = { class_ = #FiatCurrency; symbol = "USD" };
                    amount = 0 : Nat64;
                    metadata = { decimals = 2 : Nat32 };
                };

                func order(id : Nat32, buyer : Principal, createdAt : Int) : OrderAPI.Order {
                    {
                        id;
                        shopId;
                        buyer;
                        items = [];
                        totals = {
                            subtotal = zero;
                            discounts = zero;
                            tax = zero;
                            shipping = zero;
                            total = zero;
                        };
                        status = #created;
                        createdAt;
                    };
                };

                func makeDependencies() : OrderAPI.Dependencies {
                    {
                        orders = Map.new<OrderAPI.OrderKey, OrderAPI.Order>();
                        ordersByBuyer = Map.new<Principal, CoreSet.Set<OrderAPI.UserOrderCursor>>();
                        unsubscribedShops = Set.new<Principal>();
                        catchUp = OrderAPI.emptyCatchUpState();
                        shopApi = {
                            getShopName = func(_ : Principal) : Text {
                                "Test Shop";
                            };
                            isRegisteredShop = func(_ : Principal) : Bool {
                                true;
                            };
                        };
                        logger = MockLogger.bind(MockLogger.new(shopId));
                    };
                };

                await test(
                    "adds the order for a buyer with no existing index",
                    func() : async () {
                        let dependencies = makeDependencies();
                        let api = OrderAPI.API(dependencies);

                        OrderAPI.indexOrderForBuyer(api, order(1, buyerA, 10));

                        expect.array(buyerOrderIds(dependencies, buyerA), Nat32.toText, Nat32.equal).equal([1]);
                    },
                );

                await test(
                    "keeps a buyer's orders newest first",
                    func() : async () {
                        let dependencies = makeDependencies();
                        let api = OrderAPI.API(dependencies);

                        OrderAPI.indexOrderForBuyer(api, order(1, buyerA, 10));
                        OrderAPI.indexOrderForBuyer(api, order(2, buyerA, 30));
                        OrderAPI.indexOrderForBuyer(api, order(3, buyerA, 20));

                        expect.array(buyerOrderIds(dependencies, buyerA), Nat32.toText, Nat32.equal).equal([2, 3, 1]);
                    },
                );

                await test(
                    "does not duplicate an order already indexed for buyer",
                    func() : async () {
                        let dependencies = makeDependencies();
                        let api = OrderAPI.API(dependencies);

                        OrderAPI.indexOrderForBuyer(api, order(1, buyerA, 10));
                        OrderAPI.indexOrderForBuyer(api, order(1, buyerA, 10));

                        expect.array(buyerOrderIds(dependencies, buyerA), Nat32.toText, Nat32.equal).equal([1]);
                    },
                );

                await test(
                    "indexes orders independently per buyer",
                    func() : async () {
                        let dependencies = makeDependencies();
                        let api = OrderAPI.API(dependencies);

                        OrderAPI.indexOrderForBuyer(api, order(1, buyerA, 10));
                        OrderAPI.indexOrderForBuyer(api, order(2, buyerA, 20));
                        OrderAPI.indexOrderForBuyer(api, order(3, buyerB, 30));

                        expect.array(buyerOrderIds(dependencies, buyerA), Nat32.toText, Nat32.equal).equal([2, 1]);
                        expect.array(buyerOrderIds(dependencies, buyerB), Nat32.toText, Nat32.equal).equal([3]);
                    },
                );
            },
        );

        await suite(
            "shop subscriptions",
            func() : async () {
                let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                let otherShopId = Principal.fromText("aaaaa-aa");
                let buyer = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
                let usdAmount = func(amount : Nat64) : ShopInterface.Money {
                    {
                        currency = { class_ = #FiatCurrency; symbol = "USD" };
                        amount;
                        metadata = { decimals = 2 };
                    };
                };
                let totals = {
                    subtotal = usdAmount(2500);
                    discounts = usdAmount(0);
                    tax = usdAmount(0);
                    shipping = usdAmount(0);
                    total = usdAmount(2500);
                };

                // Stands in for core's shop registry: shops core created or registered
                func makeDependencies(registeredShops : Set.Set<Principal>) : OrderAPI.Dependencies {
                    {
                        orders = Map.new<OrderAPI.OrderKey, OrderAPI.Order>();
                        ordersByBuyer = Map.new<Principal, CoreSet.Set<OrderAPI.UserOrderCursor>>();
                        unsubscribedShops = Set.new<Principal>();
                        catchUp = OrderAPI.emptyCatchUpState();
                        shopApi = {
                            getShopName = func(_ : Principal) : Text {
                                "Hosted Shop";
                            };
                            isRegisteredShop = func(p : Principal) : Bool {
                                Set.has(registeredShops, Set.phash, p);
                            };
                        };
                        logger = MockLogger.bind(MockLogger.new(shopId));
                    };
                };

                // Fake shops' order-updated subscriber lists. Subscribing stores a listener that, like
                // core's `trackOrder` endpoint, is called with the shop as the caller.
                func makeShops(api : OrderAPI.API) : {
                    subscribe : OrderAPI.SubscribeToShopEvents;
                    placeOrder : (Principal, Nat32) -> ();
                    subscribeCalls : () -> Nat;
                } {
                    let listeners = Map.new<Principal, OrderAPI.TrackOrderRequest -> ()>();
                    var calls = 0;
                    {
                        subscribe = func(id : Principal) : async () {
                            calls += 1;
                            Map.set(
                                listeners,
                                Map.phash,
                                id,
                                func(req : OrderAPI.TrackOrderRequest) {
                                    OrderAPI.trackOrder(api, id, req);
                                },
                            );
                        };
                        placeOrder = func(id : Principal, orderId : Nat32) {
                            switch (Map.get(listeners, Map.phash, id)) {
                                case (?notify) {
                                    notify({
                                        data = {
                                            orderId;
                                            buyer;
                                            items = [];
                                            totals;
                                            status = #awaitingPayment;
                                            createdAt = Time.now();
                                            logEvent = null;
                                        };
                                    });
                                };
                                case (null) {};
                            };
                        };
                        subscribeCalls = func() : Nat { calls };
                    };
                };

                func failingSubscribe(_ : Principal) : async () {
                    throw Error.reject("shop unavailable");
                };

                // A shop whose order log is empty: the catch-up after a subscribe has nothing to do.
                let emptyOrderLog : OrderAPI.OrderLogHooks = {
                    listOrderEvents = func(_ : Principal, _ : ?Nat, _ : ?Nat) : async {
                        items : [ShopInterface.OrderEvent];
                        next : ?Nat;
                    } { { items = []; next = null } };
                    getOrder = func(_ : Principal, _ : Nat32) : async ShopInterface.GetOrderResponse {
                        Runtime.trap("must not read an order");
                    };
                };

                func buyerOrderIds(api : OrderAPI.API) : [Nat32] {
                    switch (OrderAPI.getUserOrders(api, buyer, null, null)) {
                        case (#ok(listings)) {
                            Array.map<OrderAPI.UserOrderListing, Nat32>(listings.items, func(l) { l.order.id });
                        };
                        case (#err(_)) { Runtime.trap("expected #ok") };
                    };
                };

                await test(
                    "an order placed in a core-created shop shows up in the buyer's orders",
                    func() : async () {
                        // Core registers the shop it created, then subscribes to its events.
                        let registered = Set.fromIter<Principal>([shopId].values(), Set.phash);
                        let api = OrderAPI.API(makeDependencies(registered));
                        let shops = makeShops(api);

                        let res = await OrderAPI.subscribeShop(api, shopId, shops.subscribe);
                        expect.result<(), Text>(res, func(_) { "" }, func(a, b) { a == b }).isOk();

                        shops.placeOrder(shopId, 7);

                        expect.array<Nat32>(buyerOrderIds(api), Nat32.toText, Nat32.equal).equal([7]);
                        let listings = switch (OrderAPI.getUserOrders(api, buyer, null, null)) {
                            case (#ok(page)) { page.items };
                            case (#err(_)) { Runtime.trap("expected #ok") };
                        };
                        expect.principal(listings[0].shopCanisterId).equal(shopId);
                        expect.text(listings[0].shopName).equal("Hosted Shop");
                        expect.array<Principal>(OrderAPI.listUnsubscribedShops(api), Principal.toText, Principal.equal).equal([]);
                    },
                );

                await test(
                    "a failed subscription is recorded instead of thrown",
                    func() : async () {
                        let registered = Set.fromIter<Principal>([shopId].values(), Set.phash);
                        let api = OrderAPI.API(makeDependencies(registered));

                        let res = await OrderAPI.subscribeShop(api, shopId, failingSubscribe);

                        switch (res) {
                            case (#err(msg)) {
                                expect.text(msg).equal("shop unavailable");
                            };
                            case (#ok) { Runtime.trap("expected #err") };
                        };
                        expect.array<Principal>(OrderAPI.listUnsubscribedShops(api), Principal.toText, Principal.equal).equal([shopId]);
                    },
                );

                await test(
                    "resubscribeShops backfills an unsubscribed shop and clears its record",
                    func() : async () {
                        let registered = Set.fromIter<Principal>([shopId].values(), Set.phash);
                        let api = OrderAPI.API(makeDependencies(registered));
                        let shops = makeShops(api);
                        ignore await OrderAPI.subscribeShop(api, shopId, failingSubscribe);

                        // Before the backfill the shop has no listener, so its order is lost
                        shops.placeOrder(shopId, 1);
                        expect.nat(buyerOrderIds(api).size()).equal(0);

                        let results = await OrderAPI.resubscribeShops(api, [shopId], shops.subscribe, emptyOrderLog);

                        expect.nat(results.size()).equal(1);
                        expect.principal(results[0].shopId).equal(shopId);
                        expect.bool(results[0].result == #ok).isTrue();
                        expect.array<Principal>(OrderAPI.listUnsubscribedShops(api), Principal.toText, Principal.equal).equal([]);

                        shops.placeOrder(shopId, 2);
                        expect.array<Nat32>(buyerOrderIds(api), Nat32.toText, Nat32.equal).equal([2]);
                    },
                );

                await test(
                    "resubscribeShops skips unregistered shops",
                    func() : async () {
                        let registered = Set.fromIter<Principal>([shopId].values(), Set.phash);
                        let api = OrderAPI.API(makeDependencies(registered));
                        let shops = makeShops(api);

                        let results = await OrderAPI.resubscribeShops(api, [otherShopId, shopId], shops.subscribe, emptyOrderLog);

                        expect.nat(results.size()).equal(2);
                        expect.bool(results[0].result == #err("Shop is not registered")).isTrue();
                        expect.bool(results[1].result == #ok).isTrue();
                        expect.bool(results[0].orders == #notRegistered).isTrue();
                        expect.bool(results[1].orders == #caughtUp({ events = 0; fetched = 0; pending = 0; complete = true; restarted = false })).isTrue();
                        expect.nat(shops.subscribeCalls()).equal(1);
                    },
                );

                // A shop that reports `events` as core's subscriptions, with counters for the
                // resubscribe and product sync that a missing event should trigger.
                func makeCheckHooks(events : [ShopInterface.EventKind], subscribe : OrderAPI.SubscribeToShopEvents) : {
                    hooks : OrderAPI.SubscriptionCheckHooks;
                    syncs : () -> Nat;
                } {
                    var syncs = 0;
                    {
                        hooks = {
                            orderLog = emptyOrderLog;
                            getSubscriptions = func(_ : Principal) : async [ShopInterface.EventKind] {
                                events;
                            };
                            subscribe;
                            syncProducts = func(_ : Principal) : async Result.Result<(), Text> {
                                syncs += 1;
                                #ok;
                            };
                        };
                        syncs = func() : Nat { syncs };
                    };
                };

                await test(
                    "checkShopSubscription leaves a fully subscribed shop alone",
                    func() : async () {
                        let api = OrderAPI.API(makeDependencies(Set.fromIter<Principal>([shopId].values(), Set.phash)));
                        let shops = makeShops(api);
                        let check = makeCheckHooks(OrderAPI.SHOP_EVENTS, shops.subscribe);

                        let result = await OrderAPI.checkShopSubscription(api, shopId, check.hooks);

                        expect.bool(result == #subscribed).isTrue();
                        expect.nat(shops.subscribeCalls()).equal(0);
                        expect.nat(check.syncs()).equal(0);
                    },
                );

                await test(
                    "checkShopSubscription resubscribes and resyncs a shop that dropped core",
                    func() : async () {
                        let api = OrderAPI.API(makeDependencies(Set.fromIter<Principal>([shopId].values(), Set.phash)));
                        let shops = makeShops(api);
                        // As if the shop was reinstalled, or its Owner removed core from two events.
                        let check = makeCheckHooks([#ShopDetailsUpdated, #ProductDeleted], shops.subscribe);

                        let result = await OrderAPI.checkShopSubscription(api, shopId, check.hooks);

                        switch (result) {
                            case (#resubscribed({ missing; productSync })) {
                                expect.bool(missing == [#ProductUpdated, #OrderUpdated]).isTrue();
                                expect.bool(productSync == #ok).isTrue();
                            };
                            case _ Runtime.trap("expected #resubscribed");
                        };
                        expect.nat(shops.subscribeCalls()).equal(1);
                        expect.nat(check.syncs()).equal(1);

                        shops.placeOrder(shopId, 4);
                        expect.array<Nat32>(buyerOrderIds(api), Nat32.toText, Nat32.equal).equal([4]);
                    },
                );

                await test(
                    "checkShopSubscription records a shop it can't resubscribe to, and resyncs and clears it once subscribed",
                    func() : async () {
                        let api = OrderAPI.API(makeDependencies(Set.fromIter<Principal>([shopId].values(), Set.phash)));
                        let lost = makeCheckHooks([], failingSubscribe);

                        switch (await OrderAPI.checkShopSubscription(api, shopId, lost.hooks)) {
                            case (#resubscribeFailed({ error })) expect.text(error).equal("shop unavailable");
                            case _ Runtime.trap("expected #resubscribeFailed");
                        };
                        expect.nat(lost.syncs()).equal(0);
                        expect.array<Principal>(OrderAPI.listUnsubscribedShops(api), Principal.toText, Principal.equal).equal([shopId]);

                        // Its owner subscribed core again some other way.
                        let back = makeCheckHooks(OrderAPI.SHOP_EVENTS, failingSubscribe);
                        expect.bool((await OrderAPI.checkShopSubscription(api, shopId, back.hooks)) == #resynced({ productSync = #ok })).isTrue();
                        expect.nat(back.syncs()).equal(1);
                        expect.array<Principal>(OrderAPI.listUnsubscribedShops(api), Principal.toText, Principal.equal).equal([]);
                    },
                );

                await test(
                    "checkShopSubscription keeps a shop listed until its products resync, and retries the resync",
                    func() : async () {
                        let api = OrderAPI.API(makeDependencies(Set.fromIter<Principal>([shopId].values(), Set.phash)));
                        let shops = makeShops(api);
                        var events : [ShopInterface.EventKind] = [];
                        var syncFails = true;
                        var syncs = 0;
                        let hooks : OrderAPI.SubscriptionCheckHooks = {
                            orderLog = emptyOrderLog;
                            getSubscriptions = func(_ : Principal) : async [ShopInterface.EventKind] {
                                events;
                            };
                            subscribe = shops.subscribe;
                            syncProducts = func(_ : Principal) : async Result.Result<(), Text> {
                                syncs += 1;
                                if (syncFails) #err("product_index unavailable") else #ok;
                            };
                        };

                        switch (await OrderAPI.checkShopSubscription(api, shopId, hooks)) {
                            case (#resubscribed({ productSync = #err(msg) })) expect.text(msg).equal("product_index unavailable");
                            case _ Runtime.trap("expected #resubscribed with a failed sync");
                        };
                        expect.array<Principal>(OrderAPI.listUnsubscribedShops(api), Principal.toText, Principal.equal).equal([shopId]);

                        // Subscribed now, but the products are still stale: the next check resyncs.
                        events := OrderAPI.SHOP_EVENTS;
                        expect.bool((await OrderAPI.checkShopSubscription(api, shopId, hooks)) == #resynced({ productSync = #err("product_index unavailable") })).isTrue();
                        expect.array<Principal>(OrderAPI.listUnsubscribedShops(api), Principal.toText, Principal.equal).equal([shopId]);

                        syncFails := false;
                        expect.bool((await OrderAPI.checkShopSubscription(api, shopId, hooks)) == #resynced({ productSync = #ok })).isTrue();
                        expect.array<Principal>(OrderAPI.listUnsubscribedShops(api), Principal.toText, Principal.equal).equal([]);

                        expect.bool((await OrderAPI.checkShopSubscription(api, shopId, hooks)) == #subscribed).isTrue();
                        expect.nat(syncs).equal(3);
                        expect.nat(shops.subscribeCalls()).equal(1);
                    },
                );

                await test(
                    "checkShopSubscription changes nothing when the shop can't say",
                    func() : async () {
                        let api = OrderAPI.API(makeDependencies(Set.fromIter<Principal>([shopId].values(), Set.phash)));
                        let shops = makeShops(api);
                        let hooks : OrderAPI.SubscriptionCheckHooks = {
                            orderLog = emptyOrderLog;
                            getSubscriptions = func(_ : Principal) : async [ShopInterface.EventKind] {
                                throw Error.reject("no method getMyEventSubscriptions");
                            };
                            subscribe = shops.subscribe;
                            syncProducts = func(_ : Principal) : async Result.Result<(), Text> {
                                Runtime.trap("must not sync");
                            };
                        };

                        let results = await OrderAPI.checkShopSubscriptions(api, [shopId, otherShopId], hooks);

                        expect.bool(results[0].check == #unknown("no method getMyEventSubscriptions")).isTrue();
                        expect.bool(results[1].check == #notRegistered).isTrue();
                        expect.bool(results[1].orders == #notRegistered).isTrue();
                        expect.nat(shops.subscribeCalls()).equal(0);
                        expect.array<Principal>(OrderAPI.listUnsubscribedShops(api), Principal.toText, Principal.equal).equal([]);
                    },
                );

                await test(
                    "a background subscription check runs one at a time and tallies each shop",
                    func() : async () {
                        let api = OrderAPI.API(makeDependencies(Set.fromIter<Principal>([shopId].values(), Set.phash)));
                        let shops = makeShops(api);
                        let hooks : OrderAPI.SubscriptionCheckHooks = {
                            orderLog = emptyOrderLog;
                            getSubscriptions = func(_ : Principal) : async [ShopInterface.EventKind] {
                                throw Error.reject("unreachable");
                            };
                            subscribe = shops.subscribe;
                            syncProducts = func(_ : Principal) : async Result.Result<(), Text> {
                                Runtime.trap("must not sync");
                            };
                        };

                        let begun = OrderAPI.beginSubscriptionCheck(api, #requested, 2, 7);
                        expect.bool(Result.isOk(begun)).isTrue();
                        switch (OrderAPI.beginSubscriptionCheck(api, #scheduled, 2, 8)) {
                            case (#err(running)) expect.int(running.startedAt).equal(7);
                            case (#ok(_)) Runtime.trap("a second run began while one was under way");
                        };

                        await OrderAPI.runSubscriptionCheck(api, [shopId, otherShopId], hooks);

                        expect.bool(Option.isNull(api.runningSubscriptionCheck)).isTrue();
                        let ?last = api.lastSubscriptionCheck else Runtime.trap("no finished run");
                        expect.bool(last.trigger == #requested).isTrue();
                        expect.bool(Option.isSome(last.finishedAt)).isTrue();
                        expect.nat(last.shops).equal(2);
                        expect.nat(last.tally.checked).equal(2);
                        expect.nat(last.tally.unknown).equal(1);
                        expect.nat(last.tally.notRegistered).equal(1);
                        expect.bool(Result.isOk(OrderAPI.beginSubscriptionCheck(api, #scheduled, 0, 9))).isTrue();
                    },
                );

                await test(
                    "tallySubscriptionCheck counts a failed product resync apart from a clean one",
                    func() : async () {
                        let tallied = [
                            {
                                shopId;
                                check = #subscribed;
                                orders = #caughtUp({
                                    events = 3;
                                    fetched = 1;
                                    pending = 2;
                                    complete = true;
                                    restarted = false;
                                });
                            },
                            {
                                shopId;
                                check = #resubscribed({
                                    missing = [#OrderUpdated];
                                    productSync = #ok;
                                });
                                orders = #inProgress;
                            },
                            {
                                shopId;
                                check = #resynced({ productSync = #err("down") });
                                orders = #unknown("down");
                            },
                            {
                                shopId;
                                check = #resubscribeFailed({
                                    missing = [#OrderUpdated];
                                    error = "no role";
                                });
                                orders = #skipped("not subscribed");
                            },
                        ].foldLeft(OrderAPI.EMPTY_SUBSCRIPTION_CHECK_TALLY, OrderAPI.tallySubscriptionCheck);

                        expect.nat(tallied.checked).equal(4);
                        expect.nat(tallied.subscribed).equal(1);
                        expect.nat(tallied.resubscribed).equal(1);
                        expect.nat(tallied.resynced).equal(0);
                        expect.nat(tallied.resyncFailed).equal(1);
                        expect.nat(tallied.resubscribeFailed).equal(1);
                        expect.nat(tallied.orderEvents).equal(3);
                        expect.nat(tallied.ordersPending).equal(2);
                        expect.nat(tallied.orderCatchUpsSkipped).equal(2);
                    },
                );

                await test(
                    "orders from a subscribed but unregistered shop are ignored",
                    func() : async () {
                        let api = OrderAPI.API(makeDependencies(Set.new<Principal>()));
                        let shops = makeShops(api);
                        ignore await OrderAPI.subscribeShop(api, otherShopId, shops.subscribe);

                        shops.placeOrder(otherShopId, 3);

                        expect.nat(buyerOrderIds(api).size()).equal(0);
                    },
                );
            },
        );

        await suite(
            "buildOrderKey",
            func() : async () {
                let shopA = Principal.fromText("aaaaa-aa");
                let shopB = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");

                await test(
                    "builds composite key from shop id and order id",
                    func() : async () {
                        expect.text(OrderAPI.buildOrderKey(shopA, 1)).equal("aaaaa-aa:1");
                        expect.text(OrderAPI.buildOrderKey(shopA, 42)).equal("aaaaa-aa:42");
                    },
                );

                await test(
                    "uses shop principal text in key",
                    func() : async () {
                        expect.text(OrderAPI.buildOrderKey(shopB, 7)).equal("uxrrr-q7777-77774-qaaaq-cai:7");
                    },
                );
            },
        );

        await suite(
            "sortUserOrderListingsDesc",
            func() : async () {
                let shopId = Principal.fromText("aaaaa-aa");
                let buyer = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
                let usd = {
                    class_ = #FiatCurrency;
                    symbol = "USD";
                };
                let zeroMoney = {
                    currency = usd;
                    amount = 0 : Nat64;
                    metadata = { decimals = 2 : Nat32 };
                };
                let zeroTotals = {
                    subtotal = zeroMoney;
                    discounts = zeroMoney;
                    tax = zeroMoney;
                    shipping = zeroMoney;
                    total = zeroMoney;
                };

                func makeListing(orderId : Nat32, createdAt : Time.Time) : OrderAPI.UserOrderListing {
                    {
                        shopCanisterId = shopId;
                        shopName = "Test Shop";
                        order = {
                            id = orderId;
                            shopId;
                            buyer;
                            items = [];
                            totals = zeroTotals;
                            status = #created;
                            createdAt;
                        };
                    };
                };

                await test(
                    "returns empty array unchanged",
                    func() : async () {
                        let sorted = OrderAPI.sortUserOrderListingsDesc([]);
                        expect.nat(sorted.size()).equal(0);
                    },
                );

                await test(
                    "sorts by createdAt descending",
                    func() : async () {
                        let oldest = makeListing(1, 100);
                        let middle = makeListing(2, 200);
                        let newest = makeListing(3, 300);

                        let sorted = OrderAPI.sortUserOrderListingsDesc([oldest, newest, middle]);

                        expect.nat32(sorted[0].order.id).equal(3);
                        expect.nat32(sorted[1].order.id).equal(2);
                        expect.nat32(sorted[2].order.id).equal(1);
                    },
                );

                await test(
                    "breaks ties with order id descending when createdAt is equal",
                    func() : async () {
                        let lowerId = makeListing(1, 500);
                        let higherId = makeListing(5, 500);

                        let sorted = OrderAPI.sortUserOrderListingsDesc([lowerId, higherId]);

                        expect.nat32(sorted[0].order.id).equal(5);
                        expect.nat32(sorted[1].order.id).equal(1);
                    },
                );
            },
        );
    },
);
