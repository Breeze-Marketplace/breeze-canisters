import Principal "mo:core/Principal";

import ShopInterface "../../../interfaces/shop";

/// Subscribing core to a shop's events, and checking it still is (BRE-195). The callbacks are core's own `syncShopDetails`,
/// `syncUpdatedProduct`, `syncDeletedProduct` and `trackOrder` methods, reached through an actor
/// reference to core, so this works from any mixin.
module {
    /// The shop is untrusted: a silent one must not hold up core's stop or upgrade (BRE-67/69/119).
    let callTimeoutSeconds : Nat32 = 30;

    type Callbacks = actor {
        syncShopDetails : ShopInterface.ShopDetailsUpdatedEventListener;
        syncUpdatedProduct : ShopInterface.ProductUpdatedEventListener;
        syncDeletedProduct : ShopInterface.ProductDeletedEventListener;
        trackOrder : ShopInterface.OrderUpdatedEventListener;
    };

    /// Subscribes `core` to the shop's details, product and order events. Throws if a call fails.
    public func subscribe(core : Principal, shopId : Principal) : async () {
        let callbacks = actor (core.toText()) : Callbacks;
        let shop = actor (shopId.toText()) : ShopInterface.Shop;
        await (with timeout = callTimeoutSeconds) shop.subscribeToShopDetailsUpdated(callbacks.syncShopDetails);
        await (with timeout = callTimeoutSeconds) shop.subscribeToProductUpdated(callbacks.syncUpdatedProduct);
        await (with timeout = callTimeoutSeconds) shop.subscribeToProductDeleted(callbacks.syncDeletedProduct);
        await (with timeout = callTimeoutSeconds) shop.subscribeToOrderUpdated(callbacks.trackOrder);
    };

    /// The events the shop sends the caller (core). Throws on shop versions from before BRE-195.
    public func subscriptions(shopId : Principal) : async [ShopInterface.EventKind] {
        let shop = actor (shopId.toText()) : ShopInterface.Shop;
        await (with timeout = callTimeoutSeconds) shop.getMyEventSubscriptions();
    };

    /// `subscribe` with `core` filled in, for APIs that take a subscriber function.
    public func subscriber(core : Principal) : (Principal) -> async () {
        func(shopId : Principal) : async () { await subscribe(core, shopId) };
    };
};
