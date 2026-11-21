import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Map "mo:map/Map";

import ShopAPI "../../shop";
import Fixtures "./fixtures";

// Listing artist pages for the marketplace's Music page (BRE-201).

let gus = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
let ida = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let kit = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let shop = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");

func item(canisterId : Principal, name : Text, presentation : { #storefront; #artist }) : ShopAPI.ShopRegistryItem {
    {
        Fixtures.shopRegistryItem(canisterId, name, "", ?("https://example.com/" # name # ".png"), null, false) with presentation;
    };
};

func apiWith(items : [ShopAPI.ShopRegistryItem]) : ShopAPI.API {
    let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
    for (i in items.values()) Map.set(registry, Map.phash, i.canisterId, i);
    ShopAPI.API(Fixtures.makeDependencies(?registry));
};

func names(page : { items : [ShopAPI.ArtistShopInfo] }) : [Text] {
    page.items.map(func(a : ShopAPI.ArtistShopInfo) : Text = a.name);
};

func byId(ids : [Principal]) : [Principal] = ids.sort(Principal.compare);

suite(
    "listArtistShops",
    func() {
        test(
            "lists only shops shown as artist pages, in canister ID order, with what anyone may see",
            func() {
                let api = apiWith([item(gus, "Gus", #artist), item(shop, "Shop", #storefront), item(ida, "Ida", #artist)]);
                let page = ShopAPI.listArtistShops(api, null, null);
                expect.array(page.items.map(func(a : ShopAPI.ArtistShopInfo) : Principal = a.canisterId), Principal.toText, Principal.equal).equal(byId([gus, ida]));
                assert page.next == null;
                let first = page.items[0];
                expect.text(first.slug).equal(Text.toLower(first.name));
                assert first.logoUrl == ?("https://example.com/" # first.name # ".png");
            },
        );

        test(
            "pages from the cursor",
            func() {
                let api = apiWith([item(gus, "Gus", #artist), item(ida, "Ida", #artist), item(kit, "Kit", #artist)]);
                let ordered = byId([gus, ida, kit]);
                let first = ShopAPI.listArtistShops(api, null, ?2);
                expect.nat(first.items.size()).equal(2);
                assert first.next == ?ordered[1];
                let second = ShopAPI.listArtistShops(api, first.next, ?2);
                expect.nat(second.items.size()).equal(1);
                assert second.items[0].canisterId == ordered[2];
                assert second.next == null;
            },
        );

        test(
            "follows the presentation a shop's events set, and drops unregistered shops",
            func() {
                let api = apiWith([item(gus, "Gus", #storefront)]);
                expect.nat(ShopAPI.listArtistShops(api, null, null).items.size()).equal(0);

                ShopAPI.syncShopDetails(api, gus, Fixtures.shopDetailsEventWithPresentation("Gus", "Songs", ?#artist));
                expect.array(names(ShopAPI.listArtistShops(api, null, null)), func t = t, Text.equal).equal(["Gus"]);

                // An event from a shop older than BRE-197 keeps the presentation core knows.
                ShopAPI.syncShopDetails(api, gus, Fixtures.shopDetailsUpdatedEvent("Gus Live", "Songs"));
                expect.array(names(ShopAPI.listArtistShops(api, null, null)), func t = t, Text.equal).equal(["Gus Live"]);

                ShopAPI.syncShopDetails(api, gus, Fixtures.shopDetailsEventWithPresentation("Gus Live", "Songs", ?#storefront));
                expect.nat(ShopAPI.listArtistShops(api, null, null).items.size()).equal(0);

                ShopAPI.syncShopDetails(api, gus, Fixtures.shopDetailsEventWithPresentation("Gus Live", "Songs", ?#artist));
                assert ShopAPI.unregisterShop(api, gus) == #ok;
                expect.nat(ShopAPI.listArtistShops(api, null, null).items.size()).equal(0);
            },
        );

        test(
            "leaves out shops trust_safety hid until it shows them again, even ones hidden before registering",
            func() {
                let api = apiWith([item(gus, "Gus", #artist), item(ida, "Ida", #artist)]);
                ShopAPI.setShopVisibility(api, gus, #hidden);
                ShopAPI.setShopVisibility(api, kit, #hidden);
                expect.array(names(ShopAPI.listArtistShops(api, null, null)), func t = t, Text.equal).equal(["Ida"]);

                ShopAPI.putShopRegistryAndIndexes(api, item(kit, "Kit", #artist), "kit");
                expect.array(names(ShopAPI.listArtistShops(api, null, null)), func t = t, Text.equal).equal(["Ida"]);

                ShopAPI.setShopVisibility(api, gus, #visible);
                let shown = names(ShopAPI.listArtistShops(api, null, null)).sort(Text.compare);
                expect.array(shown, func t = t, Text.equal).equal(["Gus", "Ida"]);
            },
        );

        test(
            "a page of hidden shops comes back short with a next cursor, and paging on reaches the rest",
            func() {
                let items = Array.tabulate<ShopAPI.ShopRegistryItem>(
                    1_003,
                    func i = item(Principal.fromBlob(Blob.fromArray([Nat8.fromNat(i / 256), Nat8.fromNat(i % 256), 7])), "Artist" # Nat.toText(i), #artist),
                );
                let api = apiWith(items);
                let ordered = byId(items.map(func(i : ShopAPI.ShopRegistryItem) : Principal = i.canisterId));
                for (i in Nat.range(0, 1_001)) ShopAPI.setShopVisibility(api, ordered[i], #hidden);

                let first = ShopAPI.listArtistShops(api, null, ?1);
                expect.nat(first.items.size()).equal(0);
                assert first.next != null;
                let second = ShopAPI.listArtistShops(api, first.next, ?1);
                expect.nat(second.items.size()).equal(1);
                assert second.items[0].canisterId == ordered[1_001];
            },
        );

        test(
            "lists no one until core has copied product_index's hidden shops once",
            func() {
                let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                Map.set(registry, Map.phash, gus, item(gus, "Gus", #artist));
                Map.set(registry, Map.phash, ida, item(ida, "Ida", #artist));
                let api = ShopAPI.API({ Fixtures.makeDependencies(?registry) with hiddenShopsCopy = { var complete = false } });
                expect.nat(ShopAPI.listArtistShops(api, null, null).items.size()).equal(0);

                ShopAPI.startHiddenShopsCopy(api);
                expect.nat(ShopAPI.copyHiddenShops(api, [gus], ShopAPI.visibilityMark(api))).equal(1);
                ShopAPI.finishHiddenShopsCopy(api);
                expect.array(names(ShopAPI.listArtistShops(api, null, null)), func t = t, Text.equal).equal(["Ida"]);
            },
        );
    },
);

suite(
    "copyHiddenShops",
    func() {
        test(
            "skips a shop trust_safety showed while the page was in flight, and hides the rest",
            func() {
                let api = apiWith([item(gus, "Gus", #artist), item(ida, "Ida", #artist), item(kit, "Kit", #artist)]);
                ShopAPI.setShopVisibility(api, kit, #visible);
                ShopAPI.startHiddenShopsCopy(api);
                let mark = ShopAPI.visibilityMark(api);
                // While the page is in flight, a moderator shows Gus in both canisters.
                ShopAPI.setShopVisibility(api, gus, #visible);
                expect.nat(ShopAPI.copyHiddenShops(api, [gus, ida, kit], mark)).equal(2);
                let shown = names(ShopAPI.listArtistShops(api, null, null));
                expect.array(shown, func t = t, Text.equal).equal(["Gus"]);
            },
        );

        test(
            "a decision before the copy started doesn't shield a shop the page lists as hidden",
            func() {
                let api = apiWith([item(gus, "Gus", #artist)]);
                ShopAPI.setShopVisibility(api, gus, #visible);
                ShopAPI.startHiddenShopsCopy(api);
                expect.nat(ShopAPI.copyHiddenShops(api, [gus], ShopAPI.visibilityMark(api))).equal(1);
                expect.nat(ShopAPI.listArtistShops(api, null, null).items.size()).equal(0);
            },
        );
    },
);
