import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Array "mo:core/Array";
import Error "mo:core/Error";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";

import CoreMap "mo:core/Map";
import CoreSet "mo:core/Set";
import Map "mo:map/Map";
import Set "mo:map/Set";

import MockLogger "../../../../../lib/Logger/mock";
import OrderAPI "../lib";
import ShopInterface "../../../../../interfaces/shop";

let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
let otherShopId = Principal.fromText("aaaaa-aa");
let buyer = Principal.fromText("vg3po-ix777-77774-qaafa-cai");

func usd(amount : Nat64) : ShopInterface.Money {
    {
        currency = { class_ = #FiatCurrency; symbol = "USD" };
        amount;
        metadata = { decimals = 2 };
    };
};

let totals : ShopInterface.Totals = {
    subtotal = usd(2500);
    discounts = usd(0);
    tax = usd(0);
    shipping = usd(0);
    total = usd(2500);
};

/// Stands in for core's shop registry; tests unregister shops from it.
let registeredShops = Set.new<Principal>();

func makeApi(registered : [Principal]) : OrderAPI.API {
    Set.clear(registeredShops);
    for (id in registered.values()) Set.add(registeredShops, Set.phash, id);
    OrderAPI.API({
        orders = Map.new<OrderAPI.OrderKey, OrderAPI.Order>();
        ordersByBuyer = Map.new<Principal, CoreSet.Set<OrderAPI.UserOrderCursor>>();
        unsubscribedShops = Set.new<Principal>();
        catchUp = OrderAPI.emptyCatchUpState();
        shopApi = {
            getShopName = func(_ : Principal) : Text = "Hosted Shop";
            isRegisteredShop = func(id : Principal) : Bool = Set.has(registeredShops, Set.phash, id);
        };
        logger = MockLogger.bind(MockLogger.new(shopId));
    });
};

/// A shop with an order log (`listOrderEvents`) and orders (`getMyOrder`). Placing an order or
/// changing its status appends an event, as the shop's `storeOrder` does; `push` is the
/// `OrderUpdated` notification core gets when nothing is lost.
class MockShop(api : OrderAPI.API) {
    let orders = CoreMap.empty<Nat32, ShopInterface.Order>();
    let log = List.empty<ShopInterface.OrderEvent>();
    var clock : Int = 1_000;

    /// Most events the shop returns per page, whatever the limit asked.
    public var pageSize = 200;
    /// False: a shop version from before BRE-133, with no `listOrderEvents`.
    public var hasLog = true;
    /// False: core may not read the log (a self-managed shop without Marketplace access): empty pages.
    public var logReadable = true;
    /// False: a shop version from before BRE-203, which refuses core `getMyOrder`.
    public var lendsOrders = true;
    public var getOrderCalls = 0;
    /// False: the shop ignores the limit core asks for and returns up to `pageSize` events.
    public var honorsLimit = true;
    /// Orders whose `getMyOrder` call fails.
    public let failingOrders = CoreSet.empty<Nat32>();
    /// Runs inside `getMyOrder` after the shop read the order, to act while a catch-up waits on the
    /// shop: what it changes isn't in the reply.
    public var onGetOrder : ?(() -> async ()) = null;

    /// Appends an event at the shop's current time (the time its order was written, as `storeOrder` does).
    func append(orderId : Nat32, kind : ShopInterface.OrderEventKind) {
        log.add({ seq = log.size(); orderId; at = clock; kind = ?kind });
    };

    /// Sends the order's notification as core's `trackOrder` endpoint takes it, naming the order's
    /// latest log event. Returns whether core would start a catch-up.
    public func push(orderId : Nat32) : Bool {
        let ?order = orders.get(Nat32.compare, orderId) else Runtime.trap("no order");
        var logEvent : ?ShopInterface.OrderLogEvent = null;
        for (e in log.values()) if (e.orderId == orderId) logEvent := ?{
            seq = e.seq;
            at = e.at;
        };
        OrderAPI.trackOrder(api, shopId, { data = { order with orderId; logEvent } });
        OrderAPI.noteNotification(api, shopId, logEvent, clock);
    };

    public func place(orderId : Nat32) = placeFor(orderId, buyer);

    public func placeFor(orderId : Nat32, orderBuyer : Principal) {
        clock += 1;
        orders.add(Nat32.compare, orderId, { id = orderId; buyer = orderBuyer; items = []; totals; status = #created; createdAt = clock });
        append(orderId, #created);
    };

    public func setStatus(orderId : Nat32, status : ShopInterface.OrderStatus, kind : ShopInterface.OrderEventKind) {
        clock += 1;
        let ?order = orders.get(Nat32.compare, orderId) else Runtime.trap("no order");
        orders.add(Nat32.compare, orderId, { order with status });
        append(orderId, kind);
    };

    /// Wipes the shop, as a reinstall does: its log numbers from 0 again.
    public func reinstall() {
        orders.clear();
        log.clear();
    };

    /// Restores the shop from a snapshot taken when its log held `events` events: later events and
    /// the orders they created are gone, so their IDs are given out again.
    public func restoreTo(events : Nat) {
        log.truncate(events);
        let kept = CoreSet.empty<Nat32>();
        for (e in log.values()) kept.add(Nat32.compare, e.orderId);
        for (id in Iter.toArray(orders.keys()).values()) if (not kept.contains(Nat32.compare, id)) orders.remove(Nat32.compare, id);
    };

    public let hooks : OrderAPI.OrderLogHooks = {
        listOrderEvents = func(_ : Principal, after : ?Nat, limit : ?Nat) : async {
            items : [ShopInterface.OrderEvent];
            next : ?Nat;
        } {
            if (not hasLog) throw Error.reject("Canister has no query method 'listOrderEvents'");
            if (not logReadable) return { items = []; next = null };
            let from = switch (after) { case (?seq) seq + 1; case null 0 };
            let n = switch (limit) {
                case (?l) if (l < pageSize and honorsLimit) l else pageSize;
                case null pageSize;
            };
            let items = List.empty<ShopInterface.OrderEvent>();
            var seq = from;
            while (seq < log.size() and items.size() < n) {
                items.add(log.at(seq));
                seq += 1;
            };
            let next = if (seq < log.size() and items.size() > 0) ?(seq - 1 : Nat) else null;
            { items = items.toArray(); next };
        };
        getOrder = func(_ : Principal, orderId : Nat32) : async ShopInterface.GetOrderResponse {
            getOrderCalls += 1;
            let order = orders.get(Nat32.compare, orderId);
            switch (onGetOrder) { case (?f) await f(); case null {} };
            if (failingOrders.contains(Nat32.compare, orderId)) throw Error.reject("timed out");
            if (not lendsOrders) return #err(#Unauthorized("Only the order buyer, Owner or Admin can view this order"));
            switch (order) {
                case (?order) #ok(order);
                case null #err(#NotFoundError("not found"));
            };
        };
    };
};

/// The buyer's orders in core's index, newest first, as (order ID, status).
func buyerOrders(api : OrderAPI.API) : [(Nat32, ShopInterface.OrderStatus)] {
    switch (OrderAPI.getUserOrders(api, buyer, null, ?200)) {
        case (#ok(page)) page.items.map<OrderAPI.UserOrderListing, (Nat32, ShopInterface.OrderStatus)>(func(l : OrderAPI.UserOrderListing) : (Nat32, ShopInterface.OrderStatus) = (l.order.id, l.order.status));
        case (#err(_)) Runtime.trap("expected #ok");
    };
};

func buyerCreatedAt(api : OrderAPI.API, orderId : Nat32) : Int {
    switch (OrderAPI.getUserOrders(api, buyer, null, ?200)) {
        case (#ok(page)) {
            for (l in page.items.values()) if (l.order.id == orderId) return l.order.createdAt;
            Runtime.trap("no such order");
        };
        case (#err(_)) Runtime.trap("expected #ok");
    };
};

func showOrders(orders : [(Nat32, ShopInterface.OrderStatus)]) : Text = debug_show orders;

func caughtUp(result : OrderAPI.OrderCatchUp) : {
    events : Nat;
    fetched : Nat;
    pending : Nat;
    complete : Bool;
    restarted : Bool;
} {
    switch (result) {
        case (#caughtUp(r)) r;
        case other Runtime.trap("expected #caughtUp, got " # debug_show other);
    };
};

suite(
    "OrderAPI.catchUpOrders",
    func() : async () {
        await test(
            "indexes orders and status changes whose notifications core missed",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                ignore shop.push(1);
                // Core was upgrading: none of these reached it.
                shop.place(2);
                shop.setStatus(1, #paid, #paid({}));
                shop.place(3);
                shop.setStatus(3, #awaitingPayment, #awaitingPayment({}));

                let r = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));

                expect.nat(r.events).equal(5);
                // Order 1's status came from its event; orders 2 and 3 were read from the shop.
                expect.nat(r.fetched).equal(2);
                expect.bool(r.complete).isTrue();
                expect.bool(r.restarted).isFalse();
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(3, #awaitingPayment), (2, #created), (1, #paid)]));

                // Only new events are read next time.
                shop.setStatus(2, #canceled, #canceled({}));
                let next = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(next.events).equal(1);
                expect.nat(next.fetched).equal(0);
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(3, #awaitingPayment), (2, #canceled), (1, #paid)]));
            },
        );

        await test(
            "reads the order when an event doesn't say its status",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                ignore shop.push(1);
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);
                shop.setStatus(1, #fulfilled, #lineDelivered({}));

                let r = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));

                expect.nat(r.fetched).equal(1);
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(1, #fulfilled)]));
            },
        );

        await test(
            "applying events again, or after their notifications, changes nothing",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                shop.setStatus(1, #paid, #paid({}));
                shop.place(2);
                // A late notification of order 1's newest state arrives before the catch-up.
                ignore shop.push(1);
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);
                let once = showOrders(buyerOrders(api));
                expect.text(once).equal(showOrders([(2, #created), (1, #paid)]));

                // As if the cursor was lost: every event is applied a second time.
                api.catchUp.cursors.clear();
                let again = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(again.events).equal(3);
                expect.text(showOrders(buyerOrders(api))).equal(once);

                // Notifications of events the catch-up already applied.
                ignore shop.push(2);
                ignore shop.push(1);
                expect.text(showOrders(buyerOrders(api))).equal(once);
            },
        );

        await test(
            "events of one order apply in log order, so the last one wins",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                ignore shop.push(1);
                shop.setStatus(1, #paid, #paid({}));
                shop.place(2);
                shop.setStatus(1, #fulfilled, #fulfilled({}));
                shop.setStatus(1, #refunded, #refunded);

                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);

                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(2, #created), (1, #refunded)]));
            },
        );

        await test(
            "starts over from the first event when the shop's log was reset by a reinstall",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                shop.place(2);
                shop.place(3);
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);
                expect.bool(api.catchUp.cursors.get(Principal.compare, shopId) != null).isTrue();

                // Shorter than core's cursor: the event core last read isn't there.
                shop.reinstall();
                shop.place(10);
                let shorter = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.bool(shorter.restarted).isTrue();
                expect.nat(shorter.events).equal(1);
                expect.bool(buyerOrders(api)[0].0 == 10).isTrue();

                // Longer than core's cursor, but a different event at its position.
                shop.reinstall();
                shop.place(20);
                shop.place(21);
                shop.place(22);
                let longer = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.bool(longer.restarted).isTrue();
                expect.nat(longer.events).equal(3);
                expect.nat(longer.fetched).equal(3);
                expect.bool(buyerOrders(api)[0].0 == 22).isTrue();

                // The same log as last time: no restart.
                shop.place(23);
                let same = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.bool(same.restarted).isFalse();
                expect.nat(same.events).equal(1);
            },
        );

        await test(
            "stops at the page cap and carries on at the next run",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.pageSize := 2;
                let total = 2 * OrderAPI.MAX_CATCH_UP_PAGES + 5;
                var id : Nat32 = 0;
                while (Nat32.toNat(id) < total) {
                    shop.place(id);
                    id += 1;
                };

                let first = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(first.events).equal(2 * OrderAPI.MAX_CATCH_UP_PAGES);
                expect.bool(first.complete).isFalse();
                expect.nat(buyerOrders(api).size()).equal(2 * OrderAPI.MAX_CATCH_UP_PAGES);

                let second = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(second.events).equal(5);
                expect.bool(second.complete).isTrue();
                expect.nat(buyerOrders(api).size()).equal(total);
            },
        );

        await test(
            "keeps orders a shop won't lend core pending, and reads them once it does",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.lendsOrders := false;
                shop.place(1);
                ignore shop.push(1);
                shop.place(2);
                shop.place(3);
                shop.setStatus(1, #paid, #paid({}));

                let refused = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(refused.events).equal(4);
                expect.nat(refused.pending).equal(2);
                // Asked once; the shop's refusal holds for the rest of the run.
                expect.nat(shop.getOrderCalls).equal(1);
                // An order core knew still got its new status from the event.
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(1, #paid)]));

                // The shop upgraded to a version that lends core its orders.
                shop.lendsOrders := true;
                let lent = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(lent.events).equal(0);
                expect.nat(lent.fetched).equal(2);
                expect.nat(lent.pending).equal(0);
                expect.bool(not api.catchUp.pending.containsKey(Principal.compare, shopId)).isTrue();
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(3, #created), (2, #created), (1, #paid)]));
            },
        );

        await test(
            "a failed order read stays pending and is retried",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                var fail = true;
                shop.onGetOrder := ?(func() : async () { if (fail) throw Error.reject("timed out") });

                let failed = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(failed.pending).equal(1);
                expect.nat(buyerOrders(api).size()).equal(0);

                fail := false;
                let retried = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(retried.pending).equal(0);
                expect.nat(buyerOrders(api).size()).equal(1);
            },
        );

        await test(
            "skips shops without the log, or whose log core can't read, and keeps the cursor",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                shop.hasLog := false;
                switch (await OrderAPI.catchUpOrders(api, shopId, shop.hooks)) {
                    case (#unknown(msg)) expect.text(msg).equal("Canister has no query method 'listOrderEvents'");
                    case other Runtime.trap("expected #unknown, got " # debug_show other);
                };
                expect.nat(buyerOrders(api).size()).equal(0);

                shop.hasLog := true;
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);
                let cursor = api.catchUp.cursors.get(Principal.compare, shopId);

                // Its Owner revoked core's Marketplace access: the log reads as empty.
                shop.logReadable := false;
                switch (await OrderAPI.catchUpOrders(api, shopId, shop.hooks)) {
                    case (#skipped(_)) {};
                    case other Runtime.trap("expected #skipped, got " # debug_show other);
                };
                expect.bool(api.catchUp.cursors.get(Principal.compare, shopId) == cursor).isTrue();

                expect.bool((await OrderAPI.catchUpOrders(api, otherShopId, shop.hooks)) == #notRegistered).isTrue();
            },
        );

        await test(
            "a late snapshot or an old event never moves an order's status back",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                shop.setStatus(1, #paid, #paid({}));
                // The order is fulfilled, and its notification arrives, while core waits on the
                // snapshot it asked for, which still says paid.
                shop.onGetOrder := ?(
                    func() : async () {
                        shop.onGetOrder := null;
                        shop.setStatus(1, #fulfilled, #fulfilled({}));
                        ignore shop.push(1);
                    }
                );
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(1, #fulfilled)]));

                // Replaying the whole log again: its created and paid events don't undo fulfilled.
                api.catchUp.cursors.clear();
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(1, #fulfilled)]));

                // Nor does a late notification of an older state.
                OrderAPI.trackOrder(api, shopId, { data = { orderId = 1 : Nat32; buyer; items = []; totals; status = #paid; createdAt = buyerCreatedAt(api, 1); logEvent = null } });
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(1, #fulfilled)]));
            },
        );

        await test(
            "after a reinstall, an order ID the new log reuses is read again, not taken for the old order",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                let newBuyer = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
                shop.place(1);
                shop.setStatus(1, #fulfilled, #fulfilled({}));
                shop.place(2);
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);

                // Reinstalled: order IDs start over, and the new order 1's notification is lost.
                shop.reinstall();
                shop.placeFor(1, newBuyer);
                shop.place(3);
                shop.place(4);
                shop.place(5);
                shop.setStatus(1, #paid, #paid({}));
                shop.pageSize := 2;
                let first = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.bool(first.restarted).isTrue();

                // Later runs of the same new log still know order 1's old entry isn't its order.
                shop.pageSize := 200;
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);
                let listings = switch (OrderAPI.getUserOrders(api, newBuyer, null, null)) {
                    case (#ok(page)) page.items;
                    case (#err(_)) Runtime.trap("expected #ok");
                };
                expect.nat(listings.size()).equal(1);
                expect.bool(listings[0].order.status == #paid).isTrue();
                // The old buyer keeps the old install's order 2, but no longer has an order 1.
                expect.bool(buyerOrders(api).filter(func((id, _) : (Nat32, ShopInterface.OrderStatus)) : Bool = id == 1).size() == 0).isTrue();
            },
        );

        await test(
            "after a snapshot restore, an order ID given out again is read, not taken for the lost order",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                let newBuyer = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
                shop.place(1);
                shop.place(2);
                // Core indexes order 3, then the shop is restored from before it.
                shop.place(3);
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);
                shop.restoreTo(2);
                // Order 3 again, another buyer's; its notification is lost.
                shop.placeFor(3, newBuyer);
                shop.setStatus(3, #paid, #paid({}));

                let r = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.bool(r.restarted).isTrue();
                let listings = switch (OrderAPI.getUserOrders(api, newBuyer, null, null)) {
                    case (#ok(page)) page.items;
                    case (#err(_)) Runtime.trap("expected #ok");
                };
                expect.nat(listings.size()).equal(1);
                expect.bool(listings[0].order.status == #paid).isTrue();
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(2, #created), (1, #created)]));
            },
        );

        await test(
            "a reinstalled shop's notifications that look in step don't hide its lost first events",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);

                // Reinstalled: order 5's notification (seq 0) is lost; order 6's (seq 1) follows
                // core's cursor (seq 0) by number.
                shop.reinstall();
                shop.place(5);
                shop.place(6);
                expect.bool(shop.push(6)).isFalse();

                let r = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.bool(r.restarted).isTrue();
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(6, #created), (5, #created), (1, #created)]));
            },
        );

        await test(
            "a late read of a replaced order doesn't overwrite the order now under its ID",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                let newBuyer = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
                shop.place(1);
                // While core waits on its read of order 1, the shop is reinstalled and the new
                // order 1's notification arrives first.
                shop.onGetOrder := ?(
                    func() : async () {
                        shop.onGetOrder := null;
                        shop.reinstall();
                        shop.placeFor(1, newBuyer);
                        ignore shop.push(1);
                    }
                );
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);

                let listings = switch (OrderAPI.getUserOrders(api, newBuyer, null, null)) {
                    case (#ok(page)) page.items;
                    case (#err(_)) Runtime.trap("expected #ok");
                };
                expect.nat(listings.size()).equal(1);
                expect.nat(buyerOrders(api).size()).equal(0);
            },
        );

        await test(
            "events for orders already pending need no more room, so a full pending set doesn't stop them",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.lendsOrders := false;
                let full = CoreSet.empty<Nat32>();
                var id : Nat32 = 0;
                while (Nat32.toNat(id) < OrderAPI.MAX_PENDING_PER_SHOP) {
                    full.add(Nat32.compare, id);
                    id += 1;
                };
                api.catchUp.pending.add(Principal.compare, shopId, full);
                shop.place(1);
                shop.setStatus(1, #paid, #paid({}));

                let r = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(r.events).equal(2);
                expect.bool(r.complete).isTrue();
                expect.nat(r.pending).equal(OrderAPI.MAX_PENDING_PER_SHOP);

                // An order not yet pending doesn't fit: the page waits, cursor unmoved.
                shop.place(Nat32.fromNat(OrderAPI.MAX_PENDING_PER_SHOP));
                let waiting = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(waiting.events).equal(0);
                expect.bool(waiting.complete).isFalse();
            },
        );

        await test(
            "stops reading orders after a few failed reads, leaving the rest pending",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                var id : Nat32 = 0;
                while (id < 10) {
                    shop.place(id);
                    shop.failingOrders.add(Nat32.compare, id);
                    id += 1;
                };

                let r = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(shop.getOrderCalls).equal(OrderAPI.MAX_FAILED_READS);
                expect.nat(r.events).equal(10);
                expect.nat(r.pending).equal(10);
            },
        );

        await test(
            "orders that keep failing don't stop the run from reading the log",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                var id : Nat32 = 0;
                while (Nat32.toNat(id) < OrderAPI.MAX_FAILED_READS) {
                    shop.place(id);
                    shop.failingOrders.add(Nat32.compare, id);
                    id += 1;
                };
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);

                // The retries spend the run's failed reads; the new order's event is still read.
                shop.place(id);
                let blocked = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(blocked.events).equal(1);
                expect.nat(blocked.pending).equal(OrderAPI.MAX_FAILED_READS + 1);

                // The next run's retries start with it.
                let next = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(next.fetched).equal(1);
                expect.nat(buyerOrders(api).size()).equal(1);
            },
        );

        await test(
            "refuses a page whose next isn't its last event, before reading any order",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(0);
                shop.place(1);
                let hooks = {
                    shop.hooks with listOrderEvents = func(_ : Principal, _ : ?Nat, _ : ?Nat) : async {
                        items : [ShopInterface.OrderEvent];
                        next : ?Nat;
                    } {
                        {
                            items = [{
                                seq = 0;
                                orderId = 0;
                                at = 1;
                                kind = ?#created;
                            }];
                            next = ?1;
                        };
                    };
                };
                switch (await OrderAPI.catchUpOrders(api, shopId, hooks)) {
                    case (#unknown(_)) {};
                    case other Runtime.trap("expected #unknown, got " # debug_show other);
                };
                expect.nat(shop.getOrderCalls).equal(0);
            },
        );

        await test(
            "an event from before core's order was created is read again, not applied to it",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                ignore shop.push(1);
                // A page read before a reinstall: its event is about the order the ID had then.
                let hooks = {
                    shop.hooks with listOrderEvents = func(_ : Principal, _ : ?Nat, _ : ?Nat) : async {
                        items : [ShopInterface.OrderEvent];
                        next : ?Nat;
                    } {
                        {
                            items = [{
                                seq = 0;
                                orderId = 1;
                                at = 0;
                                kind = ?#fulfilled({});
                            }];
                            next = null;
                        };
                    };
                };
                ignore caughtUp(await OrderAPI.catchUpOrders(api, shopId, hooks));
                expect.nat(shop.getOrderCalls).equal(1);
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(1, #created)]));
            },
        );

        await test(
            "refuses a page with more events than asked for, before reading any order",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                var id : Nat32 = 0;
                while (id < 250) {
                    shop.place(id);
                    id += 1;
                };
                shop.pageSize := 500;
                shop.honorsLimit := false;

                switch (await OrderAPI.catchUpOrders(api, shopId, shop.hooks)) {
                    case (#unknown(_)) {};
                    case other Runtime.trap("expected #unknown, got " # debug_show other);
                };
                expect.nat(shop.getOrderCalls).equal(0);
                expect.bool(api.catchUp.cursors.get(Principal.compare, shopId) == null).isTrue();
            },
        );

        await test(
            "retries take turns through the pending orders",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.lendsOrders := false;
                let count = OrderAPI.MAX_PENDING_RETRIES + 1;
                var id : Nat32 = 0;
                while (Nat32.toNat(id) < count) {
                    shop.place(id);
                    id += 1;
                };
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);

                // The shop lends orders now, but the lowest IDs keep failing, so the run stops
                // reading after them.
                shop.lendsOrders := true;
                id := 0;
                while (Nat32.toNat(id) < OrderAPI.MAX_FAILED_READS) {
                    shop.failingOrders.add(Nat32.compare, id);
                    id += 1;
                };
                let blocked = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(blocked.fetched).equal(0);
                expect.nat(blocked.pending).equal(count);

                // The next run starts at the first order the last one didn't try, so every other
                // pending order is read, the last one included.
                let turned = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(turned.fetched).equal(count - OrderAPI.MAX_FAILED_READS);
                expect.nat(turned.pending).equal(OrderAPI.MAX_FAILED_READS);
                expect.bool(buyerOrders(api)[0].0 == Nat32.fromNat(count - 1)).isTrue();
            },
        );

        await test(
            "a shop unregistered during a catch-up keeps no cursor, order or pending state from it",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                shop.place(2);
                shop.onGetOrder := ?(
                    func() : async () {
                        Set.delete(registeredShops, Set.phash, shopId);
                        OrderAPI.forgetShop(api, shopId);
                    }
                );

                expect.bool((await OrderAPI.catchUpOrders(api, shopId, shop.hooks)) == #notRegistered).isTrue();

                expect.nat(shop.getOrderCalls).equal(1);
                expect.nat(buyerOrders(api).size()).equal(0);
                expect.bool(api.catchUp.cursors.get(Principal.compare, shopId) == null).isTrue();
                expect.bool(not api.catchUp.pending.containsKey(Principal.compare, shopId)).isTrue();
                expect.bool(api.catchUpsCancelled.size() == 0).isTrue();
            },
        );

        await test(
            "notifications in step aren't gaps, and the next catch-up reads their events without reading orders",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                expect.bool(shop.push(1)).isFalse();
                shop.place(2);
                expect.bool(shop.push(2)).isFalse();
                shop.setStatus(1, #paid, #paid({}));
                expect.bool(shop.push(1)).isFalse();

                let r = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(r.events).equal(3);
                expect.nat(shop.getOrderCalls).equal(0);
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(2, #created), (1, #paid)]));
            },
        );

        await test(
            "a skipped sequence number starts a catch-up, at most once per interval",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                ignore shop.push(1);
                // Order 2's notification is lost.
                shop.place(2);
                shop.place(3);
                expect.bool(shop.push(3)).isTrue();

                // Another gap right after doesn't start a second one.
                shop.place(4);
                shop.place(5);
                expect.bool(shop.push(5)).isFalse();
                expect.bool(OrderAPI.noteNotification(api, shopId, ?{ seq = 9; at = 1 }, OrderAPI.GAP_CATCH_UP_INTERVAL * 100)).isTrue();

                // The catch-up reads what was missed.
                ignore await OrderAPI.catchUpOrdersFor(api, shopId, shop.hooks, OrderAPI.GAP_CATCH_UP_PAGES);
                expect.nat(buyerOrders(api).size()).equal(5);
            },
        );

        await test(
            "a late earlier notification, or one from an older shop, starts nothing",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                shop.place(2);
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);
                let cursor = api.catchUp.cursors.get(Principal.compare, shopId);

                // Order 1's notification arrives after the catch-up read past it.
                expect.bool(shop.push(1)).isFalse();
                expect.bool(OrderAPI.noteNotification(api, shopId, null, 0)).isFalse();
                expect.bool(api.catchUp.cursors.get(Principal.compare, shopId) == cursor).isTrue();
            },
        );

        await test(
            "a notification numbered from 0 again, later in time, starts a catch-up (reinstall)",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                shop.place(2);
                shop.place(3);
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);

                shop.reinstall();
                shop.place(1);
                expect.bool(shop.push(1)).isTrue();
            },
        );

        await test(
            "notifications leave the cursor to a running catch-up",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                shop.place(2);
                var during : ?Bool = null;
                shop.onGetOrder := ?(
                    func() : async () {
                        if (during == null) during := ?shop.push(2);
                    }
                );
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);
                expect.bool(during == ?false).isTrue();
                switch (api.catchUp.cursors.get(Principal.compare, shopId)) {
                    case (?{ last = ?{ seq } }) expect.nat(seq).equal(1);
                    case _ Runtime.trap("expected a cursor");
                };
            },
        );

        await test(
            "a notification during a run has it read on to the end of the log",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                shop.onGetOrder := ?(
                    func() : async () {
                        shop.onGetOrder := null;
                        shop.place(2);
                        shop.setStatus(2, #awaitingPayment, #awaitingPayment({}));
                        ignore shop.push(2);
                        shop.setStatus(2, #paid, #paid({}));
                    }
                );
                let r = caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                expect.nat(r.events).equal(4);
                expect.bool(r.complete).isTrue();
                expect.text(showOrders(buyerOrders(api))).equal(showOrders([(2, #paid), (1, #created)]));
            },
        );

        await test(
            "runs one catch-up per shop at a time",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                var nested : ?OrderAPI.OrderCatchUp = null;
                shop.onGetOrder := ?(
                    func() : async () {
                        if (nested == null) nested := ?(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));
                    }
                );

                ignore caughtUp(await OrderAPI.catchUpOrders(api, shopId, shop.hooks));

                expect.bool(nested == ?#inProgress).isTrue();
                expect.bool(api.catchUpsRunning.size() == 0).isTrue();
            },
        );

        await test(
            "forgetShop drops the shop's cursor and pending orders",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.lendsOrders := false;
                shop.place(1);
                ignore await OrderAPI.catchUpOrders(api, shopId, shop.hooks);
                expect.bool(api.catchUp.cursors.get(Principal.compare, shopId) != null).isTrue();
                expect.bool(api.catchUp.pending.containsKey(Principal.compare, shopId)).isTrue();

                OrderAPI.forgetShop(api, shopId);

                expect.bool(api.catchUp.cursors.get(Principal.compare, shopId) == null).isTrue();
                expect.bool(not api.catchUp.pending.containsKey(Principal.compare, shopId)).isTrue();
            },
        );

        await test(
            "the subscription check catches up, and skips shops it couldn't subscribe to again",
            func() : async () {
                let api = makeApi([shopId]);
                let shop = MockShop(api);
                shop.place(1);
                var subscribeFails = false;
                let hooks : OrderAPI.SubscriptionCheckHooks = {
                    orderLog = shop.hooks;
                    getSubscriptions = func(_ : Principal) : async [ShopInterface.EventKind] {
                        if (subscribeFails) { [] } else { OrderAPI.SHOP_EVENTS };
                    };
                    subscribe = func(_ : Principal) : async () {
                        if (subscribeFails) throw Error.reject("no access");
                    };
                    syncProducts = func(_ : Principal) : async Result.Result<(), Text> {
                        #ok;
                    };
                };

                let checked = await OrderAPI.checkShopSubscriptions(api, [shopId], hooks);
                expect.nat(caughtUp(checked[0].orders).events).equal(1);
                expect.nat(buyerOrders(api).size()).equal(1);

                subscribeFails := true;
                shop.place(2);
                let skipped = await OrderAPI.checkShopSubscriptions(api, [shopId], hooks);
                switch (skipped[0].orders) {
                    case (#skipped(_)) {};
                    case other Runtime.trap("expected #skipped, got " # debug_show other);
                };
                expect.nat(buyerOrders(api).size()).equal(1);

                let resubscribed = await OrderAPI.resubscribeShops(api, [shopId], func(_ : Principal) : async () {}, shop.hooks);
                expect.nat(caughtUp(resubscribed[0].orders).events).equal(1);
                expect.nat(buyerOrders(api).size()).equal(2);
            },
        );
    },
);
