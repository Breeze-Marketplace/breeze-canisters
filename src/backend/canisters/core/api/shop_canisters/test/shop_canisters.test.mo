import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Array "mo:core/Array";
import Error "mo:core/Error";
import Principal "mo:core/Principal";

import CoreSet "mo:core/Set";
import Map "mo:map/Map";

import HandoverAPI "../../handover";
import ShopAPI "../../shop";
import ShopCanistersAPI "../lib";

let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let shopA = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let shopB = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let vaultA = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");

func v(version : Nat) : ShopCanistersAPI.InstalledWasm {
    { version; sha256 = null };
};

func managed(_ : Principal) : HandoverAPI.ControlStatus = #Managed;

func newState() : ShopCanistersAPI.State {
    {
        wasmVersions = Map.new<Principal, ShopCanistersAPI.InstalledWasm>();
        vaultsByShop = Map.new<Principal, Principal>();
    };
};

func registryWith(shops : [(Principal, Text)]) : Map.Map<Principal, ShopAPI.ShopRegistryItem> {
    let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
    for ((canisterId, name) in shops.vals()) {
        Map.set(
            registry,
            Map.phash,
            canisterId,
            {
                canisterId;
                slug = "shop-" # Principal.toText(canisterId);
                owner;
                registeredBy = owner;
                registrationDate = 0;
                presentation = #storefront;
                shopDetails = {
                    name;
                    description = "";
                    logoUrl = null;
                    bannerImageUrl = null;
                    physicalLocation = null;
                    locationPublic = false;
                };
            },
        );
    };
    registry;
};

/// Every row of the admin registry for `shops`, read a page at a time.
func list(state : ShopCanistersAPI.State, shops : [(Principal, Text)]) : [ShopCanistersAPI.AdminShopInfo] {
    let byName = CoreSet.empty<ShopAPI.ShopNameKey>();
    for ((canisterId, name) in shops.values()) {
        CoreSet.add(byName, ShopAPI.compareShopNameKey, { name; canisterId });
    };
    ShopCanistersAPI.page(state, registryWith(shops), byName, managed, null, null).items;
};

