import Map "mo:map/Map";
import Principal "mo:core/Principal";
import Array "mo:core/Array";
import Error "mo:core/Error";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Result "mo:core/Result";
import Time "mo:core/Time";

import Logger "../../../lib/Logger";
import ShopCallFees "../../../lib/ShopCallFees";

import {
    type ProductVariant;
    type ProductAttribute;
    type Money;
    type ProductId;
    type VariantId;
    type OrderId;
    type SKU;
    type ProductStatus;
    type Product;
    type ShopLocation;
    type ProductType;
    type LineItemSnapshot;
    type Totals;
    type OrderStatus;
    type Order;
    type Deliverable;
    type MarketplaceRelease;
    type Presentation;
    type ShopProfile;
} "../types";
import Subscriptions "subscriptions";

module {
    public type ProductUpdatedEventData = {
        productId : ProductId;
        title : Text;
        description : Text;
        variants : [ProductUpdatedVariant];
        tags : [Text];
        category : ?Text;
        productType : ProductType;
    };

    public type ProductUpdatedEvent = { data : ProductUpdatedEventData };

    public type ProductUpdatedEventListener = shared (event : ProductUpdatedEvent) -> async ();

    public type ProductDeletedEvent = { data : { productId : ProductId } };

    public type ProductDeletedEventListener = shared (event : ProductDeletedEvent) -> async ();

    public type ShopUpdatedEventData = {
        name : Text;
        description : Text;
        logoUrl : Text;
        bannerImageUrl : ?Text;
        physicalLocation : ?ShopLocation;
        locationPublic : Bool;
        /// Storefront or artist page (BRE-197). Optional so a subscriber can tell an older shop, which
        /// doesn't send it, and gets null for a mode it doesn't know.
        presentation : ?Presentation;
    };

    /// The details event for the shop as it is now. The location is always included, also when it
    /// isn't public: subscribers are core and staff with `Events.Manage`, and core indexes it.
    public func shopDetailsEventData(profile : ShopProfile, presentation : Presentation) : ShopUpdatedEventData {
        {
            name = profile.name;
            description = profile.description;
            logoUrl = switch (profile.logoUrl) { case (?u) u; case null "" };
            bannerImageUrl = profile.bannerImageUrl;
            physicalLocation = profile.physicalLocation;
            locationPublic = profile.showPhysicalLocation;
            presentation = ?presentation;
        };
    };

    public type ShopDetailsUpdatedEvent = { data : ShopUpdatedEventData };

    public type ShopDetailsUpdatedEventListener = shared (event : ShopDetailsUpdatedEvent) -> async ();

    public type OrderUpdatedEventData = {
        orderId : OrderId;
        buyer : Principal;
        items : [LineItemSnapshot];
        totals : Totals;
        status : OrderStatus;
        createdAt : Time.Time;
        /// The order log event this notification is for (BRE-203): a subscriber that sees a number
        /// skipped knows it missed one and catches up with `listOrderEvents`. Optional so a
        /// subscriber can tell an older shop, which doesn't send it.
        logEvent : ?OrderLogEvent;
    };

    /// Where an event sits in the shop's order log: its sequence number and time.
    public type OrderLogEvent = { seq : Nat; at : Int };

    public type OrderUpdatedEvent = { data : OrderUpdatedEventData };

    public type OrderUpdatedEventListener = shared (event : OrderUpdatedEvent) -> async ();

    /// The events a shop publishes, for managing subscribers.
    public type EventKind = {
        #ProductUpdated;
        #ProductDeleted;
        #ShopDetailsUpdated;
        #OrderUpdated;
    };

    public type SubscribeError = Subscriptions.SubscribeError;

    /// The principals subscribed to each event.
    public type Subscribers = {
        productUpdated : [Principal];
        productDeleted : [Principal];
        shopDetailsUpdated : [Principal];
        orderUpdated : [Principal];
    };

    public let MAX_SUBSCRIBERS_PER_EVENT = Subscriptions.MAX_SUBSCRIBERS_PER_EVENT;

    /// Each notification carries `ShopCallFees.EVENT_CYCLES`: core keeps them from a shop it doesn't
    /// host and hands them back from a hosted one (BRE-116).
    ///
    /// Notifications are bounded-wait calls: a listener that never replies can't stop the shop from
    /// being stopped (and so upgraded) for longer than this (BRE-67).
    public let NOTIFY_TIMEOUT_SECONDS : Nat32 = 30;

    /// Subscriptions to the shop's events. Only principals for which `isAllowed` holds can subscribe,
    /// and it's checked again before each notification: a subscriber that has lost its access is
    /// removed instead of notified. The anonymous principal is never allowed.
    public class PubSubService(
        productUpdatedSubscribers : Map.Map<Principal, ProductUpdatedEventListener>,
        productDeletedSubscribers : Map.Map<Principal, ProductDeletedEventListener>,
        shopDetailsUpdatedSubscribers : Map.Map<Principal, ShopDetailsUpdatedEventListener>,
        orderUpdatedSubscribers : Map.Map<Principal, OrderUpdatedEventListener>,
        isAllowed : (Principal) -> Bool,
        _logger : Logger.BoundLogger,
        releaseOf : ?Deliverable -> ?MarketplaceRelease,
    ) {
        public let logger = _logger;

        func subscribe<L>(event : Text, subscribers : Map.Map<Principal, L>, caller : Principal, listener : L) : Result.Result<(), SubscribeError> {
            Subscriptions.subscribe(subscribers, isAllowed, event, caller, listener);
        };

        func allowedSubscribers<L>(event : Text, subscribers : Map.Map<Principal, L>) : [(Principal, L)] {
            Subscriptions.allowed(subscribers, isAllowed, event, logger.warning);
        };

        /// For a caller that couldn't start a notification at all: a `notify…` call is a self-call,
        /// which throws in the caller when it can't be sent (the shop is short of cycles or its
        /// queue is full). Callers catch it and log it here, so the change they made stands (BRE-109).
        public func logUnsent(event : Text, e : Error.Error) {
            logger.error("Couldn't send the " # event # " notification: " # Error.message(e));
        };

        func logFailure(event : Text, subscriber : Principal, e : Error.Error) {
            logger.error("Failed to notify " # event # " subscriber " # Principal.toText(subscriber) # ": " # Error.message(e));
        };

        public func subscribeToProductUpdated(caller : Principal, listener : ProductUpdatedEventListener) : Result.Result<(), SubscribeError> {
            subscribe("ProductUpdated", productUpdatedSubscribers, caller, listener);
        };

        public func unsubscribeFromProductUpdated(caller : Principal) : () {
            Map.delete(productUpdatedSubscribers, Map.phash, caller);
        };

        /// Sends the event to every allowed subscriber at once, then waits for the replies (each
        /// bounded by `NOTIFY_TIMEOUT_SECONDS`) and logs failures. Callers `ignore` the result
        /// rather than wait for subscribers.
        public func notifyProductUpdated(product : Product) : async () {
            let event = { data = convertProduct(product, releaseOf) };
            let calls = List.empty<(Principal, async ())>();
            for ((p, listener) in allowedSubscribers("ProductUpdated", productUpdatedSubscribers).vals()) {
                try {
                    List.add(calls, (p, (with timeout = NOTIFY_TIMEOUT_SECONDS; cycles = ShopCallFees.EVENT_CYCLES) listener(event)));
                } catch (e) { logFailure("ProductUpdated", p, e) };
            };
            for ((p, call) in List.values(calls)) {
                try { await call } catch (e) {
                    logFailure("ProductUpdated", p, e);
                };
            };
        };

        public func subscribeToProductDeleted(caller : Principal, listener : ProductDeletedEventListener) : Result.Result<(), SubscribeError> {
            subscribe("ProductDeleted", productDeletedSubscribers, caller, listener);
        };

        public func unsubscribeFromProductDeleted(caller : Principal) : () {
            Map.delete(productDeletedSubscribers, Map.phash, caller);
        };

        public func notifyProductDeleted(productId : ProductId) : async () {
            let event = { data = { productId } };
            let calls = List.empty<(Principal, async ())>();
            for ((p, listener) in allowedSubscribers("ProductDeleted", productDeletedSubscribers).vals()) {
                try {
                    List.add(calls, (p, (with timeout = NOTIFY_TIMEOUT_SECONDS; cycles = ShopCallFees.EVENT_CYCLES) listener(event)));
                } catch (e) { logFailure("ProductDeleted", p, e) };
            };
            for ((p, call) in List.values(calls)) {
                try { await call } catch (e) {
                    logFailure("ProductDeleted", p, e);
                };
            };
        };

        public func subscribeToShopDetailsUpdated(caller : Principal, listener : ShopDetailsUpdatedEventListener) : Result.Result<(), SubscribeError> {
            subscribe("ShopDetailsUpdated", shopDetailsUpdatedSubscribers, caller, listener);
        };

        public func unsubscribeFromShopDetailsUpdated(caller : Principal) : () {
            Map.delete(shopDetailsUpdatedSubscribers, Map.phash, caller);
        };

        public func notifyShopDetailsUpdated(eventData : ShopUpdatedEventData) : async () {
            let event = { data = eventData };
            let calls = List.empty<(Principal, async ())>();
            for ((p, listener) in allowedSubscribers("ShopDetailsUpdated", shopDetailsUpdatedSubscribers).vals()) {
                try {
                    List.add(calls, (p, (with timeout = NOTIFY_TIMEOUT_SECONDS; cycles = ShopCallFees.EVENT_CYCLES) listener(event)));
                } catch (e) { logFailure("ShopDetailsUpdated", p, e) };
            };
            for ((p, call) in List.values(calls)) {
                try { await call } catch (e) {
                    logFailure("ShopDetailsUpdated", p, e);
                };
            };
        };

        public func subscribeToOrderUpdated(caller : Principal, listener : OrderUpdatedEventListener) : Result.Result<(), SubscribeError> {
            subscribe("OrderUpdated", orderUpdatedSubscribers, caller, listener);
        };

        public func unsubscribeFromOrderUpdated(caller : Principal) : () {
            Map.delete(orderUpdatedSubscribers, Map.phash, caller);
        };

        /// Order events carry the buyer and the order contents, which is why every subscriber must
        /// pass `isAllowed` at send time, not only when it subscribed.
        public func notifyOrderUpdated(order : Order, logEvent : ?OrderLogEvent) : async () {
            let event = { data = convertOrder(order, logEvent) };
            let calls = List.empty<(Principal, async ())>();
            for ((p, listener) in allowedSubscribers("OrderUpdated", orderUpdatedSubscribers).vals()) {
                try {
                    List.add(calls, (p, (with timeout = NOTIFY_TIMEOUT_SECONDS; cycles = ShopCallFees.EVENT_CYCLES) listener(event)));
                } catch (e) { logFailure("OrderUpdated", p, e) };
            };
            for ((p, call) in List.values(calls)) {
                try { await call } catch (e) {
                    logFailure("OrderUpdated", p, e);
                };
            };
        };

        /// Removes `principal`'s subscription to `event`. Returns whether there was one.
        public func removeSubscriber(event : EventKind, principal : Principal) : Bool {
            switch (event) {
                case (#ProductUpdated) {
                    Map.remove(productUpdatedSubscribers, Map.phash, principal) != null;
                };
                case (#ProductDeleted) {
                    Map.remove(productDeletedSubscribers, Map.phash, principal) != null;
                };
                case (#ShopDetailsUpdated) {
                    Map.remove(shopDetailsUpdatedSubscribers, Map.phash, principal) != null;
                };
                case (#OrderUpdated) {
                    Map.remove(orderUpdatedSubscribers, Map.phash, principal) != null;
                };
            };
        };

        /// The events `principal` would be notified of: none once it is no longer allowed, since the
        /// next notification removes it.
        public func subscriptionsOf(principal : Principal) : [EventKind] {
            let events = List.empty<EventKind>();
            func check<L>(event : EventKind, subscribers : Map.Map<Principal, L>) {
                if (Subscriptions.isSubscribed(subscribers, isAllowed, principal)) events.add(event);
            };
            check(#ProductUpdated, productUpdatedSubscribers);
            check(#ProductDeleted, productDeletedSubscribers);
            check(#ShopDetailsUpdated, shopDetailsUpdatedSubscribers);
            check(#OrderUpdated, orderUpdatedSubscribers);
            events.toArray();
        };

        public func listSubscribers() : Subscribers {
            {
                productUpdated = Iter.toArray(Map.keys(productUpdatedSubscribers));
                productDeleted = Iter.toArray(Map.keys(productDeletedSubscribers));
                shopDetailsUpdated = Iter.toArray(Map.keys(shopDetailsUpdatedSubscribers));
                orderUpdated = Iter.toArray(Map.keys(orderUpdatedSubscribers));
            };
        };
    };

    private func convertOrder(order : Order, logEvent : ?OrderLogEvent) : OrderUpdatedEventData {
        {
            orderId = order.id;
            buyer = order.buyer;
            items = order.items;
            totals = order.totals;
            status = order.status;
            createdAt = order.createdAt;
            logEvent;
        };
    };

    public type ProductUpdatedVariant = {
        variantId : VariantId;
        name : Text;
        sku : SKU;
        priceCatalog : [Money];
        status : ProductStatus;
        attributes : [ProductAttribute];
        imageUrls : [Text];
        /// The release the variant sells, for the marketplace's Music listings (BRE-187); null otherwise.
        release : ?MarketplaceRelease;
    };

    func convertProduct(p : Product, releaseOf : ?Deliverable -> ?MarketplaceRelease) : ProductUpdatedEventData {
        {
            productId = p.id;
            title = p.title;
            description = p.description;
            productType = p.productType;
            variants = Array.map<ProductVariant, ProductUpdatedVariant>(
                p.variants,
                func(v) = {
                    variantId = v.id;
                    name = v.name;
                    sku = v.sku;
                    priceCatalog = v.price.catalog;
                    status = v.status;
                    attributes = v.attributes;
                    imageUrls = v.imageUrls;
                    release = releaseOf(v.deliverable);
                },
            );
            tags = p.tags;
            category = p.category;
        };
    };
};
