import { expect } "mo:test";
import { suite; test } "mo:test";

import Principal "mo:core/Principal";

import Permissions "../../../../lib/Permissions";
import AuthService "../auth";
import ShopPermissions "../permissions";
import Fixtures "fixtures";

let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let admin = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let core = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
let stranger = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");

func isUnauthorized(r : { #ok; #err : { #Unauthorized : Text } }) : Bool {
    switch (r) { case (#err(#Unauthorized(_))) true; case (#ok) false };
};

suite(
    "ShopPermissions.catalog",
    func() {
        test(
            "is valid: <Resource>.<Action> ids, includes within their resource, team permissions present",
            func() {
                expect.array<Text>(Permissions.catalogProblems(ShopPermissions.catalog), func t = t, func(a, b) = a == b).size(0);
            },
        );
    },
);

suite(
    "AuthService",
    func() {
        test(
            "the Owner holds every catalog permission",
            func() {
                let authService = Fixtures.newAuthService(owner);
                for (def in ShopPermissions.catalog.values()) {
                    expect.bool(AuthService.hasPermission(authService, owner, def.id)).isTrue();
                };
                expect.bool(AuthService.isOwner(authService, owner)).isTrue();
                expect.bool(AuthService.isOwner(authService, admin)).isFalse();
            },
        );
        test(
            "initOwner sets the Owner only while there is none",
            func() {
                let authService = Fixtures.newAuthService(owner);
                AuthService.initOwner(authService, stranger);
                expect.bool(AuthService.isOwner(authService, owner)).isTrue();
                authService.ownership.owner := null;
                AuthService.initOwner(authService, stranger);
                expect.bool(AuthService.isOwner(authService, stranger)).isTrue();
            },
        );
        test(
            "setOwner hands ownership over and drops the new owner's roles",
            func() {
                let authService = Fixtures.newAuthService(owner);
                Fixtures.grantAdmin(authService, admin);
                expect.bool(isUnauthorized(AuthService.setOwner(authService, admin, admin))).isTrue();
                expect.bool(isUnauthorized(AuthService.setOwner(authService, owner, Principal.anonymous()))).isTrue();
                expect.bool(AuthService.setOwner(authService, owner, admin) == #ok).isTrue();
                expect.bool(AuthService.isOwner(authService, admin)).isTrue();
                expect.bool(AuthService.isOwner(authService, owner)).isFalse();
                expect.bool(AuthService.hasPermission(authService, owner, ShopPermissions.ordersView)).isFalse();
                expect.nat(authService.team.rolesOf(admin).size()).equal(0);
            },
        );
        test(
            "only the Owner grants and revokes Marketplace access, which isn't a permission",
            func() {
                let authService = Fixtures.newAuthService(owner);
                Fixtures.grantAdmin(authService, admin);
                expect.bool(isUnauthorized(AuthService.grantMarketplace(authService, admin, core))).isTrue();
                expect.bool(AuthService.grantMarketplace(authService, owner, core) == #ok).isTrue();
                expect.bool(AuthService.isMarketplace(authService, core)).isTrue();
                expect.bool(AuthService.hasPermission(authService, core, ShopPermissions.ordersView)).isFalse();
                expect.bool(isUnauthorized(AuthService.revokeMarketplace(authService, admin, core))).isTrue();
                expect.bool(AuthService.revokeMarketplace(authService, owner, core) == #ok).isTrue();
                expect.bool(AuthService.isMarketplace(authService, core)).isFalse();
            },
        );
        test(
            "an owner who hands the shop over keeps the roles it was given",
            func() {
                let authService = Fixtures.newAuthService(owner);
                Fixtures.grantAdmin(authService, owner);
                expect.bool(AuthService.setOwner(authService, owner, stranger) == #ok).isTrue();
                expect.bool(AuthService.isOwner(authService, owner)).isFalse();
                expect.bool(AuthService.hasPermission(authService, owner, ShopPermissions.productsEdit)).isTrue();
                // Admin holds team permissions but not the Owner's: moving funds isn't a permission.
                expect.bool(AuthService.hasPermission(authService, stranger, ShopPermissions.productsEdit)).isTrue();
            },
        );
    },
);
