import AuthService "auth";
import ShopPermissions "permissions";

/// Who may read the shop's admin-only data (dashboard stats and alerts, inventory, digital asset keys).
/// Kept apart from `../types` (which imports `canister:xrc`) so it can run under `mops test`.
/// Marketplace (core) and everyone without the permission get nothing (BRE-105).
module AdminAccess {
    public func canViewDashboard(authService : AuthService.AuthService, caller : Principal) : Bool {
        AuthService.hasPermission(authService, caller, ShopPermissions.dashboardView);
    };

    public func canViewInventory(authService : AuthService.AuthService, caller : Principal) : Bool {
        AuthService.hasPermission(authService, caller, ShopPermissions.inventoryView);
    };

    public func canViewDigitalAssets(authService : AuthService.AuthService, caller : Principal) : Bool {
        AuthService.hasPermission(authService, caller, ShopPermissions.digitalAssetsView);
    };
};
