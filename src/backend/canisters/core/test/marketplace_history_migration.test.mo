import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Set "mo:core/Set";
import Text "mo:core/Text";

import Migration "../migrations/20261116_085855_MarketplaceHistory";

type TeamRole = { name : Text; permissions : [Text] };

func team(roles : [(Nat, TeamRole)]) : {
    roles : Map.Map<Nat, TeamRole>;
    members : Map.Map<Principal, [Nat]>;
    counter : { var nextRoleId : Nat };
} {
    let map = Map.empty<Nat, TeamRole>();
    for ((id, role) in roles.values()) map.add(id, role);
    { roles = map; members = Map.empty(); counter = { var nextRoleId = 4 } };
};

func permissionsOf(t : { roles : Map.Map<Nat, TeamRole> }, id : Nat) : [Text] {
    switch (t.roles.get(id)) {
        case (?role) role.permissions;
        case null [];
    };
};

suite(
    "Marketplace history migration",
    func() {
        test(
            "starts an empty history",
            func() {
                let upgraded = Migration.migration({ team = team([]) });
                expect.nat(upgraded.marketplaceHistory.nextSeq).equal(0);
                expect.nat(Map.size(upgraded.marketplaceHistory.events)).equal(0);
                expect.nat(Set.size(upgraded.marketplaceHistory.bySubject)).equal(0);
            },
        );

        test(
            "gives the Admin preset History.View once",
            func() {
                let upgraded = Migration.migration({
                    team = team([(1, { name = "Admin"; permissions = ["Shops.View"] })]);
                });
                expect.array<Text>(permissionsOf(upgraded.team, 1), func t = t, func(a, b) = a == b).equal(["Shops.View", "History.View"]);
                let again = Migration.migration({ team = upgraded.team });
                expect.nat(permissionsOf(again.team, 1).size()).equal(2);
            },
        );

        test(
            "leaves a renamed role 1 and every other role alone",
            func() {
                let upgraded = Migration.migration({
                    team = team([
                        (1, { name = "Support"; permissions = ["Shops.View"] }),
                        (2, { name = "Moderator"; permissions = ["Moderation.HideProducts"] }),
                    ]);
                });
                expect.array<Text>(permissionsOf(upgraded.team, 1), func t = t, func(a, b) = a == b).equal(["Shops.View"]);
                expect.array<Text>(permissionsOf(upgraded.team, 2), func t = t, func(a, b) = a == b).equal(["Moderation.HideProducts"]);
            },
        );
    },
);
