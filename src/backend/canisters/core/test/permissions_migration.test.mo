import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Set "mo:map/Set";

import PlatformPermissions "../../../lib/PlatformPermissions";
import Migration "../migrations/20261116_044224_Permissions";
// Every later migration that adds a permission to the Admin preset, in order.
import Later "../migrations/20261116_085855_MarketplaceHistory";

let admin = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let otherAdmin = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");

func migrate(admins : [Principal]) : Migration.Team {
    let set = Set.new<Principal>();
    for (p in admins.values()) { Set.add(set, Set.phash, p) };
    Migration.migration({ admins = set }).team;
};

suite(
    "Platform permissions migration",
    func() {
        test(
            "every admin gets the Admin role",
            func() {
                let team = migrate([admin, otherAdmin]);
                expect.bool(team.members.get(admin) == ?[1]).isTrue();
                expect.bool(team.members.get(otherAdmin) == ?[1]).isTrue();
                expect.nat(team.members.size()).equal(2);
            },
        );

        test(
            "the Admin role, with the permissions later migrations add, holds the whole catalog",
            func() {
                let team = Later.migration({ team = migrate([]) }).team;
                let ?adminRole = team.roles.get(1) else return assert false;
                expect.text(adminRole.name).equal("Admin");
                let catalogIds = PlatformPermissions.catalog.map(func d = d.id);
                expect.nat(adminRole.permissions.size()).equal(catalogIds.size());
                for (id in catalogIds.values()) {
                    expect.bool(adminRole.permissions.contains(id)).isTrue();
                };
            },
        );

        test(
            "presets use only catalog permissions and new roles start after them",
            func() {
                let team = Later.migration({ team = migrate([]) }).team;
                let catalogIds = PlatformPermissions.catalog.map(func d = d.id);
                for ((_, role) in team.roles.entries()) {
                    for (p in role.permissions.values()) {
                        expect.bool(catalogIds.contains(p)).isTrue();
                    };
                };
                expect.nat(team.roles.size()).equal(3);
                expect.nat(team.counter.nextRoleId).equal(4);
            },
        );
    },
);
