import Array "mo:core/Array";
import CoreMap "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Set "mo:core/Set";
import Map "mo:map/Map";

// Replaces the fixed roles (`#Owner`, `#Admin`, `#Marketplace`) with an owner, Marketplace grants, and a
// team of custom roles made of permissions (BRE-151). Seeds three preset roles; every Admin gets the
// "Admin" preset, which holds every permission, so nobody loses access. The permission ids are this
// version's catalog (`lib/permissions.mo`), copied here because a migration can't import it.
module {
    type Role = { #Owner; #Admin; #Marketplace };

    type TeamRole = { name : Text; permissions : [Text] };
    type Team = {
        roles : CoreMap.Map<Nat, TeamRole>;
        members : CoreMap.Map<Principal, [Nat]>;
        counter : { var nextRoleId : Nat };
    };

    let allPermissions = [
        "Dashboard.View",
        "Products.Edit",
        "Inventory.View",
        "Inventory.Edit",
        "Orders.View",
        "Orders.Fulfill",
        "Orders.Cancel",
        "Funds.View",
        "DigitalAssets.View",
        "DigitalAssets.Edit",
        "Settings.Edit",
        "Events.View",
        "Events.Manage",
        "Logs.View",
        "Team.View",
        "Team.AssignRoles",
        "Team.EditRoles",
    ];

    let ADMIN_ROLE_ID = 1;

    public func migration(old : { rolesByPrincipal : Map.Map<Principal, [Role]> }) : {
        ownership : { var owner : ?Principal };
        marketplacePrincipals : Set.Set<Principal>;
        team : Team;
    } {
        let roles = CoreMap.empty<Nat, TeamRole>();
        roles.add(ADMIN_ROLE_ID, { name = "Admin"; permissions = allPermissions });
        roles.add(2, { name = "Catalog manager"; permissions = ["Products.Edit", "Inventory.Edit", "DigitalAssets.Edit", "Dashboard.View"] });
        roles.add(3, { name = "Fulfillment"; permissions = ["Orders.Fulfill", "Orders.Cancel", "Inventory.View"] });

        var owner : ?Principal = null;
        let marketplacePrincipals = Set.empty<Principal>();
        let members = CoreMap.empty<Principal, [Nat]>();
        for ((principal, held) in Map.entries(old.rolesByPrincipal)) {
            if (held.any(func r = r == #Owner)) {
                // The shop allows one Owner; should there be more, the others keep Admin access.
                if (owner == null) { owner := ?principal } else {
                    members.add(principal, [ADMIN_ROLE_ID]);
                };
            } else if (held.any(func r = r == #Admin)) {
                members.add(principal, [ADMIN_ROLE_ID]);
            };
            if (held.any(func r = r == #Marketplace)) {
                marketplacePrincipals.add(principal);
            };
        };

        {
            ownership = { var owner };
            marketplacePrincipals;
            team = { roles; members; counter = { var nextRoleId = 4 } };
        };
    };
};
