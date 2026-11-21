import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import CoreMap "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Set "mo:core/Set";
import Map "mo:map/Map";

import ShopPermissions "../lib/permissions";
import Migration "../migrations/20261115_064951_Permissions";

let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let admin = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let core = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
let ownerAndCore = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");

type Role = { #Owner; #Admin; #Marketplace };

func migrate(entries : [(Principal, [Role])]) : {
    ownership : { var owner : ?Principal };
    marketplacePrincipals : Set.Set<Principal>;
    team : Team;
} {
    let rolesByPrincipal = Map.new<Principal, [Role]>();
    for ((p, roles) in entries.values()) {
        Map.set(rolesByPrincipal, Map.phash, p, roles);
    };
    Migration.migration({ rolesByPrincipal });
};

type Team = {
    roles : CoreMap.Map<Nat, { name : Text; permissions : [Text] }>;
    members : CoreMap.Map<Principal, [Nat]>;
    counter : { var nextRoleId : Nat };
};

suite(
    "Permissions migration",
    func() {
        test(
            "keeps the Owner, gives Admins the Admin role and keeps Marketplace access",
            func() {
                let after = migrate([(owner, [#Owner]), (admin, [#Admin]), (core, [#Marketplace])]);
                expect.bool(after.ownership.owner == ?owner).isTrue();
                expect.bool(after.marketplacePrincipals.contains(core)).isTrue();
                expect.bool(after.marketplacePrincipals.contains(admin)).isFalse();
                expect.bool(after.team.members.get(admin) == ?[1]).isTrue();
                expect.bool(after.team.members.get(owner) == null).isTrue();
                expect.bool(after.team.members.get(core) == null).isTrue();
            },
        );
        test(
            "a principal with Owner and Marketplace keeps both",
            func() {
                let after = migrate([(ownerAndCore, [#Owner, #Marketplace])]);
                expect.bool(after.ownership.owner == ?ownerAndCore).isTrue();
                expect.bool(after.marketplacePrincipals.contains(ownerAndCore)).isTrue();
            },
        );
        test(
            "seeds the presets; Admin holds exactly that version's catalog",
            func() {
                let after = migrate([]);
                expect.bool(after.ownership.owner == null).isTrue();
                let adminRole = after.team.roles.get(1);
                switch (adminRole) {
                    case (?role) {
                        expect.text(role.name).equal("Admin");
                        // Later migrations add the permissions added since (StorefrontTheme: `Storefront.Edit`).
                        let catalogIds = ShopPermissions.catalog.map(func d = d.id).filter(func id = id != ShopPermissions.storefrontEdit and id != ShopPermissions.musicEdit);
                        expect.bool(role.permissions == catalogIds).isTrue();
                    };
                    case null expect.bool(false).isTrue();
                };
                expect.nat(after.team.roles.size()).equal(3);
                expect.nat(after.team.counter.nextRoleId).equal(4);
                // Every preset's permissions are in the catalog.
                for ((_, role) in after.team.roles.entries()) {
                    for (p in role.permissions.values()) {
                        expect.bool(ShopPermissions.catalog.any(func d = d.id == p)).isTrue();
                    };
                };
            },
        );
    },
);
