import { expect; suite; test } "mo:test";
import Principal "mo:core/Principal";
import CoreMap "mo:core/Map";
import Map "mo:map/Map";

import ShopFees "../../../../../lib/ShopCallFees";
import HandoverAPI "../../handover";
import ShopCanistersAPI "../../shop_canisters";
import ShopCallFeesAPI "../lib";

let hostedShop = Principal.fromText("aaaaa-aa");
let otherShop = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");

func canisters() : ShopCanistersAPI.State {
    {
        wasmVersions = Map.new<Principal, ShopCanistersAPI.InstalledWasm>();
        vaultsByShop = Map.new<Principal, Principal>();
    };
};

suite(
    "ShopCallFees.required",
    func() {
        test(
            "charges nothing while the fees aren't enforced",
            func() {
                let state = ShopCallFeesAPI.newState();
                expect.nat(ShopCallFeesAPI.required(state, false)).equal(0);
            },
        );
        test(
            "charges a shop core doesn't host once enforced",
            func() {
                let state = ShopCallFeesAPI.newState();
                state.enforced := true;
                expect.nat(ShopCallFeesAPI.required(state, false)).equal(ShopFees.EVENT_CYCLES);
            },
        );
        test(
            "never charges a hosted shop",
            func() {
                let state = ShopCallFeesAPI.newState();
                state.enforced := true;
                expect.nat(ShopCallFeesAPI.required(state, true)).equal(0);
            },
        );
    },
);

suite(
    "ShopCallFees.isHosted",
    func() {
        test(
            "a shop with a recorded vault is hosted",
            func() {
                let c = canisters();
                Map.set(c.vaultsByShop, Map.phash, hostedShop, otherShop);
                expect.bool(ShopCallFeesAPI.isHosted(c, HandoverAPI.newState(), hostedShop)).isTrue();
            },
        );
        test(
            "a shop core has no record of (registerShop) is not hosted",
            func() {
                expect.bool(ShopCallFeesAPI.isHosted(canisters(), HandoverAPI.newState(), otherShop)).isFalse();
            },
        );
        test(
            "a shop handed over to its merchant is not hosted",
            func() {
                let c = canisters();
                let handover = HandoverAPI.newState();
                Map.set(c.vaultsByShop, Map.phash, hostedShop, otherShop);
                CoreMap.add(handover.selfManaged, Principal.compare, hostedShop, { controller = otherShop; vaultId = otherShop; since = 0 });
                expect.bool(ShopCallFeesAPI.isHosted(c, handover, hostedShop)).isFalse();
            },
        );
    },
);