suite(
    "ShopCanistersAPI",
    func() : async () {
        let registrant = Principal.fromText("aaaaa-aa");
        func hooks(vault : ?Principal, controllers : [Principal]) : ShopCanistersAPI.LinkRegisteredVaultHooks = {
            getMediaCanisterId = func(_ : Principal) : async ?Principal { vault };
            getControllers = func(_ : Principal) : async [Principal] { controllers };
        };

        await test(
            "lists every registered shop sorted by name",
            func() : async () {
                let rows = list(newState(), [(shopA, "Zebra"), (shopB, "Apple")]);
                expect.bool(Array.map<ShopCanistersAPI.AdminShopInfo, Text>(rows, func(r) = r.name) == ["Apple", "Zebra"]).isTrue();
                expect.principal(rows[0].owner).equal(owner);
            },
        );

        await test(
            "shops with nothing recorded have no vault and unknown versions",
            func() : async () {
                let rows = list(newState(), [(shopA, "A")]);
                expect.bool(rows[0].vaultId == null).isTrue();
                expect.bool(rows[0].shopVersion == null).isTrue();
                expect.bool(rows[0].vaultVersion == null).isTrue();
            },
        );

        await test(
            "reports the recorded vault and the versions of the shop and its vault",
            func() : async () {
                let state = newState();
                ShopCanistersAPI.recordInstall(state, vaultA, v(1));
                ShopCanistersAPI.recordInstall(state, shopA, v(4));
                ShopCanistersAPI.linkVault(state, shopA, vaultA);
                let rows = list(state, [(shopA, "A")]);
                expect.bool(rows[0].vaultId == ?vaultA).isTrue();
                expect.bool(rows[0].shopVersion == ?v(4)).isTrue();
                expect.bool(rows[0].vaultVersion == ?v(1)).isTrue();
            },
        );

        await test(
            "a later install replaces the recorded version",
            func() : async () {
                let state = newState();
                ShopCanistersAPI.recordInstall(state, shopA, v(4));
                ShopCanistersAPI.recordInstall(state, shopA, v(5));
                expect.bool(ShopCanistersAPI.wasmVersion(state, shopA) == ?v(5)).isTrue();
                expect.bool(ShopCanistersAPI.wasmVersion(state, shopB) == null).isTrue();
            },
        );

        await test(
            "unregistered shops are not listed even when their versions are recorded",
            func() : async () {
                let state = newState();
                ShopCanistersAPI.recordInstall(state, shopB, v(4));
                let rows = list(state, [(shopA, "A")]);
                expect.nat(rows.size()).equal(1);
                expect.principal(rows[0].canisterId).equal(shopA);
            },
        );

        await test(
            "linkShopVault records the vault a shop reports",
            func() : async () {
                let state = newState();
                ShopCanistersAPI.recordInstall(state, vaultA, v(2));
                let res = await ShopCanistersAPI.linkShopVault(state, registryWith([(shopA, "A")]), shopA, func(_ : Principal) : async ?Principal { ?vaultA });
                expect.bool(res == #ok(?vaultA)).isTrue();
                let rows = list(state, [(shopA, "A")]);
                expect.bool(rows[0].vaultId == ?vaultA).isTrue();
                expect.bool(rows[0].vaultVersion == ?v(2)).isTrue();
            },
        );

        await test(
            "linkShopVault returns a recorded vault without asking the shop",
            func() : async () {
                let state = newState();
                ShopCanistersAPI.linkVault(state, shopA, vaultA);
                let res = await ShopCanistersAPI.linkShopVault(state, registryWith([(shopA, "A")]), shopA, func(_ : Principal) : async ?Principal { ?shopB });
                expect.bool(res == #ok(?vaultA)).isTrue();
            },
        );

        await test(
            "linkShopVault leaves a shop without a vault unlinked",
            func() : async () {
                let state = newState();
                let res = await ShopCanistersAPI.linkShopVault(state, registryWith([(shopA, "A")]), shopA, func(_ : Principal) : async ?Principal { null });
                expect.bool(res == #ok(null)).isTrue();
                expect.bool(list(state, [(shopA, "A")])[0].vaultId == null).isTrue();
            },
        );

        await test(
            "linkRegisteredShopVault records a vault the owner controls",
            func() : async () {
                let state = newState();
                expect.bool(await ShopCanistersAPI.linkRegisteredShopVault(state, shopA, registrant, hooks(?vaultA, [registrant]))).isTrue();
                expect.bool(list(state, [(shopA, "A")])[0].vaultId == ?vaultA).isTrue();
            },
        );

        await test(
            "linkRegisteredShopVault ignores a vault the owner doesn't control",
            func() : async () {
                let state = newState();
                expect.bool(await ShopCanistersAPI.linkRegisteredShopVault(state, shopA, registrant, hooks(?vaultA, [shopB]))).isFalse();
                expect.bool(list(state, [(shopA, "A")])[0].vaultId == null).isTrue();
            },
        );

        await test(
            "linkRegisteredShopVault ignores another shop's vault",
            func() : async () {
                let state = newState();
                ShopCanistersAPI.linkVault(state, shopB, vaultA);
                expect.bool(await ShopCanistersAPI.linkRegisteredShopVault(state, shopA, registrant, hooks(?vaultA, [registrant]))).isFalse();
                expect.bool(list(state, [(shopA, "A")])[0].vaultId == null).isTrue();
            },
        );

        await test(
            "linkRegisteredShopVault leaves the shop unlinked when it has no vault or the controllers can't be read",
            func() : async () {
                let state = newState();
                expect.bool(await ShopCanistersAPI.linkRegisteredShopVault(state, shopA, registrant, hooks(null, [registrant]))).isFalse();
                let failing = {
                    getMediaCanisterId = func(_ : Principal) : async ?Principal { ?vaultA };
                    getControllers = func(_ : Principal) : async [Principal] { throw Error.reject("no access") };
                };
                expect.bool(await ShopCanistersAPI.linkRegisteredShopVault(state, shopA, registrant, failing)).isFalse();
                expect.bool(list(state, [(shopA, "A")])[0].vaultId == null).isTrue();
            },
        );

        await test(
            "linkShopVault rejects shops that aren't registered",
            func() : async () {
                let res = await ShopCanistersAPI.linkShopVault(newState(), registryWith([]), shopA, func(_ : Principal) : async ?Principal { ?vaultA });
                expect.bool(res == #err(#NotFound)).isTrue();
            },
        );
    },
);
