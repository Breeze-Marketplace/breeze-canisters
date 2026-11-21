import Array "mo:core/Array";
import CoreMap "mo:core/Map";
import Nat "mo:core/Nat";

// Adds `storefront`: the shop's storefront settings, starting with its theme (BRE-171). Every shop
// starts with no theme, so it renders exactly as before until its staff set one.
//
// Also adds the new `Storefront.Edit` permission to the "Admin" preset (role 1), but only while that
// role still holds every permission of the previous catalog: the preset means "every permission", and
// an Owner who trimmed it meant otherwise. Nothing else changes in the team.
module {
    type ThemeColor = { red : Nat8; green : Nat8; blue : Nat8 };
    type TextTone = { #dark; #light };
    type ShopTheme = {
        primary : ThemeColor;
        onPrimary : TextTone;
        accent : ThemeColor;
        onAccent : TextTone;
        fonts : { #archivoGrotesk; #grotesk; #monoGrotesk; #mono };
        shape : { #sharp; #rounded; #soft };
        colorScheme : { #dark; #light };
        hero : { #banner; #split; #minimal };
    };

    type TeamRole = { name : Text; permissions : [Text] };
    type Team = {
        roles : CoreMap.Map<Nat, TeamRole>;
        members : CoreMap.Map<Principal, [Nat]>;
        counter : { var nextRoleId : Nat };
    };

    /// The catalog before this version (`lib/permissions.mo`), copied because a migration can't import it.
    let previousCatalog = [
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
    let STOREFRONT_EDIT = "Storefront.Edit";
    let ADMIN_ROLE_ID = 1;

    type OldActor = { team : Team };
    type NewActor = {
        team : Team;
        storefront : { var theme : ?ShopTheme };
    };

    public func migration(old : OldActor) : NewActor {
        switch (old.team.roles.get(ADMIN_ROLE_ID)) {
            case (?admin) {
                let holdsAll = previousCatalog.all(func(id : Text) : Bool = admin.permissions.any(func(p : Text) : Bool = p == id));
                let hasNew = admin.permissions.any(func(p : Text) : Bool = p == STOREFRONT_EDIT);
                if (admin.name == "Admin" and holdsAll and not hasNew) {
                    old.team.roles.add(ADMIN_ROLE_ID, { admin with permissions = admin.permissions.concat([STOREFRONT_EDIT]) });
                };
            };
            case null {};
        };
        { team = old.team; storefront = { var theme = null } };
    };
};
