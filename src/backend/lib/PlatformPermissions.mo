import Permissions "Permissions";

/// The marketplace's platform permission catalog (BRE-152): what core's team roles are made of. Core
/// checks them for its admin methods; trust_safety and product_index ask core for them
/// (`hasPlatformPermission`), so the ids live here, shared. Checks name permissions through these
/// constants only, so a typo fails to compile. Adding a permission is safe; removing or renaming one
/// leaves it in stored roles, where it then grants nothing.
module PlatformPermissions {
    public let shopsView = "Shops.View";
    public let shopsManage = "Shops.Manage";
    public let shopCreationManage = "ShopCreation.Manage";
    public let upgradesView = "Upgrades.View";
    public let upgradesRun = "Upgrades.Run";
    public let upgradesApprove = "Upgrades.Approve";
    public let balancesView = "Balances.View";
    public let cyclesView = "Cycles.View";
    public let logsView = "Logs.View";
    public let moderationView = "Moderation.View";
    public let moderationHideProducts = "Moderation.HideProducts";
    public let moderationCategorize = "Moderation.Categorize";
    public let policiesPublish = "Policies.Publish";
    public let historyView = "History.View";

    public let catalog : [Permissions.PermissionDef] = [
        { id = shopsView; includes = [] },
        { id = shopsManage; includes = [shopsView] },
        { id = shopCreationManage; includes = [] },
        { id = upgradesView; includes = [] },
        { id = upgradesRun; includes = [upgradesView] },
        { id = upgradesApprove; includes = [upgradesView] },
        { id = balancesView; includes = [] },
        { id = cyclesView; includes = [] },
        { id = logsView; includes = [] },
        { id = moderationView; includes = [] },
        { id = moderationHideProducts; includes = [moderationView] },
        { id = moderationCategorize; includes = [moderationView] },
        { id = policiesPublish; includes = [] },
        { id = historyView; includes = [] },
        { id = Permissions.TEAM_VIEW; includes = [] },
        {
            id = Permissions.TEAM_ASSIGN_ROLES;
            includes = [Permissions.TEAM_VIEW];
        },
        { id = Permissions.TEAM_EDIT_ROLES; includes = [Permissions.TEAM_VIEW] },
    ];

    /// Bounds the platform team, so nobody with a team permission can grow core's state or the cost of
    /// checks without limit.
    public let limits : Permissions.Limits = {
        maxRoles = 20;
        maxMembers = 100;
        maxRolesPerMember = 5;
        maxNameLength = 50;
    };
};
