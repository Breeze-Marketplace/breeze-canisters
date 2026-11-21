import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import CoreMap "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Map "mo:map/Map";

import PermissionsMigration "../migrations/20261115_064951_Permissions";
import Migration "../migrations/20261117_034407_StorefrontTheme";

let admin = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");

type Role = { #Owner; #Admin; #Marketplace };

/// A team as the permissions migration seeds it, with one old Admin.
func seededTeam() : {
    roles : CoreMap.Map<Nat, { name : Text; permissions : [Text] }>;
    members : CoreMap.Map<Principal, [Nat]>;
    counter : { var nextRoleId : Nat };
} {
    let rolesByPrincipal = Map.new<Principal, [Role]>();
    Map.set(rolesByPrincipal, Map.phash, admin, [#Admin]);
    PermissionsMigration.migration({ rolesByPrincipal }).team;
};

/// The catalog when this migration shipped, before BRE-182 added `Music.Edit`. Listed rather than derived
/// from `ShopPermissions.catalog`, so later permissions (added by their own migrations) don't change it.
let catalogBeforeMusicEdit = [
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
    "Storefront.Edit",
    "Team.View",
    "Team.AssignRoles",
    "Team.EditRoles",
];

func permissionsOf(team : { roles : CoreMap.Map<Nat, { name : Text; permissions : [Text] }> }, id : Nat) : [Text] {
    switch (team.roles.get(id)) {
        case (?role) role.permissions;
        case null [];
    };
};

suite(
    "StorefrontTheme migration",
    func() {
        test(
            "starts every shop with no theme",
            func() {
                let after = Migration.migration({ team = seededTeam() });
                expect.bool(after.storefront.theme == null).isTrue();
            },
        );
        test(
            "the untouched Admin preset holds exactly this version's catalog",
            func() {
                let after = Migration.migration({ team = seededTeam() });
                let catalogIds = catalogBeforeMusicEdit.sort(Text.compare);
                expect.bool(permissionsOf(after.team, 1).sort(Text.compare) == catalogIds).isTrue();
                // Other presets and members are unchanged.
                expect.bool(permissionsOf(after.team, 2) == permissionsOf(seededTeam(), 2)).isTrue();
                expect.bool(after.team.members.get(admin) == ?[1]).isTrue();
            },
        );
        test(
            "a trimmed Admin role doesn't gain Storefront.Edit",
            func() {
                let team = seededTeam();
                team.roles.add(1, { name = "Admin"; permissions = ["Orders.View"] });
                let after = Migration.migration({ team });
                expect.bool(permissionsOf(after.team, 1) == ["Orders.View"]).isTrue();
            },
        );
        test(
            "a renamed role 1 doesn't gain it, and running twice adds it once",
            func() {
                let renamed = seededTeam();
                let full = permissionsOf(renamed, 1);
                renamed.roles.add(1, { name = "Support"; permissions = full });
                expect.bool(permissionsOf(Migration.migration({ team = renamed }).team, 1) == full).isTrue();

                let twice = Migration.migration(Migration.migration({ team = seededTeam() }));
                expect.nat(permissionsOf(twice.team, 1).size()).equal(catalogBeforeMusicEdit.size());
            },
        );
        test(
            "a shop without role 1 migrates unchanged",
            func() {
                let team = seededTeam();
                team.roles.remove(1);
                let after = Migration.migration({ team });
                expect.bool(after.team.roles.get(1) == null).isTrue();
            },
        );
    },
);
