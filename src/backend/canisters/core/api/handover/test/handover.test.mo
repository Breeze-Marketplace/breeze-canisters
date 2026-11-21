import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Array "mo:core/Array";
import Error "mo:core/Error";
import List "mo:core/List";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Set "mo:core/Set";
import Text "mo:core/Text";

import HandoverAPI "../lib";

let core = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let shop = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let vault = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");
let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let newController = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
let stranger = Principal.fromText("aovwi-4maaa-aaaaa-qaagq-cai");
let anonymous = Principal.fromText("2vxsx-fae");

/// A fake management canister: keeps each canister's controllers, logs calls, and fails
/// `setControllers` on the canisters in `failing`.
type Fake = {
    deps : HandoverAPI.Deps;
    controllers : Map.Map<Principal, [Principal]>;
    failing : Set.Set<Principal>;
    forgotten : List.List<Principal>;
};

func fake() : Fake {
    let controllers = Map.empty<Principal, [Principal]>();
    Map.add(controllers, Principal.compare, shop, [core]);
    Map.add(controllers, Principal.compare, vault, [core]);
    let failing = Set.empty<Principal>();
    let forgotten = List.empty<Principal>();
    {
        deps = {
            state = HandoverAPI.newState();
            core;
            busy = Set.empty<Principal>();
            ownerOf = func(id : Principal) : ?Principal {
                if (id == shop) { ?owner } else { null };
            };
            vaultOf = func(id : Principal) : ?Principal {
                if (id == shop) { ?vault } else { null };
            };
            forgetVersion = func(id : Principal) { List.add(forgotten, id) };
            now = func() : Int = 42;
            ops = {
                setControllers = func(id : Principal, cs : [Principal]) : async () {
                    if (Set.contains(failing, Principal.compare, id)) {
                        throw Error.reject("update_settings failed");
                    };
                    Map.add(controllers, Principal.compare, id, cs);
                };
                controllers = func(id : Principal) : async [Principal] {
                    switch (Map.get(controllers, Principal.compare, id)) {
                        case (?cs) { cs };
                        case (null) { throw Error.reject("not found") };
                    };
                };
            };
        };
        controllers;
        failing;
        forgotten;
    };
};

func text(ps : [Principal]) : Text = Text.join(Array.map(ps, Principal.toText).vals(), ",");

func controllersOf(f : Fake, id : Principal) : Text {
    switch (Map.get(f.controllers, Principal.compare, id)) {
        case (?cs) { text(cs) };
        case (null) { "" };
    };
};

