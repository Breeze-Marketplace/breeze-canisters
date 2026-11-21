import { expect } "mo:test";
import { suite; test } "mo:test/async";
import Principal "mo:core/Principal";
import Map "mo:map/Map";

import ShopAPI "../lib";
import Fixtures "./fixtures";

let owner = Principal.fromText("aaaaa-aa"); // the fixtures' owner
let stranger = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let shopA = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let shopB = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let shopC = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");

func apiWith(shops : [(Principal, Text)]) : ShopAPI.API {
    let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
    for ((id, name) in shops.values()) {
        Map.set(registry, Map.phash, id, Fixtures.shopRegistryItem(id, name, "", null, null, false));
    };
    ShopAPI.API(Fixtures.makeDependencies(?registry));
};

func resolvesTo(api : ShopAPI.API, slug : Text) : ?(Principal, Text) {
    switch (ShopAPI.resolveSlug(api, slug)) {
        case (?r) { ?(r.canisterId, r.canonicalSlug) };
        case null { null };
    };
};

await suite(
    "Shop slugs",
    func() : async () {
        await test(
            "resolves a current slug, in any case",
            func() : async () {
                let api = apiWith([(shopA, "Blue Heron")]);
                expect.bool(resolvesTo(api, "blue-heron") == ?(shopA, "blue-heron")).isTrue();
                expect.bool(resolvesTo(api, "Blue-Heron") == ?(shopA, "blue-heron")).isTrue();
                expect.bool(resolvesTo(api, "nope") == null).isTrue();
            },
        );

        await test(
            "the owner changes the slug, and the old one redirects to the new",
            func() : async () {
                let api = apiWith([(shopA, "Blue Heron")]);
                expect.bool(ShopAPI.setShopSlug(api, owner, shopA, "heron-books") == #ok("heron-books")).isTrue();
                expect.bool(resolvesTo(api, "heron-books") == ?(shopA, "heron-books")).isTrue();
                expect.bool(resolvesTo(api, "blue-heron") == ?(shopA, "heron-books")).isTrue();
                let ?item = Map.get(api.shopRegistry, Map.phash, shopA) else return assert false;
                expect.text(item.slug).equal("heron-books");
            },
        );

        await test(
            "only the owner can change it, with a valid slug",
            func() : async () {
                let api = apiWith([(shopA, "Blue Heron")]);
                expect.bool(ShopAPI.setShopSlug(api, stranger, shopA, "mine-now") == #err(#Unauthorized)).isTrue();
                expect.bool(ShopAPI.setShopSlug(api, Principal.anonymous(), shopA, "mine-now") == #err(#Unauthorized)).isTrue();
                expect.bool(ShopAPI.setShopSlug(api, owner, shopB, "mine-now") == #err(#NotFound)).isTrue();
                switch (ShopAPI.setShopSlug(api, owner, shopA, "Not Valid")) {
                    case (#err(#InvalidSlug(_))) {};
                    case _ { assert false };
                };
                switch (ShopAPI.setShopSlug(api, owner, shopA, Principal.toText(shopB))) {
                    case (#err(#InvalidSlug(_))) {};
                    case _ { assert false };
                };
            },
        );

        await test(
            "a shop's current or old slug is never given to another shop",
            func() : async () {
                let api = apiWith([(shopA, "Blue Heron"), (shopB, "Owl")]);
                expect.bool(ShopAPI.setShopSlug(api, owner, shopB, "blue-heron") == #err(#SlugTaken)).isTrue();
                ignore ShopAPI.setShopSlug(api, owner, shopA, "heron-books");
                // blue-heron is shopA's old slug now: still not free for shopB.
                expect.bool(ShopAPI.setShopSlug(api, owner, shopB, "blue-heron") == #err(#SlugTaken)).isTrue();
                // shopA can go back to it.
                expect.bool(ShopAPI.setShopSlug(api, owner, shopA, "blue-heron") == #ok("blue-heron")).isTrue();
                expect.bool(resolvesTo(api, "heron-books") == ?(shopA, "blue-heron")).isTrue();
            },
        );

        await test(
            "a slug an open quote holds isn't free",
            func() : async () {
                let deps = Fixtures.makeDependencies(null);
                let api = ShopAPI.API({
                    deps with slugReservedByQuote = func(s : Text) : Bool = s == "held"
                });
                expect.bool(ShopAPI.slugAvailable(api, "held", null)).isFalse();
                expect.bool(ShopAPI.slugAvailable(api, "free", null)).isTrue();
            },
        );

        await test(
            "caps the slugs one shop can hold",
            func() : async () {
                let api = apiWith([(shopA, "Blue Heron")]);
                var n = 1;
                while (n < ShopAPI.MAX_SLUGS_PER_SHOP) {
                    expect.bool(ShopAPI.setShopSlug(api, owner, shopA, "heron-" # debug_show (n)) == #ok("heron-" # debug_show (n))).isTrue();
                    n += 1;
                };
                expect.bool(ShopAPI.setShopSlug(api, owner, shopA, "one-too-many") == #err(#TooManySlugs)).isTrue();
                // Going back to an earlier one still works.
                expect.bool(ShopAPI.setShopSlug(api, owner, shopA, "blue-heron") == #ok("blue-heron")).isTrue();
            },
        );

        await test(
            "registerShop derives a free slug, with a suffix on a clash",
            func() : async () {
                let api = apiWith([(shopA, "Test Shop")]);
                // The fixtures' hooks report the name "Test Shop", but names must be unique too, so
                // rename shopA first; its slug stays test-shop.
                ShopAPI.syncShopDetails(api, shopA, Fixtures.shopDetailsUpdatedEvent("Renamed", ""));
                let res = await ShopAPI.registerShop(api, owner, { canisterId = shopB }, func _ = true, Fixtures.defaultRegisterShopHooks([owner]));
                expect.bool(res == #ok).isTrue();
                let ?item = Map.get(api.shopRegistry, Map.phash, shopB) else return assert false;
                expect.text(item.slug).equal("test-shop-2");
                expect.bool(resolvesTo(api, "test-shop") == ?(shopA, "test-shop")).isTrue();
            },
        );

        await test(
            "an unregistered shop's slugs aren't reused, and come back if it registers again",
            func() : async () {
                let api = apiWith([(shopA, "Test Shop")]);
                ignore ShopAPI.setShopSlug(api, owner, shopA, "my-books");
                expect.bool(ShopAPI.unregisterShop(api, shopA) == #ok).isTrue();
                expect.bool(resolvesTo(api, "my-books") == null).isTrue();
                expect.bool(ShopAPI.slugAvailable(api, "my-books", ?shopC)).isFalse();
                expect.bool(ShopAPI.slugAvailable(api, "test-shop", ?shopC)).isFalse();
                ignore await ShopAPI.registerShop(api, owner, { canisterId = shopA }, func _ = true, Fixtures.defaultRegisterShopHooks([owner]));
                let ?item = Map.get(api.shopRegistry, Map.phash, shopA) else return assert false;
                expect.text(item.slug).equal("my-books");
            },
        );

        await test(
            "listShops, getUserShops and getSlugs carry the slug",
            func() : async () {
                let api = apiWith([(shopA, "Blue Heron"), (shopB, "Owl Shop")]);
                let page = ShopAPI.listShops(api, null, null);
                for (s in page.items.values()) {
                    expect.bool(s.slug == "blue-heron" or s.slug == "owl-shop").isTrue();
                };
                let slugs = ShopAPI.getSlugs(api, [shopB, shopC, shopA]);
                expect.bool(slugs == [{ canisterId = shopB; slug = "owl-shop" }, { canisterId = shopA; slug = "blue-heron" }]).isTrue();
                let mine = ShopAPI.getUserShops(api, owner);
                expect.nat(mine.size()).equal(1);
                expect.bool(mine[0].slug == "blue-heron" or mine[0].slug == "owl-shop").isTrue();
            },
        );
    },
);
