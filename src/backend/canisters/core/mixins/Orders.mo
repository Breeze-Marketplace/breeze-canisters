import Iter "mo:core/Iter";
import Time "mo:core/Time";
import { type Result } "mo:core/Result";
import Map "mo:map/Map";

import AdminAPI "../api/admin";
import PlatformPermissions "../../../lib/PlatformPermissions";
import OrderAPI "../api/orders";
import ShopAPI "../api/shop";
import ShopCallFeesAPI "../api/shop_call_fees";
import ShopEvents "../lib/ShopEvents";

/// The cross-shop order index that shops keep current through `trackOrder`.
mixin (
    orderApi : OrderAPI.API,
    adminApi : AdminAPI.API,
    shopRegistry : Map.Map<Principal, ShopAPI.ShopRegistryItem>,
    callFees : ShopCallFeesAPI.State,
    coreId : Principal,
    subscriptionChecks : OrderAPI.SubscriptionCheckHooks,
) {
    /// Upserts a marketplace-wide order index entry. Called by a registered shop canister
    /// when an order is created or its status changes. Every caller must attach
    /// `ShopCallFees.EVENT_CYCLES` once enforced (BRE-116). A notification that shows core missed
    /// some of the shop's order log starts a short catch-up (BRE-203; rate-limited per shop).
    public shared ({ caller }) func trackOrder(req : OrderAPI.TrackOrderRequest) : async () {
        await* ShopCallFeesAPI.chargeOrReject<system>(callFees);
        OrderAPI.trackOrder(orderApi, caller, req);
        if (OrderAPI.noteNotification(orderApi, caller, req.data.logEvent, Time.now())) {
            // Not awaited: the shop doesn't wait on core's catch-up.
            ignore OrderAPI.catchUpOrdersFor(orderApi, caller, subscriptionChecks.orderLog, OrderAPI.GAP_CATCH_UP_PAGES);
        };
    };

    /// Orders indexed for the authenticated caller across shops, newest first, a page at a time (see
    /// `lib/Pagination`: pass `next` back as `after`).
    public query ({ caller }) func getUserOrders(after : ?OrderAPI.UserOrderCursor, limit : ?Nat) : async OrderAPI.GetUserOrdersResponse {
        OrderAPI.getUserOrders(orderApi, caller, after, limit);
    };

    /// Subscribes core to the events (orders included) of `shopIds`, or of every registered shop
    /// when null, then catches up on each one's orders from its order log (BRE-203). Backfills shops
    /// created before core subscribed hosted shops to orders, and retries those in
    /// `listUnsubscribedShops`. Idempotent. Needs `Shops.Manage`: each shop costs core calls.
    public shared ({ caller }) func resubscribeShops(shopIds : ?[Principal]) : async Result<[OrderAPI.ShopSubscriptionResult], { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.shopsManage)) {
            return #err(#Unauthorized);
        };
        let ids = shopIds ?? Iter.toArray(Map.keys(shopRegistry));
        #ok(await OrderAPI.resubscribeShops(orderApi, ids, ShopEvents.subscriber(coreId), subscriptionChecks.orderLog));
    };

    /// Asks `shopIds`, or every registered shop when null, which events core still gets, one shop at
    /// a time. Where core lost one, subscribes again and resyncs the shop's products (BRE-195). Then
    /// catches up on the shop's orders from its order log (BRE-203). Core also runs this daily and
    /// five minutes after each install or upgrade. Needs `Shops.Manage`: each shop costs core a call,
    /// a resync a call per page of products, and a catch-up a call per page of events and per order
    /// it reads.
    public shared ({ caller }) func checkShopSubscriptions(shopIds : ?[Principal]) : async Result<[OrderAPI.ShopSubscriptionCheck], { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.shopsManage)) {
            return #err(#Unauthorized);
        };
        let ids = shopIds ?? Iter.toArray(Map.keys(shopRegistry));
        #ok(await OrderAPI.checkShopSubscriptions(orderApi, ids, subscriptionChecks));
    };

    /// Registered shops whose events core may have missed: the last event subscription failed, or
    /// `checkShopSubscriptions` found the shop had dropped core and couldn't resubscribe or resync its
    /// products (the next check retries the resync). Their products and orders may be missing from the
    /// marketplace. Retry them with `resubscribeShops` or `checkShopSubscriptions`. Needs `Shops.View`.
    public query ({ caller }) func listUnsubscribedShops() : async Result<[Principal], { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.shopsView)) {
            return #err(#Unauthorized);
        };
        #ok(OrderAPI.listUnsubscribedShops(orderApi));
    };
};
