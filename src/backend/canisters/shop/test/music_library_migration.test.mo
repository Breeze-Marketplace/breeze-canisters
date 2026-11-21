import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import CoreMap "mo:core/Map";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Set "mo:core/Set";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Map "mo:map/Map";

import ShopPermissions "../lib/permissions";
import PermissionsMigration "../migrations/20261115_064951_Permissions";
import ThemeMigration "../migrations/20261117_034407_StorefrontTheme";
import Migration "../migrations/20261120_021809_MusicLibrary";

let admin = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");

type Role = { #Owner; #Admin; #Marketplace };
type Team = {
    roles : CoreMap.Map<Nat, { name : Text; permissions : [Text] }>;
    members : CoreMap.Map<Principal, [Nat]>;
    counter : { var nextRoleId : Nat };
};

/// A team as the earlier migrations leave it: seeded presets, Admin with `Storefront.Edit`.
func seededTeam() : Team {
    let rolesByPrincipal = Map.new<Principal, [Role]>();
    Map.set(rolesByPrincipal, Map.phash, admin, [#Admin]);
    ThemeMigration.migration({
        team = PermissionsMigration.migration({ rolesByPrincipal }).team;
    }).team;
};

func permissionsOf(team : Team, id : Nat) : [Text] {
    switch (team.roles.get(id)) {
        case (?role) role.permissions;
        case null [];
    };
};

func has(team : Team, id : Nat, permission : Text) : Bool {
    permissionsOf(team, id).any(func(p : Text) : Bool = p == permission);
};

let usd = { class_ = #FiatCurrency; symbol = "USD" };

func oldVariant(id : Nat32) : {
    id : Nat32;
    productId : Nat32;
    name : Text;
    sku : Text;
    price : {
        catalog : [{
            amount : Nat64;
            currency : {
                class_ : { #Cryptocurrency; #FiatCurrency };
                symbol : Text;
            };
            metadata : { decimals : Nat32 };
        }];
    };
    status : { #Draft; #Active; #Inactive; #Archived };
    attributes : [{ key : Text; value : Text }];
    imageUrls : [Text];
} {
    {
        id;
        productId = 1;
        name = "Default";
        sku = "SKU-" # id.toText();
        price = {
            catalog = [{
                amount = 500;
                currency = usd;
                metadata = { decimals = 2 };
            }];
        };
        status = #Active;
        attributes = [];
        imageUrls = ["/images/a.png"];
    };
};

func oldState() : {
    team : Team;
    products : Map.Map<Nat32, { id : Nat32; title : Text; description : Text; status : { #Draft; #Active; #Inactive; #Archived }; productType : { #Physical; #Digital; #Service }; tags : [Text]; category : ?Text; variants : [{ id : Nat32; productId : Nat32; name : Text; sku : Text; price : { catalog : [{ amount : Nat64; currency : { class_ : { #Cryptocurrency; #FiatCurrency }; symbol : Text }; metadata : { decimals : Nat32 } }] }; status : { #Draft; #Active; #Inactive; #Archived }; attributes : [{ key : Text; value : Text }]; imageUrls : [Text] }]; createdAt : Int }>;
    productVariants : Map.Map<Nat32, { id : Nat32; productId : Nat32; name : Text; sku : Text; price : { catalog : [{ amount : Nat64; currency : { class_ : { #Cryptocurrency; #FiatCurrency }; symbol : Text }; metadata : { decimals : Nat32 } }] }; status : { #Draft; #Active; #Inactive; #Archived }; attributes : [{ key : Text; value : Text }]; imageUrls : [Text] }>;
} {
    let products = Map.new<Nat32, { id : Nat32; title : Text; description : Text; status : { #Draft; #Active; #Inactive; #Archived }; productType : { #Physical; #Digital; #Service }; tags : [Text]; category : ?Text; variants : [{ id : Nat32; productId : Nat32; name : Text; sku : Text; price : { catalog : [{ amount : Nat64; currency : { class_ : { #Cryptocurrency; #FiatCurrency }; symbol : Text }; metadata : { decimals : Nat32 } }] }; status : { #Draft; #Active; #Inactive; #Archived }; attributes : [{ key : Text; value : Text }]; imageUrls : [Text] }]; createdAt : Int }>();
    let productVariants = Map.new<Nat32, { id : Nat32; productId : Nat32; name : Text; sku : Text; price : { catalog : [{ amount : Nat64; currency : { class_ : { #Cryptocurrency; #FiatCurrency }; symbol : Text }; metadata : { decimals : Nat32 } }] }; status : { #Draft; #Active; #Inactive; #Archived }; attributes : [{ key : Text; value : Text }]; imageUrls : [Text] }>();
    let variants = [oldVariant(1), oldVariant(2)];
    Map.set(products, Map.n32hash, 1 : Nat32, { id = 1 : Nat32; title = "Tee"; description = ""; status = #Active; productType = #Physical; tags = []; category = null; variants; createdAt = 0 });
    for (v in variants.values()) Map.set(productVariants, Map.n32hash, v.id, v);
    { team = seededTeam(); products; productVariants };
};

suite(
    "MusicLibrary migration",
    func() {
        test(
            "gives every variant no deliverable and fixed pricing, in both maps",
            func() {
                let after = Migration.migration(oldState());
                expect.nat(Map.size(after.productVariants)).equal(2);
                for (v in Map.vals(after.productVariants)) {
                    expect.bool(v.deliverable == null and v.pricing == ?#fixed).isTrue();
                };
                switch (Map.get(after.products, Map.n32hash, 1 : Nat32)) {
                    case (?p) {
                        expect.nat(p.variants.size()).equal(2);
                        for (v in p.variants.values()) expect.bool(v.deliverable == null and v.pricing == ?#fixed).isTrue();
                        expect.text(p.variants[0].sku).equal("SKU-1");
                    };
                    case null expect.bool(false).isTrue();
                };
            },
        );
        test(
            "starts an empty library",
            func() {
                let after = Migration.migration(oldState());
                expect.nat(after.music.tracks.size()).equal(0);
                expect.nat(after.music.releases.size()).equal(0);
                expect.nat(after.music.soldReleases.size()).equal(0);
                expect.bool(after.music.nextTrackId == 1 and after.music.nextReleaseId == 1).isTrue();
            },
        );
        test(
            "the untouched Admin preset holds exactly this version's catalog",
            func() {
                let after = Migration.migration(oldState());
                let catalogIds = ShopPermissions.catalog.map(func d = d.id).sort(Text.compare);
                expect.bool(permissionsOf(after.team, 1).sort(Text.compare) == catalogIds).isTrue();
                expect.bool(after.team.members.get(admin) == ?[1]).isTrue();
            },
        );
        test(
            "the untouched Catalog manager preset gains Music.Edit; Fulfillment doesn't",
            func() {
                let after = Migration.migration(oldState());
                expect.bool(has(after.team, 2, ShopPermissions.musicEdit)).isTrue();
                expect.bool(has(after.team, 3, ShopPermissions.musicEdit)).isFalse();
            },
        );
        test(
            "trimmed or renamed presets don't gain it, and running twice adds it once",
            func() {
                let state = oldState();
                state.team.roles.add(1, { name = "Admin"; permissions = ["Orders.View"] });
                state.team.roles.add(2, { name = "Merch"; permissions = permissionsOf(state.team, 2) });
                let after = Migration.migration(state);
                expect.bool(has(after.team, 1, ShopPermissions.musicEdit)).isFalse();
                expect.bool(has(after.team, 2, ShopPermissions.musicEdit)).isFalse();

                let once = Migration.migration(oldState());
                let twice = Migration.migration({
                    once with products = Map.new();
                    productVariants = Map.new();
                });
                expect.nat(permissionsOf(twice.team, 1).size()).equal(ShopPermissions.catalog.size());
                expect.nat(permissionsOf(twice.team, 2).filter(func(p : Text) : Bool = p == ShopPermissions.musicEdit).size()).equal(1);
            },
        );
        test(
            "a shop without presets migrates unchanged",
            func() {
                let state = oldState();
                state.team.roles.remove(1);
                state.team.roles.remove(2);
                let after = Migration.migration(state);
                expect.bool(after.team.roles.get(1) == null and after.team.roles.get(2) == null).isTrue();
            },
        );
    },
);
