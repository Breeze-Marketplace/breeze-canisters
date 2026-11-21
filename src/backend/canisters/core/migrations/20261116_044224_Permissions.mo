import CoreMap "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Set "mo:map/Set";

// Replaces the all-or-nothing admin list with a team of roles made of platform permissions (BRE-152).
// Seeds three preset roles; every admin gets the "Admin" preset, which holds every permission, so
// nobody loses access. Controllers need no role: they hold every permission. The permission ids are
// this version's catalog (`lib/PlatformPermissions.mo`), copied here because a migration can't import it.
module {
    type TeamRole = { name : Text; permissions : [Text] };
    public type Team = {
        roles : CoreMap.Map<Nat, TeamRole>;
        members : CoreMap.Map<Principal, [Nat]>;
        counter : { var nextRoleId : Nat };
    };

    let allPermissions = [
        "Shops.View",
        "Shops.Manage",
        "ShopCreation.Manage",
        "Upgrades.View",
        "Upgrades.Run",
        "Upgrades.Approve",
        "Balances.View",
        "Cycles.View",
        "Logs.View",
        "Moderation.View",
        "Moderation.HideProducts",
        "Moderation.Categorize",
        "Policies.Publish",
        "Team.View",
        "Team.AssignRoles",
        "Team.EditRoles",
    ];

    let ADMIN_ROLE_ID = 1;

    public func migration(old : { admins : Set.Set<Principal> }) : {
        team : Team;
    } {
        let roles = CoreMap.empty<Nat, TeamRole>();
        roles.add(ADMIN_ROLE_ID, { name = "Admin"; permissions = allPermissions });
        roles.add(2, { name = "Moderator"; permissions = ["Moderation.HideProducts", "Moderation.Categorize"] });
        roles.add(3, { name = "Release manager"; permissions = ["Upgrades.Run", "Upgrades.Approve", "Shops.View", "Logs.View"] });

        let members = CoreMap.empty<Principal, [Nat]>();
        for (admin in Set.keys(old.admins)) {
            members.add(admin, [ADMIN_ROLE_ID]);
        };

        { team = { roles; members; counter = { var nextRoleId = 4 } } };
    };
};
