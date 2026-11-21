import Array "mo:base/Array";
import Nat32 "mo:base/Nat32";
import Cycles "mo:core/Cycles";
import List "mo:core/List";
import { type Result } "mo:core/Result";
import Time "mo:core/Time";
import Map "mo:map/Map";

import AdminAccess "../lib/admin_access";
import AuthService "../lib/auth";
import Dashboard "../lib/dashboard";

import {
    type Product;
    type ProductId;
    type ProductVariant;
    type VariantId;
    type InventoryEntry;
    type Alert;
    type Order;
    type OrderId;
} "../types";

/// The admin dashboard (Owner or Admin), the older counts and low-stock alerts, and the cycle balance.
mixin (
    products : Map.Map<ProductId, Product>,
    productVariants : Map.Map<VariantId, ProductVariant>,
    inventory : Map.Map<VariantId, InventoryEntry>,
    orders : Map.Map<OrderId, Order>,
    authService : AuthService.AuthService,
) {
    /// Owner or Admin: everything the admin dashboard shows, in one call (BRE-146). See
    /// `Dashboard.Dashboard` for each field. Reads every order, like `listOrders`.
    public query ({ caller }) func getDashboard() : async Result<Dashboard.Dashboard, { #Unauthorized : Text }> {
        if (not AdminAccess.canViewDashboard(authService, caller)) {
            return #err(#Unauthorized("Only the shop's Owner and Admins can see its dashboard"));
        };
        #ok(
            Dashboard.build({
                now = Time.now();
                products = Map.vals(products);
                inventory = Map.entries(inventory);
                orders = Map.vals(orders);
                productById = func(id : ProductId) : ?Dashboard.ProductInput = Map.get(products, Map.n32hash, id);
                variantById = func(id : VariantId) : ?Dashboard.VariantInput = Map.get(productVariants, Map.n32hash, id);
            })
        );
    };

    /// Owner or Admin: aggregate counts of products, active listings, low-stock SKUs, and open
    /// orders (paid, not yet fulfilled). Other callers get all zeros (BRE-105). Superseded by
    /// `getDashboard`; kept for frontends talking to shops not yet upgraded.
    public query ({ caller }) func getStats() : async {
        totalProducts : Nat32;
        activeListings : Nat32;
        lowStockItems : Nat32;
        openOrders : Nat32;
    } {
        if (not AdminAccess.canViewDashboard(authService, caller)) {
            return {
                totalProducts = 0;
                activeListings = 0;
                lowStockItems = 0;
                openOrders = 0;
            };
        };
        var activeListings : Nat32 = 0;
        for (product in Map.vals(products)) {
            if (product.status == #Active) activeListings += 1;
        };
        var openOrders : Nat32 = 0;
        for (order in Map.vals(orders)) {
            if (Dashboard.isToFulfill(order.status)) openOrders += 1;
        };

        return {
            totalProducts = Nat32.fromNat(Map.size(products));
            activeListings;
            lowStockItems = Nat32.fromNat(Array.size(getLowStockItems()));
            openOrders;
        };
    };

    /// Owner or Admin: low-stock alerts derived from inventory thresholds (one alert per qualifying
    /// inventory row). Other callers get `[]` (BRE-105). Superseded by `getDashboard`'s `stock`.
    public query ({ caller }) func getAlerts() : async [Alert] {
        if (not AdminAccess.canViewDashboard(authService, caller)) {
            return [];
        };
        Array.map<{ product : { id : ProductId; name : Text }; currentStock : Nat32 }, Alert>(
            getLowStockItems(),
            func(item) = #LowStock(item),
        );
    };

    /// Returns this canister's cycle balance. No caller check: the balance is not private (anyone can
    /// read it from core's `getShopCycles`), and a fake 0 for outsiders would look like a drained shop.
    public query func getCyclesBalance() : async Nat {
        Cycles.balance();
    };

    private func getLowStockItems() : [{
        product : { id : ProductId; name : Text };
        currentStock : Nat32;
    }] {
        let lowStockItems = List.empty<{ product : { id : ProductId; name : Text }; currentStock : Nat32 }>();

        label _loop for (entry in Map.vals(inventory)) {
            if (entry.stock < entry.lowStockThreshold) {
                let product = switch (Map.get(products, Map.n32hash, entry.productId)) {
                    case (?p) p;
                    case null { continue _loop };
                };
                List.add(
                    lowStockItems,
                    {
                        product = { id = product.id; name = product.title };
                        currentStock = entry.stock;
                    },
                );
            };
        };

        return List.toArray(lowStockItems);
    };
};
