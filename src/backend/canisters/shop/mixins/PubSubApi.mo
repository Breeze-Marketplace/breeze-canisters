import Error "mo:core/Error";
import { type Result } "mo:core/Result";
import Principal "mo:core/Principal";

import AuthService "../lib/auth";
import ShopPermissions "../lib/permissions";
import PubSubService "../lib/pubsub";

/// Event subscriptions (per caller: subscribing again replaces the listener). Core subscribes to all four.
///
/// Only the shop's controllers and principals with the Owner, Admin or Marketplace role may
/// subscribe, and each event has at most `PubSubService.MAX_SUBSCRIBERS_PER_EVENT` subscribers
/// (BRE-67). A refused subscription throws, so the methods keep their `() -> ()` shape for core.
/// Core is a controller of the shops it creates; a shop registered with core's `registerShop` must
/// grant core `#Marketplace` (or make it a controller) before core can subscribe.
mixin (pubSubService : PubSubService.PubSubService, authService : AuthService.AuthService) {
    func requireSubscribed(result : Result<(), PubSubService.SubscribeError>) : async* () {
        switch (result) {
            case (#ok) {};
            case (#err(#Unauthorized(msg) or #TooManySubscribers(msg))) {
                throw Error.reject(msg);
            };
        };
    };

    /// Registers `caller` as a subscriber for active product create/update events.
    public shared ({ caller }) func subscribeToProductUpdated(
        listener : PubSubService.ProductUpdatedEventListener
    ) : async () {
        pubSubService.logger.info("Subscribing caller to product updated events: " # Principal.toText(caller));
        await* requireSubscribed(pubSubService.subscribeToProductUpdated(caller, listener));
    };

    /// Removes the caller's own subscription, so it needs no role.
    public shared ({ caller }) func unsubscribeFromProductUpdated() : async () {
        pubSubService.unsubscribeFromProductUpdated(caller);
        pubSubService.logger.info("Unsubscribed caller from product updated events: " # Principal.toText(caller));
    };

    /// Registers `caller` as a subscriber for product delete/archive notifications.
    public shared ({ caller }) func subscribeToProductDeleted(
        listener : PubSubService.ProductDeletedEventListener
    ) : async () {
        pubSubService.logger.info("Subscribing caller to product deleted events: " # Principal.toText(caller));
        await* requireSubscribed(pubSubService.subscribeToProductDeleted(caller, listener));
    };

    /// Removes the caller's own subscription, so it needs no role.
    public shared ({ caller }) func unsubscribeFromProductDeleted() : async () {
        pubSubService.unsubscribeFromProductDeleted(caller);
        pubSubService.logger.info("Unsubscribed caller from product deleted events: " # Principal.toText(caller));
    };

    /// Registers `caller` as a subscriber for shop metadata and location change events.
    public shared ({ caller }) func subscribeToShopDetailsUpdated(
        listener : PubSubService.ShopDetailsUpdatedEventListener
    ) : async () {
        pubSubService.logger.info("Subscribing caller to shop details updated events: " # Principal.toText(caller));
        await* requireSubscribed(pubSubService.subscribeToShopDetailsUpdated(caller, listener));
    };

    /// Removes the caller's own subscription, so it needs no role.
    public shared ({ caller }) func unsubscribeFromShopDetailsUpdated() : async () {
        pubSubService.unsubscribeFromShopDetailsUpdated(caller);
        pubSubService.logger.info("Unsubscribed caller from shop details updated events: " # Principal.toText(caller));
    };

    /// Registers `caller` as a subscriber for order create/update events, which carry the buyer
    /// and the order contents.
    public shared ({ caller }) func subscribeToOrderUpdated(
        listener : PubSubService.OrderUpdatedEventListener
    ) : async () {
        pubSubService.logger.info("Subscribing caller to order updated events: " # Principal.toText(caller));
        await* requireSubscribed(pubSubService.subscribeToOrderUpdated(caller, listener));
    };

    /// Removes the caller's own subscription, so it needs no role.
    public shared ({ caller }) func unsubscribeFromOrderUpdated() : async () {
        pubSubService.unsubscribeFromOrderUpdated(caller);
        pubSubService.logger.info("Unsubscribed caller from order updated events: " # Principal.toText(caller));
    };

    /// The events the caller is subscribed to, so core can tell when it has lost a subscription and
    /// subscribe again (BRE-195). No permission check: it shows only the caller's own subscriptions.
    public shared query ({ caller }) func getMyEventSubscriptions() : async [PubSubService.EventKind] {
        pubSubService.subscriptionsOf(caller);
    };

    /// Lists each event's subscribers. Owner or Admin.
    public shared query ({ caller }) func listEventSubscribers() : async Result<PubSubService.Subscribers, { #Unauthorized : Text }> {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.eventsView)) {
            return #err(#Unauthorized("Only Owner or Admin can list event subscribers"));
        };
        #ok(pubSubService.listSubscribers());
    };

    /// Removes `principal`'s subscription to `event`; returns whether it had one. Owner or Admin.
    public shared ({ caller }) func removeEventSubscriber(
        event : PubSubService.EventKind,
        principal : Principal,
    ) : async Result<Bool, { #Unauthorized : Text }> {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.eventsManage)) {
            return #err(#Unauthorized("Only Owner or Admin can remove event subscribers"));
        };
        let removed = pubSubService.removeSubscriber(event, principal);
        if (removed) {
            pubSubService.logger.info("Removed " # Principal.toText(principal) # " from " # debug_show (event) # " subscribers (by " # Principal.toText(caller) # ")");
        };
        #ok(removed);
    };
};
