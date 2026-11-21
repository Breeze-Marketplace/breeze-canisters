import Array "mo:core/Array";
import Error "mo:core/Error";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Time "mo:core/Time";

import CoreMap "mo:core/Map";
import CoreSet "mo:core/Set";
import Map "mo:map/Map";
import Set "mo:map/Set";

import Logger "../../../../lib/Logger";
import Pagination "../../../../lib/Pagination";
import ShopAPI "../shop";
import ShopInterface "../../../../interfaces/shop";

module {
    public type OrderId = ShopInterface.OrderId;

    public type OrderKey = Text; // `shopId:orderId`, from `buildOrderKey`

    public type Order = {
        id : OrderId; // the shop canister's own order ID
        shopId : ShopAPI.ShopId;
        buyer : Principal;
        items : [ShopInterface.LineItemSnapshot];
        totals : ShopInterface.Totals;
        status : ShopInterface.OrderStatus;
        createdAt : Time.Time;
    };

    public type UserOrderListing = {
        shopCanisterId : Principal;
        shopName : Text;
        order : Order;
    };

    public type OrderData = {
        orderId : OrderId;
        buyer : Principal;
        items : [ShopInterface.LineItemSnapshot];
        totals : ShopInterface.Totals;
        status : ShopInterface.OrderStatus;
        createdAt : Time.Time;
    };

    public type TrackOrderRequest = ShopInterface.OrderUpdatedEvent;

    /// Where a `getUserOrders` page ends: orders are newest first, ties broken by order ID, then shop.
    public type UserOrderCursor = {
        createdAt : Time.Time;
        orderId : OrderId;
        shopCanisterId : Principal;
    };

    public type GetUserOrdersResponse = Result<Pagination.Page<UserOrderListing, UserOrderCursor>, { #Unauthenticated }>;

    public func userOrderCursor(l : UserOrderListing) : UserOrderCursor {
        {
            createdAt = l.order.createdAt;
            orderId = l.order.id;
            shopCanisterId = l.shopCanisterId;
        };
    };

    /// Newest first: the order `getUserOrders` pages in.
    public func compareUserOrderCursor(a : UserOrderCursor, b : UserOrderCursor) : {
        #less;
        #equal;
        #greater;
    } {
        switch (Int.compare(b.createdAt, a.createdAt)) {
            case (#equal) {};
            case (order) { return order };
        };
        switch (Nat32.compare(b.orderId, a.orderId)) {
            case (#equal) {
                Principal.compare(a.shopCanisterId, b.shopCanisterId);
            };
            case (order) { order };
        };
    };

    /// Subscribes core to a shop's events, `trackOrder` included. Throws if a subscribe call fails.
    public type SubscribeToShopEvents = (shopId : Principal) -> async ();

    public type ShopSubscriptionResult = {
        shopId : Principal;
        result : Result<(), Text>;
        /// The order catch-up run once subscribed (`#skipped` when the subscribe failed).
        orders : OrderCatchUp;
    };

    public type Dependencies = {
        orders : Map.Map<OrderKey, Order>;
        /// Each buyer's orders by cursor, newest first, so `getUserOrders` reads a page from its cursor
        /// (BRE-96).
        ordersByBuyer : Map.Map<Principal, CoreSet.Set<UserOrderCursor>>;
        // Shops whose last event subscription failed, so their orders aren't reaching the index
        unsubscribedShops : Set.Set<Principal>;
        /// How far core has read each shop's order log, and the orders it couldn't fetch (BRE-203).
        catchUp : CatchUpState;
        shopApi : {
            getShopName : (Principal) -> Text;
            isRegisteredShop : (Principal) -> Bool;
        };
        logger : Logger.BoundLogger;
    };

    public class API(dependencies : Dependencies) {
        public let {
            orders;
            ordersByBuyer;
            unsubscribedShops;
            catchUp;
            shopApi;
            logger;
        } = dependencies;
        /// Shops with a catch-up running, so two never read the same log at once.
        public let catchUpsRunning = CoreSet.empty<Principal>();
        /// Running catch-ups `forgetShop` stopped: they keep nothing more.
        public let catchUpsCancelled = CoreSet.empty<Principal>();
        /// Each shop's first pending order the next run retries (`nextRetries`). Losing it on upgrade
        /// only starts the turns over.
        public let retryFrom = CoreMap.empty<Principal, OrderId>();
        /// When a skipped notification last started a catch-up for each shop (`noteNotification`).
        public let lastGapCatchUp = CoreMap.empty<Principal, Int>();
        /// Shops whose notifications named a log event while their catch-up ran: the run reads the
        /// log once more before it ends, so events after its last page aren't left for the next run.
        public let notifiedDuringCatchUp = CoreSet.empty<Principal>();
    };

    /// How far core has followed a shop's order log. `last` is the last event a catch-up read from
    /// the log; its `at` tells a reinstalled or restored shop's log, which numbers events again,
    /// from the one core read. `notified` is the last event notifications showed in step
    /// (`noteNotification`): it only tells gaps apart, since a notification can't show that the
    /// events before it are the ones core read, so catch-ups read on from `last`.
    public type CatchUpCursor = {
        last : ?{ seq : Nat; at : Int };
        notified : ?{ seq : Nat; at : Int };
    };

    /// Stable state for catching up from shops' order logs (BRE-203).
    public type CatchUpState = {
        cursors : CoreMap.Map<Principal, CatchUpCursor>;
        /// Orders core found in a shop's log but couldn't read (a shop version that refuses core
        /// `getMyOrder`, or a failed call). Each catch-up tries them again.
        pending : CoreMap.Map<Principal, CoreSet.Set<OrderId>>;
    };

    public func emptyCatchUpState() : CatchUpState {
        { cursors = CoreMap.empty(); pending = CoreMap.empty() };
    };

    /// Pages one catch-up reads per shop, like `ShopAPI.MAX_SYNC_PAGES`; the next run carries on.
    public let MAX_CATCH_UP_PAGES = 10;

    /// Events core asks for per page. A page with more is refused: each event can cost an order read.
    public let CATCH_UP_PAGE_SIZE = Pagination.MAX_LIMIT;

    /// Pending orders one catch-up tries again. Runs take turns through the set (`retryFrom`).
    public let MAX_PENDING_RETRIES = 200;

    /// Pending orders kept per shop. A page whose orders might not fit is left for a later run, with
    /// the cursor before it, so no order is dropped.
    public let MAX_PENDING_PER_SHOP = 10_000;

    /// Failed order reads after which a run stops reading orders, leaving the rest pending: a shop
    /// that times out can't hold the subscription check of every other shop for hours.
    public let MAX_FAILED_READS = 3;

    /// How long one run keeps calling the shop (5 minutes). Orders it hasn't read by then stay
    /// pending, and the log is read on at the next run.
    public let CATCH_UP_TIME_BUDGET : Int = 300_000_000_000;

    /// Reads a shop's order log and orders. Both throw when the call fails.
    public type OrderLogHooks = {
        listOrderEvents : (shopId : Principal, after : ?Nat, limit : ?Nat) -> async {
            items : [ShopInterface.OrderEvent];
            next : ?Nat;
        };
        getOrder : (shopId : Principal, orderId : OrderId) -> async ShopInterface.GetOrderResponse;
    };

    public type OrderCatchUp = {
        /// Core read `events` new events and is up to date with the shop's log, or stopped at
        /// `MAX_CATCH_UP_PAGES` or a full pending set (`complete = false`; the next run carries on).
        /// `fetched` orders were read from the shop; `pending` are still waiting to be. `restarted`:
        /// the shop's log no longer held the event core last read (the shop was reinstalled), so
        /// core read it from the start.
        #caughtUp : {
            events : Nat;
            fetched : Nat;
            pending : Nat;
            complete : Bool;
            restarted : Bool;
        };
        /// Core didn't read the log: it isn't subscribed to the shop, or the shop's log came back
        /// empty where core had read events before (core can't read it, e.g. a self-managed shop that
        /// revoked core's Marketplace access). Nothing changed.
        #skipped : Text;
        /// The shop couldn't serve its log (unreachable, a version without `listOrderEvents`, or a
        /// page core refused). Events read before the failure stay applied.
        #unknown : Text;
        #inProgress;
        /// Also when the shop was unregistered during the run: the run stopped and kept nothing more.
        #notRegistered;
    };

    /// How far along an order is. The shop only moves an order forward (created, awaiting payment,
    /// paid, fulfilled; cancelled only while unpaid), so core never moves one back: a late snapshot
    /// or an old event must not undo a newer state core already has.
    func statusRank(status : ShopInterface.OrderStatus) : Nat {
        switch (status) {
            case (#created) 0;
            case (#awaitingPayment) 1;
            case (#paid) 2;
            case (#processing) 3;
            case (#partiallyFulfilled) 4;
            case (#fulfilled) 5;
            case (#canceled or #refunded) 6;
        };
    };

    /// `next` unless it would move `current` back.
    func laterStatus(current : ShopInterface.OrderStatus, next : ShopInterface.OrderStatus) : ShopInterface.OrderStatus {
        if (statusRank(next) >= statusRank(current)) next else current;
    };

    /// The order status an event leaves its order in, when the event says.
    func statusAfter(kind : ShopInterface.OrderEventKind) : ?ShopInterface.OrderStatus {
        switch (kind) {
            case (#created) ?#created;
            case (#awaitingPayment(_)) ?#awaitingPayment;
            case (#paid(_)) ?#paid;
            case (#fulfilled(_)) ?#fulfilled;
            case (#partiallyFulfilled) ?#partiallyFulfilled;
            case (#canceled(_)) ?#canceled;
            case (#refunded) ?#refunded;
            // May or may not have changed the status: read the order.
            case (#lineDelivered(_)) null;
        };
    };

    /// Why core refuses a page of events read after `after`, if it does: more events than asked,
    /// events out of order or at or before `after`, or a `next` other than the page's last event
    /// (the shop's log pages skip nothing, so any other `next` would skip events).
    func pageProblem(page : { items : [ShopInterface.OrderEvent]; next : ?Nat }, after : ?Nat) : ?Text {
        if (page.items.size() > CATCH_UP_PAGE_SIZE) return ?("The shop returned " # Nat.toText(page.items.size()) # " events; core asked for " # Nat.toText(CATCH_UP_PAGE_SIZE));
        var previous = after;
        for (event in page.items.values()) {
            switch (previous) {
                case (?p) if (event.seq <= p) return ?"The shop returned events out of order";
                case null {};
            };
            previous := ?event.seq;
        };
        switch (page.next, previous) {
            case (?next, ?last) if (next != last) return ?"The shop's next page doesn't start after its last event";
            case (?_, null) return ?"The shop's next page doesn't move on";
            case _ {};
        };
        null;
    };

    /// Brings core's order index up to date with `shopId`'s order log (BRE-203). Pushes
    /// (`trackOrder`) are the fast path, but core misses them while it is stopped or upgrading, when
    /// a call times out, or while the shop has dropped core's subscription. This reads the log from
    /// the last event core applied: an event for an order core knows sets its status; an order core
    /// doesn't know (or whose status the event doesn't give) is read from the shop with `getMyOrder`.
    /// Orders the shop won't give core wait in `pending` for the next run. Applying an event again
    /// is harmless, and neither an old event nor a late snapshot moves an order's status back.
    ///
    /// One catch-up per shop at a time; `forgetShop` stops a running one. Check the caller before
    /// calling this.
    public func catchUpOrders(api : API, shopId : Principal, hooks : OrderLogHooks) : async OrderCatchUp {
        await catchUpOrdersFor(api, shopId, hooks, MAX_CATCH_UP_PAGES);
    };

    /// `catchUpOrders`, reading at most `maxPages` pages.
    public func catchUpOrdersFor(api : API, shopId : Principal, hooks : OrderLogHooks, maxPages : Nat) : async OrderCatchUp {
        if (not api.shopApi.isRegisteredShop(shopId)) return #notRegistered;
        if (api.catchUpsRunning.contains(shopId)) return #inProgress;
        // Lock before the first await; `finally` unlocks however the run ends.
        api.catchUpsRunning.add(shopId);
        let shopText = Principal.toText(shopId);
        var events = 0;
        var fetched = 0;
        var restarted = false;
        var complete = false;
        // Set once the shop refuses `getMyOrder`: the rest of the run doesn't ask again.
        var refused = false;
        var failedReads = 0;
        let deadline = Time.now() + CATCH_UP_TIME_BUDGET;

        /// False once the run has spent its time: what's left waits for the next.
        func inTime() : Bool { Time.now() <= deadline };

        /// False once the run may not read orders (spent its failed reads or its time). It still
        /// reads the log while in time, leaving the orders pending, so orders that keep failing
        /// can't hold up the log.
        func mayRead() : Bool { failedReads < MAX_FAILED_READS and inTime() };

        /// False once the shop was unregistered (or forgotten) during an await: nothing more is kept.
        func current() : Bool {
            not api.catchUpsCancelled.contains(shopId) and api.shopApi.isRegisteredShop(shopId);
        };

        func pendingCount() : Nat {
            switch (api.catchUp.pending.get(Principal.compare, shopId)) {
                case (?set) set.size();
                case null 0;
            };
        };

        func isPending(orderId : OrderId) : Bool {
            switch (api.catchUp.pending.get(Principal.compare, shopId)) {
                case (?set) set.contains(Nat32.compare, orderId);
                case null false;
            };
        };

        func addPending(orderId : OrderId) {
            switch (api.catchUp.pending.get(Principal.compare, shopId)) {
                case (?set) set.add(Nat32.compare, orderId);
                case null api.catchUp.pending.add(Principal.compare, shopId, CoreSet.singleton(orderId));
            };
        };

        func removePending(orderId : OrderId) {
            switch (api.catchUp.pending.get(Principal.compare, shopId)) {
                case (?set) set.remove(Nat32.compare, orderId);
                case null {};
            };
        };

        /// Reads order `orderId` from the shop and indexes it; a refused or failed read leaves it
        /// pending. False when the run must stop (the shop was unregistered meanwhile).
        /// `async*` so nothing runs between its last check of `current()` and the caller resuming.
        func fetch(orderId : OrderId) : async* Bool {
            if (refused or not mayRead()) {
                addPending(orderId);
                return true;
            };
            let response = try { await hooks.getOrder(shopId, orderId) } catch (e) {
                if (not current()) return false;
                failedReads += 1;
                api.logger.warning("Couldn't read order " # Nat32.toText(orderId) # " of shop " # shopText # "; trying again at the next catch-up: " # Error.message(e));
                addPending(orderId);
                return true;
            };
            if (not current()) return false;
            switch (response) {
                case (#ok(order)) {
                    fetched += 1;
                    removePending(orderId);
                    if (order.id == orderId) {
                        ignore upsertOrder(api, shopId, { order with orderId });
                    };
                };
                case (#err(#NotFoundError(_))) {
                    // Shops don't delete orders; nothing to index.
                    removePending(orderId);
                };
                case (#err(#Unauthorized(_))) {
                    refused := true;
                    addPending(orderId);
                };
            };
            true;
        };

        try {
            // Orders an earlier run couldn't read, taking turns so every one gets retried. Once the
            // run may not call the shop, the next run starts at the first order this one didn't try.
            let retries = nextRetries(api, shopId);
            var tried = 0;
            label retry while (tried < retries.size()) {
                if (refused or not mayRead()) break retry;
                if (not (await* fetch(retries[tried]))) return #notRegistered;
                tried += 1;
            };
            if (tried < retries.size()) {
                api.retryFrom.add(Principal.compare, shopId, retries[tried]);
            } else if (retries.size() > 0) {
                let last = retries[retries.size() - 1];
                api.retryFrom.add(Principal.compare, shopId, if (last == Nat32.maxValue) (0 : OrderId) else last + 1);
            };

            var cursor : CatchUpCursor = switch (api.catchUp.cursors.get(Principal.compare, shopId)) {
                case (?c) c;
                case null ({ last = null; notified = null });
            };
            // Read from the event core last applied, so the first item shows the log is the same one.
            var check = cursor.last;
            var after : ?Nat = switch (check) {
                case (?{ seq }) if (seq == 0) null else ?(seq - 1 : Nat);
                case null null;
            };
            var pagesLeft = maxPages;
            label pages while (pagesLeft > 0 and inTime()) {
                pagesLeft -= 1;
                let page = await hooks.listOrderEvents(shopId, after, ?CATCH_UP_PAGE_SIZE);
                if (not current()) return #notRegistered;
                switch (pageProblem(page, after)) {
                    case (?problem) {
                        api.logger.error("Order catch-up for shop " # shopText # " refused a page: " # problem);
                        return #unknown(problem);
                    };
                    case null {};
                };
                var items = page.items;
                switch (check) {
                    case (?last) {
                        check := null;
                        if (items.size() > 0 and items[0].seq == last.seq and items[0].at == last.at) {
                            items := items.sliceToArray(1, items.size());
                        } else {
                            let first = (await hooks.listOrderEvents(shopId, null, ?1)).items;
                            if (not current()) return #notRegistered;
                            if (first.size() == 0) {
                                return #skipped("The shop's order log is empty, or core can't read it");
                            };
                            api.logger.warning("Shop " # shopText # "'s order log no longer holds event " # Nat.toText(last.seq) # " (reinstalled?); reading it from the start");
                            cursor := { last = null; notified = null };
                            api.catchUp.cursors.add(Principal.compare, shopId, cursor);
                            restarted := true;
                            after := null;
                            continue pages;
                        };
                    };
                    case null {};
                };

                // Status changes for orders core has, and orders to read from the shop (each once
                // per page): ones core doesn't have, ones the event doesn't give a status for, ones
                // still pending, and ones whose event isn't about the order core has. A created
                // event's `at` is its order's `createdAt`, so another one means the shop reuses the
                // ID (reinstalled, or restored from a snapshot) and core's entry is the old order;
                // an event from before core's order was created is about an order the ID had before.
                let statusChanges = List.empty<(OrderKey, ShopInterface.OrderStatus)>();
                let toFetch = CoreSet.empty<OrderId>();
                for (event in items.values()) {
                    let key = buildOrderKey(shopId, event.orderId);
                    let status = switch (event.kind) {
                        case (?kind) statusAfter(kind);
                        case null null;
                    };
                    let known = switch (Map.get(api.orders, Map.thash, key), event.kind) {
                        case (?order, ?#created) if (order.createdAt == event.at) ?order else null;
                        case (?order, _) if (event.at >= order.createdAt) ?order else null;
                        case (null, _) null;
                    };
                    switch (known, status) {
                        case (?_, ?status) if (isPending(event.orderId)) toFetch.add(Nat32.compare, event.orderId) else statusChanges.add((key, status));
                        case _ toFetch.add(Nat32.compare, event.orderId);
                    };
                };
                // Room for the orders that would be new to the pending set if every read failed.
                var newPending = 0;
                for (orderId in toFetch.values()) if (not isPending(orderId)) newPending += 1;
                if (pendingCount() + newPending > MAX_PENDING_PER_SHOP) {
                    api.logger.warning("Shop " # shopText # " has " # Nat.toText(pendingCount()) # " orders core couldn't read; its catch-up waits until they're read");
                    break pages;
                };
                for ((key, status) in statusChanges.values()) {
                    switch (Map.get(api.orders, Map.thash, key)) {
                        case (?order) Map.set(api.orders, Map.thash, key, { order with status = laterStatus(order.status, status) });
                        case null {};
                    };
                };
                for (orderId in toFetch.values()) {
                    if (not (await* fetch(orderId))) return #notRegistered;
                };
                events += items.size();

                if (items.size() > 0) {
                    let last = items[items.size() - 1];
                    let read = ?{ seq = last.seq; at = last.at };
                    cursor := { last = read; notified = read };
                    api.catchUp.cursors.add(Principal.compare, shopId, cursor);
                };
                switch (page.next) {
                    case null {
                        // A notification during the run may name events after this page: read on.
                        if (api.notifiedDuringCatchUp.contains(shopId)) {
                            api.notifiedDuringCatchUp.remove(Principal.compare, shopId);
                            after := switch (cursor.last) {
                                case (?{ seq }) ?seq;
                                case null null;
                            };
                            continue pages;
                        };
                        complete := true;
                        break pages;
                    };
                    case (?next) after := ?next;
                };
            };
            if (not complete) {
                api.logger.warning("Order catch-up for shop " # shopText # " stopped before the end of its log; the next run carries on");
            };
            #caughtUp({
                events;
                fetched;
                pending = pendingCount();
                complete;
                restarted;
            });
        } catch (e) {
            api.logger.error("Order catch-up for shop " # shopText # " failed after " # Nat.toText(events) # " events: " # Error.message(e));
            #unknown(Error.message(e));
        } finally {
            api.catchUpsRunning.remove(Principal.compare, shopId);
            api.catchUpsCancelled.remove(Principal.compare, shopId);
            api.notifiedDuringCatchUp.remove(Principal.compare, shopId);
            if (pendingCount() == 0) api.catchUp.pending.remove(Principal.compare, shopId);
        };
    };

    /// Pages a catch-up started by a skipped notification reads (`noteNotification`). The daily run
    /// reads the rest.
    public let GAP_CATCH_UP_PAGES = 2;

    /// How often a skipped notification may start a catch-up for one shop (10 minutes). A shop
    /// decides what its notifications say, so this caps what one can make core spend.
    public let GAP_CATCH_UP_INTERVAL : Int = 600_000_000_000;

    /// Follows a shop's order log through its notifications (BRE-203), after `trackOrder` applied
    /// one. The next event in the log moves `notified` on (not `last`: after a reinstall a new log
    /// can look in step while its first events were lost, so only a catch-up's read of the log
    /// moves `last`). A skipped sequence number, an event core hasn't followed the log up to, or
    /// one that numbers from 0 again later in time (a reinstall) means core missed some: returns
    /// true when a catch-up should start, at most once per shop per `GAP_CATCH_UP_INTERVAL`.
    /// Notifications from shops before BRE-203 carry no event: they change nothing. While a
    /// catch-up runs it owns the cursor, so this leaves it alone and has the run read on to the
    /// end of the log (`notifiedDuringCatchUp`) when the event is past what it has read.
    public func noteNotification(api : API, shopId : Principal, logEvent : ?ShopInterface.OrderLogEvent, now : Int) : Bool {
        let ?event = logEvent else return false;
        if (not api.shopApi.isRegisteredShop(shopId)) return false;
        let cursor = switch (api.catchUp.cursors.get(Principal.compare, shopId)) {
            case (?c) c;
            case null ({ last = null; notified = null });
        };
        if (api.catchUpsRunning.contains(shopId)) {
            let pastRead = switch (cursor.last) {
                case (?last) event.seq > last.seq or event.at > last.at;
                case null true;
            };
            if (pastRead) api.notifiedDuringCatchUp.add(Principal.compare, shopId);
            return false;
        };
        let followed = switch (cursor.notified) {
            case (?n) ?n;
            case null cursor.last;
        };
        let inStep = switch (followed) {
            case (?last) {
                // An earlier event, delivered late: nothing missed.
                if (event.seq <= last.seq and event.at <= last.at) return false;
                event.seq == last.seq + 1;
            };
            case null event.seq == 0;
        };
        if (inStep) {
            api.catchUp.cursors.add(Principal.compare, shopId, { cursor with notified = ?{ seq = event.seq; at = event.at } });
            return false;
        };
        switch (api.lastGapCatchUp.get(Principal.compare, shopId)) {
            case (?at) if (now - at < GAP_CATCH_UP_INTERVAL) return false;
            case null {};
        };
        api.lastGapCatchUp.add(Principal.compare, shopId, now);
        true;
    };

    /// Up to `MAX_PENDING_RETRIES` of `shopId`'s pending orders, starting where the last run's
    /// retries stopped (`retryFrom`, which the run sets) and wrapping around, so orders past the
    /// first batch get their turn.
    func nextRetries(api : API, shopId : Principal) : [OrderId] {
        let ?pending = api.catchUp.pending.get(Principal.compare, shopId) else return [];
        let start : OrderId = switch (api.retryFrom.get(Principal.compare, shopId)) {
            case (?s) s;
            case null 0;
        };
        let batch = List.empty<OrderId>();
        for (id in pending.valuesFrom(Nat32.compare, start)) {
            if (batch.size() >= MAX_PENDING_RETRIES) break;
            batch.add(id);
        };
        for (id in pending.values()) {
            if (batch.size() >= MAX_PENDING_RETRIES or id >= start) break;
            batch.add(id);
        };
        batch.toArray();
    };

    /// Forgets how far core read `shopId`'s order log, for `unregisterShop`. A catch-up running for
    /// it stops at its next await and keeps nothing more.
    public func forgetShop(api : API, shopId : Principal) {
        api.catchUp.cursors.remove(Principal.compare, shopId);
        api.catchUp.pending.remove(Principal.compare, shopId);
        api.retryFrom.remove(Principal.compare, shopId);
        api.notifiedDuringCatchUp.remove(Principal.compare, shopId);
        if (api.catchUpsRunning.contains(shopId)) api.catchUpsCancelled.add(Principal.compare, shopId);
    };

    /// Subscribes core to `shopId`'s events. A failure is logged and the shop recorded in
    /// `unsubscribedShops` (see `listUnsubscribedShops`) instead of thrown, so callers that have
    /// already created the shop can carry on; `resubscribeShops` retries it.
    public func subscribeShop(api : API, shopId : Principal, subscribe : SubscribeToShopEvents) : async Result<(), Text> {
        try {
            await subscribe(shopId);
            Set.delete(api.unsubscribedShops, Set.phash, shopId);
            #ok;
        } catch (e) {
            let msg = Error.message(e);
            Set.add(api.unsubscribedShops, Set.phash, shopId);
            api.logger.error("Failed to subscribe to events of shop " # Principal.toText(shopId) # ": " # msg);
            #err(msg);
        };
    };

    /// Subscribes core to each shop's events again, one at a time, then catches up on the orders
    /// placed while it wasn't (`catchUpOrders`). Subscribing is idempotent on the shop side, so shops
    /// that are already subscribed are unaffected. Unregistered shops are skipped with an error,
    /// since `trackOrder` would ignore them anyway.
    public func resubscribeShops(api : API, shopIds : [Principal], subscribe : SubscribeToShopEvents, orderLog : OrderLogHooks) : async [ShopSubscriptionResult] {
        let results = List.empty<ShopSubscriptionResult>();
        for (shopId in shopIds.values()) {
            if (api.shopApi.isRegisteredShop(shopId)) {
                let result = await subscribeShop(api, shopId, subscribe);
                let orders = switch (result) {
                    case (#ok) await catchUpOrders(api, shopId, orderLog);
                    case (#err(_)) #skipped("Core isn't subscribed to the shop");
                };
                results.add({ shopId; result; orders });
            } else {
                results.add({
                    shopId;
                    result = #err("Shop is not registered");
                    orders = #notRegistered;
                });
            };
        };
        List.toArray(results);
    };

    /// The events `ShopEvents.subscribe` subscribes core to.
    public let SHOP_EVENTS : [ShopInterface.EventKind] = [#ShopDetailsUpdated, #ProductUpdated, #ProductDeleted, #OrderUpdated];

    public type SubscriptionCheckHooks = {
        /// For the order catch-up after each check (BRE-203).
        orderLog : OrderLogHooks;
        /// The events the shop says core is subscribed to. Throws if the shop can't say.
        getSubscriptions : (shopId : Principal) -> async [ShopInterface.EventKind];
        subscribe : SubscribeToShopEvents;
        /// A full product sync of the shop into product_index.
        syncProducts : (shopId : Principal) -> async Result<(), Text>;
    };

    public type SubscriptionCheck = {
        /// Core gets every event and the shop wasn't listed in `listUnsubscribedShops`.
        #subscribed;
        /// Core had lost `missing`, subscribed again and resynced the shop's products. A failed
        /// resync keeps the shop in `listUnsubscribedShops`, so the next check retries it.
        #resubscribed : {
            missing : [ShopInterface.EventKind];
            productSync : Result<(), Text>;
        };
        /// Core gets every event, but the shop was in `listUnsubscribedShops` (an earlier subscribe or
        /// resync failed), so core resynced its products. It leaves the list only if that succeeded.
        #resynced : { productSync : Result<(), Text> };
        /// Core had lost `missing` and couldn't subscribe again: the shop is in `listUnsubscribedShops`.
        #resubscribeFailed : {
            missing : [ShopInterface.EventKind];
            error : Text;
        };
        /// The shop couldn't say (unreachable, or a version without `getMyEventSubscriptions`). Nothing changed.
        #unknown : Text;
        #notRegistered;
    };

    public type ShopSubscriptionCheck = {
        shopId : Principal;
        check : SubscriptionCheck;
        /// The order catch-up run after the check (BRE-203).
        orders : OrderCatchUp;
    };

    /// Asks the shop which events core still gets (BRE-195). A shop drops core's subscription when it
    /// is reinstalled, when its Owner removes core, or when core loses its role there, and nothing
    /// tells core: products stop reaching product_index and orders the order index. When core is
    /// missing from an event, this subscribes again and resyncs the shop's products; a shop whose
    /// resync failed stays in `unsubscribedShops` and is resynced at the next check. Orders placed in
    /// the meantime stay missing from the order index: the shop has no way to send them again.
    public func checkShopSubscription(api : API, shopId : Principal, hooks : SubscriptionCheckHooks) : async SubscriptionCheck {
        if (not api.shopApi.isRegisteredShop(shopId)) return #notRegistered;
        let shopText = Principal.toText(shopId);
        let subscribed = try { await hooks.getSubscriptions(shopId) } catch (e) {
            return #unknown(Error.message(e));
        };
        let missing = SHOP_EVENTS.filter(func(e : ShopInterface.EventKind) : Bool = not subscribed.any(func(s : ShopInterface.EventKind) : Bool = s == e));
        if (missing.size() == 0) {
            if (not Set.has(api.unsubscribedShops, Set.phash, shopId)) return #subscribed;
            let productSync = await resyncProducts(api, shopId, hooks);
            if (productSync == #ok) Set.delete(api.unsubscribedShops, Set.phash, shopId);
            return #resynced({ productSync });
        };
        api.logger.warning("Shop " # shopText # " no longer sends core " # debug_show missing # " events; subscribing again");
        switch (await subscribeShop(api, shopId, hooks.subscribe)) {
            case (#err(error)) #resubscribeFailed({ missing; error });
            case (#ok) {
                let productSync = await resyncProducts(api, shopId, hooks);
                if (productSync == #ok) {
                    api.logger.info("Subscribed to shop " # shopText # " again and resynced its products; orders it placed while unsubscribed aren't in the order index");
                };
                #resubscribed({ missing; productSync });
            };
        };
    };

    /// A full product sync of `shopId`. On failure the shop stays in (or goes back to)
    /// `unsubscribedShops`, so the next check tries again.
    func resyncProducts(api : API, shopId : Principal, hooks : SubscriptionCheckHooks) : async Result<(), Text> {
        let productSync = try { await hooks.syncProducts(shopId) } catch (e) {
            #err(Error.message(e));
        };
        switch (productSync) {
            case (#ok) {};
            case (#err(msg)) {
                Set.add(api.unsubscribedShops, Set.phash, shopId);
                api.logger.error("Couldn't resync the products of shop " # Principal.toText(shopId) # "; the next check tries again: " # msg);
            };
        };
        productSync;
    };

    /// `checkShopSubscription` for each shop, one at a time, each followed by `catchUpOrders` for
    /// the orders whose notifications core missed. A shop core couldn't subscribe to again is skipped:
    /// core may have lost its access there, and the next check tries again.
    public func checkShopSubscriptions(api : API, shopIds : [Principal], hooks : SubscriptionCheckHooks) : async [ShopSubscriptionCheck] {
        let results = List.empty<ShopSubscriptionCheck>();
        for (shopId in shopIds.values()) {
            let check = await checkShopSubscription(api, shopId, hooks);
            let orders = switch (check) {
                case (#notRegistered) #notRegistered;
                case (#resubscribeFailed(_)) #skipped("Core isn't subscribed to the shop");
                case _ await catchUpOrders(api, shopId, hooks.orderLog);
            };
            results.add({ shopId; check; orders });
        };
        List.toArray(results);
    };

    public func listUnsubscribedShops(api : API) : [Principal] {
        Set.toArray(api.unsubscribedShops);
    };

    /// The caller's orders across shops, newest first, a page at a time.
    public func getUserOrders(api : API, caller : Principal, after : ?UserOrderCursor, limit : ?Nat) : GetUserOrdersResponse {
        if (Principal.isAnonymous(caller)) {
            return #err(#Unauthenticated);
        };

        let ?cursors = Map.get(api.ordersByBuyer, Map.phash, caller) else return #ok({
            items = [];
            next = null;
        });
        let from = switch (after) {
            case (?a) { CoreSet.valuesFrom(cursors, compareUserOrderCursor, a) };
            case null { CoreSet.values(cursors) };
        };
        #ok(
            Pagination.scan<UserOrderCursor, UserOrderListing, UserOrderCursor>(
                from,
                func c = c,
                compareUserOrderCursor,
                after,
                func c = switch (Map.get(api.orders, Map.thash, buildOrderKey(c.shopCanisterId, c.orderId))) {
                    case (?order) {
                        if (order.buyer == caller) {
                            ?{
                                shopCanisterId = order.shopId;
                                shopName = api.shopApi.getShopName(order.shopId);
                                order;
                            };
                        } else { null };
                    };
                    case (null) { null };
                },
                limit,
            )
        );
    };

    public func trackOrder(api : API, caller : Principal, req : TrackOrderRequest) : () {
        if (Principal.isAnonymous(caller)) {
            return;
        };

        if (not api.shopApi.isRegisteredShop(caller)) {
            return;
        };

        ignore upsertOrder(api, caller, req.data);
    };

    /// Stores order `data` of `shopId` and indexes it for its buyer, replacing what core had, except
    /// that the status never moves back (`laterStatus`): a late notification or snapshot of the same
    /// order can't undo a newer state. Ignores orders of the anonymous principal, and an order
    /// created before the one core has under its ID. Returns whether it stored the order.
    func upsertOrder(api : API, shopId : Principal, data : OrderData) : Bool {
        if (Principal.isAnonymous(data.buyer)) {
            return false;
        };

        let key = buildOrderKey(shopId, data.orderId);
        let fresh : Order = {
            id = data.orderId;
            shopId;
            buyer = data.buyer;
            items = data.items;
            totals = data.totals;
            status = data.status;
            createdAt = data.createdAt;
        };

        let order = switch (Map.get(api.orders, Map.thash, key)) {
            case (?previous) {
                if (previous.buyer != fresh.buyer or previous.createdAt != fresh.createdAt) {
                    // Another order under the same ID (the shop was reinstalled or restored). The
                    // later one is the shop's: an earlier one is a late read or notification of
                    // the order it replaced.
                    if (fresh.createdAt < previous.createdAt) return false;
                    unindexOrderForBuyer(api, previous);
                    fresh;
                } else {
                    {
                        fresh with status = laterStatus(previous.status, fresh.status)
                    };
                };
            };
            case null fresh;
        };
        Map.set(api.orders, Map.thash, key, order);
        indexOrderForBuyer(api, order);
        true;
    };

    func orderCursor(order : Order) : UserOrderCursor {
        {
            createdAt = order.createdAt;
            orderId = order.id;
            shopCanisterId = order.shopId;
        };
    };

    /// Adds `order` to its buyer's index. Idempotent.
    public func indexOrderForBuyer(api : API, order : Order) {
        let cursors = switch (Map.get(api.ordersByBuyer, Map.phash, order.buyer)) {
            case (?cursors) { cursors };
            case null {
                let cursors = CoreSet.empty<UserOrderCursor>();
                Map.set(api.ordersByBuyer, Map.phash, order.buyer, cursors);
                cursors;
            };
        };
        CoreSet.add(cursors, compareUserOrderCursor, orderCursor(order));
    };

    func unindexOrderForBuyer(api : API, order : Order) {
        switch (Map.get(api.ordersByBuyer, Map.phash, order.buyer)) {
            case (?cursors) {
                CoreSet.remove(cursors, compareUserOrderCursor, orderCursor(order));
            };
            case null {};
        };
    };

    public func buildOrderKey(shopId : ShopAPI.ShopId, orderId : OrderId) : OrderKey {
        Principal.toText(shopId) # ":" # Nat.toText(Nat32.toNat(orderId));
    };

    public func sortUserOrderListingsDesc(listings : [UserOrderListing]) : [UserOrderListing] {
        Array.sort(
            listings,
            func(a : UserOrderListing, b : UserOrderListing) : {
                #less;
                #equal;
                #greater;
            } {
                if (a.order.createdAt > b.order.createdAt) {
                    #less;
                } else if (a.order.createdAt < b.order.createdAt) {
                    #greater;
                } else {
                    if (a.order.id > b.order.id) {
                        #less;
                    } else if (a.order.id < b.order.id) {
                        #greater;
                    } else {
                        #equal;
                    };
                };
            },
        );
    };
};
