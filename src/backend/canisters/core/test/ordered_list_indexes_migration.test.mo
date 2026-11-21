import { expect } "mo:test";
import { suite; test } "mo:test";
import Array "mo:core/Array";
import CoreSet "mo:core/Set";
import Iter "mo:core/Iter";
import Principal "mo:core/Principal";
import Map "mo:map/Map";

import Migration "../migrations/20261107_083803_OrderedListIndexes";
import OrderAPI "../api/orders";
import ShopAPI "../api/shop";

// The registry item as this migration knew it, before slugs (BRE-71).
type RegistryItem = {
    canisterId : Principal;
    owner : Principal;
    shopDetails : ShopAPI.ShopDetails;
    registeredBy : Principal;
    registrationDate : Int;
};

let shopA = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let shopB = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let alice = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let bob = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");

let zero = {
    currency = { class_ = #FiatCurrency; symbol = "USD" };
    amount = 0 : Nat64;
    metadata = { decimals = 2 : Nat32 };
};

func shop(canisterId : Principal, name : Text) : RegistryItem = {
    canisterId;
    owner = alice;
    shopDetails = {
        name;
        description = "";
        logoUrl = null;
        bannerImageUrl = null;
        physicalLocation = null;
        locationPublic = false;
    };
    registeredBy = alice;
    registrationDate = 0;
};

func order(shopId : Principal, id : Nat32, buyer : Principal, createdAt : Int) : OrderAPI.Order = {
    id;
    shopId;
    buyer;
    items = [];
    totals = {
        subtotal = zero;
        discounts = zero;
        tax = zero;
        shipping = zero;
        total = zero;
    };
    status = #paid;
    createdAt;
};

suite(
    "Migration 20261107_083803_OrderedListIndexes",
    func() {
        test(
            "indexes registered shops by canister ID and by name",
            func() {
                let shopRegistry = Map.new<Principal, RegistryItem>();
                Map.set(shopRegistry, Map.phash, shopA, shop(shopA, "Zebra"));
                Map.set(shopRegistry, Map.phash, shopB, shop(shopB, "Apple"));
                let next = Migration.migration({
                    shopRegistry;
                    orders = Map.new<Text, OrderAPI.Order>();
                    ordersByBuyer = Map.new<Principal, [Text]>();
                });
                let ids = Iter.toArray(CoreSet.values(next.shopIdsOrdered));
                expect.nat(ids.size()).equal(2);
                expect.bool(Principal.compare(ids[0], ids[1]) == #less).isTrue();
                let names = Iter.toArray(CoreSet.values(next.shopsByDisplayName)).map(func(k : ShopAPI.ShopNameKey) : Text = k.name);
                expect.bool(names == ["Apple", "Zebra"]).isTrue();
            },
        );
        test(
            "rebuilds each buyer's orders newest first, dropping keys with no order of theirs",
            func() {
                let orders = Map.new<Text, OrderAPI.Order>();
                Map.set(orders, Map.thash, "a:1", order(shopA, 1, alice, 10));
                Map.set(orders, Map.thash, "a:2", order(shopA, 2, alice, 30));
                Map.set(orders, Map.thash, "b:1", order(shopB, 1, alice, 20));
                Map.set(orders, Map.thash, "b:2", order(shopB, 2, bob, 40));
                let ordersByBuyer = Map.new<Principal, [Text]>();
                Map.set(ordersByBuyer, Map.phash, alice, ["a:1", "a:2", "b:1", "b:2", "missing"]);
                Map.set(ordersByBuyer, Map.phash, bob, ["missing"]);
                let next = Migration.migration({
                    shopRegistry = Map.new<Principal, RegistryItem>();
                    orders;
                    ordersByBuyer;
                });
                let ?aliceOrders = Map.get(next.ordersByBuyer, Map.phash, alice) else return assert false;
                let times = Iter.toArray(CoreSet.values(aliceOrders)).map(func(c : OrderAPI.UserOrderCursor) : Int = c.createdAt);
                expect.bool(times == [30, 20, 10]).isTrue();
                expect.bool(Map.has(next.ordersByBuyer, Map.phash, bob)).isFalse();
                expect.nat(Map.size(next.orders)).equal(4);
            },
        );
    },
);
