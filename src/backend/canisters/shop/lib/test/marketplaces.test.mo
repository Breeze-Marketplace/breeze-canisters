import { expect; suite; test } "mo:test";

import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";

import Marketplaces "../marketplaces";

let core = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
let other = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");
let frontend = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");

suite(
    "Marketplaces.record",
    func() {
        test(
            "stores the backend, frontend and name core reports",
            func() {
                let store : Marketplaces.Store = Map.empty();
                let result = Marketplaces.record(store, core, { backendCanisterId = core; frontendCanisterId = ?frontend; name = "  Breeze Marketplace " }, owner, 7);
                expect.bool(result == #ok({ backendCanisterId = core; frontendCanisterId = ?frontend; name = "Breeze Marketplace"; recognizedAt = 7; recognizedBy = owner })).isTrue();
                expect.nat(Marketplaces.list(store).size()).equal(1);
            },
        );
        test(
            "refuses an answer that describes another canister",
            func() {
                let store : Marketplaces.Store = Map.empty();
                let result = Marketplaces.record(store, core, { backendCanisterId = other; frontendCanisterId = null; name = "Fake" }, owner, 7);
                expect.bool(switch result { case (#err(#MarketplaceUnreachable(_))) true; case _ false }).isTrue();
                expect.nat(Marketplaces.list(store).size()).equal(0);
            },
        );
        test(
            "cuts a long name and refreshes on a second recognition",
            func() {
                let store : Marketplaces.Store = Map.empty();
                var long = "";
                for (_ in Nat.range(0, 150)) { long #= "a" };
                ignore Marketplaces.record(store, core, { backendCanisterId = core; frontendCanisterId = null; name = long }, owner, 1);
                ignore Marketplaces.record(store, core, { backendCanisterId = core; frontendCanisterId = ?frontend; name = long }, owner, 2);
                let all = Marketplaces.list(store);
                expect.nat(all.size()).equal(1);
                expect.nat(all[0].name.size()).equal(Marketplaces.MAX_NAME_SIZE);
                expect.int(all[0].recognizedAt).equal(2);
                Marketplaces.forget(store, core);
                expect.nat(Marketplaces.list(store).size()).equal(0);
            },
        );
    },
);