suite(
    "HandoverAPI",
    func() : async () {
        await test(
            "start adds the new controller next to core on both canisters",
            func() : async () {
                let f = fake();
                expect.bool((await HandoverAPI.start(f.deps, owner, shop, newController)) == #ok).isTrue();
                expect.text(controllersOf(f, shop)).equal(text([core, newController]));
                expect.text(controllersOf(f, vault)).equal(text([core, newController]));
                switch (HandoverAPI.status(f.deps.state, shop)) {
                    case (#HandoverPending(p)) {
                        expect.principal(p.controller).equal(newController);
                    };
                    case _ { expect.bool(false).isTrue() };
                };
                expect.bool(Set.isEmpty(f.deps.busy)).isTrue();
            },
        );

        await test(
            "only the owner can start, and not to an invalid principal",
            func() : async () {
                let f = fake();
                expect.bool((await HandoverAPI.start(f.deps, stranger, shop, newController)) == #err(#Unauthorized)).isTrue();
                expect.bool((await HandoverAPI.start(f.deps, anonymous, shop, newController)) == #err(#Unauthorized)).isTrue();
                expect.bool((await HandoverAPI.start(f.deps, owner, stranger, newController)) == #err(#NotFound)).isTrue();
                for (bad in [anonymous, owner, core, shop, vault].vals()) {
                    switch (await HandoverAPI.start(f.deps, owner, shop, bad)) {
                        case (#err(#InvalidController(_))) {};
                        case _ { expect.bool(false).isTrue() };
                    };
                };
                expect.text(controllersOf(f, shop)).equal(text([core]));
            },
        );

        await test(
            "a failed shop update puts the vault back",
            func() : async () {
                let f = fake();
                Set.add(f.failing, Principal.compare, shop);
                switch (await HandoverAPI.start(f.deps, owner, shop, newController)) {
                    case (#err(#UpdateFailed(_))) {};
                    case _ { expect.bool(false).isTrue() };
                };
                expect.text(controllersOf(f, vault)).equal(text([core]));
                expect.bool(HandoverAPI.status(f.deps.state, shop) == #Managed).isTrue();
                expect.bool(Set.isEmpty(f.deps.busy)).isTrue();
            },
        );

        await test(
            "only the pending controller confirms; core then removes itself",
            func() : async () {
                let f = fake();
                ignore await HandoverAPI.start(f.deps, owner, shop, newController);
                expect.bool((await HandoverAPI.confirm(f.deps, owner, shop)) == #err(#Unauthorized)).isTrue();
                switch (await HandoverAPI.confirm(f.deps, newController, shop)) {
                    case (#ok(s)) {
                        expect.principal(s.controller).equal(newController);
                    };
                    case _ { expect.bool(false).isTrue() };
                };
                expect.text(controllersOf(f, shop)).equal(text([newController]));
                expect.text(controllersOf(f, vault)).equal(text([newController]));
                expect.bool(HandoverAPI.isSelfManaged(f.deps.state, shop)).isTrue();
                expect.bool(HandoverAPI.isSelfManaged(f.deps.state, vault)).isTrue();
                expect.nat(List.size(f.forgotten)).equal(2);
                switch (await HandoverAPI.start(f.deps, owner, shop, stranger)) {
                    case (#err(#SelfManaged)) {};
                    case _ { expect.bool(false).isTrue() };
                };
            },
        );

        await test(
            "a confirm that failed on the shop can be retried, and can't be cancelled",
            func() : async () {
                let f = fake();
                ignore await HandoverAPI.start(f.deps, owner, shop, newController);
                Set.add(f.failing, Principal.compare, shop);
                switch (await HandoverAPI.confirm(f.deps, newController, shop)) {
                    case (#err(#UpdateFailed(_))) {};
                    case _ { expect.bool(false).isTrue() };
                };
                expect.text(controllersOf(f, vault)).equal(text([newController]));
                expect.bool(HandoverAPI.isSelfManaged(f.deps.state, vault)).isTrue();
                switch (await HandoverAPI.cancel(f.deps, owner, shop)) {
                    case (#err(#UpdateFailed(_))) {};
                    case _ { expect.bool(false).isTrue() };
                };
                Set.remove(f.failing, Principal.compare, shop);
                // The vault no longer accepts core's updates; a retry mustn't touch it.
                Set.add(f.failing, Principal.compare, vault);
                switch (await HandoverAPI.confirm(f.deps, newController, shop)) {
                    case (#ok(_)) {};
                    case _ { expect.bool(false).isTrue() };
                };
                expect.text(controllersOf(f, shop)).equal(text([newController]));
            },
        );

        await test(
            "cancel puts core back as the only controller",
            func() : async () {
                let f = fake();
                ignore await HandoverAPI.start(f.deps, owner, shop, newController);
                expect.bool((await HandoverAPI.cancel(f.deps, stranger, shop)) == #err(#Unauthorized)).isTrue();
                expect.bool((await HandoverAPI.cancel(f.deps, owner, shop)) == #ok).isTrue();
                expect.text(controllersOf(f, shop)).equal(text([core]));
                expect.text(controllersOf(f, vault)).equal(text([core]));
                expect.bool(HandoverAPI.status(f.deps.state, shop) == #Managed).isTrue();
                expect.bool((await HandoverAPI.confirm(f.deps, newController, shop)) == #err(#NoHandoverPending)).isTrue();
            },
        );

        await test(
            "steps are refused while the shop or vault is busy",
            func() : async () {
                let f = fake();
                Set.add(f.deps.busy, Principal.compare, vault);
                expect.bool((await HandoverAPI.start(f.deps, owner, shop, newController)) == #err(#UpgradeInProgress)).isTrue();
                expect.text(controllersOf(f, shop)).equal(text([core]));
            },
        );

        await test(
            "hand back needs core to be a controller of both canisters again",
            func() : async () {
                let f = fake();
                ignore await HandoverAPI.start(f.deps, owner, shop, newController);
                ignore await HandoverAPI.confirm(f.deps, newController, shop);
                expect.bool((await HandoverAPI.handBack(f.deps, stranger, shop)) == #err(#Unauthorized)).isTrue();
                Map.add(f.controllers, Principal.compare, shop, [newController, core]);
                switch (await HandoverAPI.handBack(f.deps, owner, shop)) {
                    case (#err(#CoreNotController(_))) {};
                    case _ { expect.bool(false).isTrue() };
                };
                Map.add(f.controllers, Principal.compare, vault, [newController, core]);
                expect.bool((await HandoverAPI.handBack(f.deps, newController, shop)) == #ok).isTrue();
                expect.bool(HandoverAPI.status(f.deps.state, shop) == #Managed).isTrue();
                expect.bool(HandoverAPI.isSelfManaged(f.deps.state, vault)).isFalse();
            },
        );
    },
);
