import Permissions "../../../lib/Permissions";

/// The shop's permission catalog (BRE-151). Checks name permissions through these constants only, so a
/// typo fails to compile; `test/permissions.test.mo` checks the catalog. Adding a permission is safe;
/// removing or renaming one leaves it in stored roles, where it then grants nothing.
module ShopPermissions {
    public let dashboardView = "Dashboard.View";
    public let productsEdit = "Products.Edit";
    public let inventoryView = "Inventory.View";
    public let inventoryEdit = "Inventory.Edit";
    public let ordersView = "Orders.View";
    public let ordersFulfill = "Orders.Fulfill";
    public let ordersCancel = "Orders.Cancel";
    public let fundsView = "Funds.View";
    public let digitalAssetsView = "DigitalAssets.View";
    public let digitalAssetsEdit = "DigitalAssets.Edit";
    public let settingsEdit = "Settings.Edit";
    public let eventsView = "Events.View";
    public let eventsManage = "Events.Manage";
    public let logsView = "Logs.View";
    public let storefrontEdit = "Storefront.Edit";
    public let musicEdit = "Music.Edit";

    public let catalog : [Permissions.PermissionDef] = [
        { id = dashboardView; includes = [] },
        { id = productsEdit; includes = [] },
        { id = inventoryView; includes = [] },
        { id = inventoryEdit; includes = [inventoryView] },
        { id = ordersView; includes = [] },
        { id = ordersFulfill; includes = [ordersView] },
        { id = ordersCancel; includes = [ordersView] },
        { id = fundsView; includes = [] },
        { id = digitalAssetsView; includes = [] },
        { id = digitalAssetsEdit; includes = [digitalAssetsView] },
        { id = settingsEdit; includes = [] },
        { id = eventsView; includes = [] },
        { id = eventsManage; includes = [eventsView] },
        { id = logsView; includes = [] },
        { id = storefrontEdit; includes = [] },
        { id = musicEdit; includes = [] },
        { id = Permissions.TEAM_VIEW; includes = [] },
        {
            id = Permissions.TEAM_ASSIGN_ROLES;
            includes = [Permissions.TEAM_VIEW];
        },
        { id = Permissions.TEAM_EDIT_ROLES; includes = [Permissions.TEAM_VIEW] },
    ];

    /// Bounds each shop's team, so nobody with a team permission can grow the shop's state or the cost
    /// of checks without limit.
    public let limits : Permissions.Limits = {
        maxRoles = 20;
        maxMembers = 100;
        maxRolesPerMember = 5;
        maxNameLength = 50;
    };
};
