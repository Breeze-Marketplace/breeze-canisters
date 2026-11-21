import Iter "mo:core/Iter";
import Principal "mo:core/Principal";

import AuthService "auth";
import ShopPermissions "permissions";

/// Who may read or change an order. Takes `{ buyer : Principal }` rather than `Order` so it does not
/// import `../types` (which imports `canister:xrc`) and can run under `mops test`.
module OrderAccess {
    /// True when `caller` placed the order. The anonymous principal never counts as a buyer, so an
    /// order placed anonymously is not readable or cancellable by every other anonymous caller.
    public func isBuyer(caller : Principal, order : { buyer : Principal }) : Bool {
        not Principal.isAnonymous(caller) and Principal.equal(caller, order.buyer);
    };

    /// True when `caller` may place an order. The anonymous principal may not: it never counts as the
    /// buyer, so nobody could read or pay for the order it placed. Checkout requires sign-in (BRE-32).
    public func canPlaceOrder(caller : Principal) : Bool {
        not Principal.isAnonymous(caller);
    };

    /// How many orders awaiting payment one buyer may hold in a shop at once (BRE-111). Each open
    /// order costs the shop a ledger read per watcher pass and at expiry, so the cap bounds what one
    /// caller can make the shop spend. Above one so a buyer can still re-order while an old order lapses.
    public let MAX_UNPAID_ORDERS_PER_BUYER : Nat = 3;

    /// True when `caller` holds fewer than `MAX_UNPAID_ORDERS_PER_BUYER` of `unpaidOrders`, the
    /// shop's orders awaiting payment.
    public func hasRoomForUnpaidOrder(caller : Principal, unpaidOrders : Iter.Iter<{ buyer : Principal }>) : Bool {
        var held = 0;
        for (order in unpaidOrders) {
            if (Principal.equal(order.buyer, caller)) {
                held += 1;
                if (held >= MAX_UNPAID_ORDERS_PER_BUYER) return false;
            };
        };
        true;
    };

    /// Whether `caller` may see every order in the shop (`Orders.View`).
    public func canViewAllOrders(authService : AuthService.AuthService, caller : Principal) : Bool {
        AuthService.hasPermission(authService, caller, ShopPermissions.ordersView);
    };

    /// Whether `caller` may cancel any order and return its payment to the buyer (`Orders.Cancel`).
    public func canCancelAllOrders(authService : AuthService.AuthService, caller : Principal) : Bool {
        AuthService.hasPermission(authService, caller, ShopPermissions.ordersCancel);
    };

    /// The order's buyer, or anyone who may see every order.
    public func canViewOrder(
        authService : AuthService.AuthService,
        caller : Principal,
        order : { buyer : Principal },
    ) : Bool {
        isBuyer(caller, order) or canViewAllOrders(authService, caller);
    };

    /// The order's buyer, or anyone who may cancel every order.
    public func canCancelOrder(
        authService : AuthService.AuthService,
        caller : Principal,
        order : { buyer : Principal },
    ) : Bool {
        isBuyer(caller, order) or canCancelAllOrders(authService, caller);
    };
};
