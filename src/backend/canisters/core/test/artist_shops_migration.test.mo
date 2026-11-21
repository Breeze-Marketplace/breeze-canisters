import { expect; suite; test } "mo:test";
import Iter "mo:core/Iter";
import Principal "mo:core/Principal";
import Set "mo:core/Set";
import Map "mo:map/Map";

import Migration "../migrations/20261120_192844_ArtistShops";
import ShopAPI "../api/shop";

let gus = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
let shop = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");

func item(canisterId : Principal, presentation : { #storefront; #artist }) : ShopAPI.ShopRegistryItem = {
    canisterId;
    slug = "s";
    owner = canisterId;
    shopDetails = {
        name = "S";
        description = "";
        logoUrl = null;
        bannerImageUrl = null;
        physicalLocation = null;
        locationPublic = false;
    };
    registeredBy = canisterId;
    registrationDate = 0;
    presentation;
};

suite(
    "ArtistShops migration (BRE-201)",
    func() {
        test(
            "indexes the shops already shown as artist pages, keeps the registry, and hides none",
            func() {
                let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                Map.set(registry, Map.phash, gus, item(gus, #artist));
                Map.set(registry, Map.phash, shop, item(shop, #storefront));
                let next = Migration.migration({ shopRegistry = registry });
                expect.nat(Map.size(next.shopRegistry)).equal(2);
                assert Iter.toArray(Set.values(next.artistShops)) == [gus];
                expect.nat(Set.size(next.hiddenShops)).equal(0);
                assert not next.hiddenShopsCopy.complete;
            },
        );
    },
);
