import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Error "mo:core/Error";
import List "mo:core/List";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Set "mo:core/Set";
import Text "mo:core/Text";

import CoreMap "mo:core/Map";
import Map "mo:map/Map";

import Logger "../../../../../lib/Logger";
import WasmVersion "../../../../../lib/WasmVersion";
import ShopCanistersAPI "../../shop_canisters";
import UpgradesAPI "../lib";

let canary = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let other = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");

let v1 : UpgradesAPI.Version = 1;
let v2 : UpgradesAPI.Version = 2;
let v3 : UpgradesAPI.Version = 1000;
let missing : UpgradesAPI.Version = 9009009;

/// The fake factory's SHA-256 of a version: one byte, the version modulo 256.
func hashOf(v : UpgradesAPI.Version) : Blob {
    Blob.fromArray([Nat8.fromNat(v % 256)]);
};

func installed(v : UpgradesAPI.Version) : ShopCanistersAPI.InstalledWasm {
    { version = v; sha256 = null };
};

/// A fake management canister: records each call in `log` and fails the steps named in `failing`.
type Fake = {
    deps : UpgradesAPI.Deps;
    log : List.List<Text>;
    failing : Set.Set<Text>;
    snapshots : List.List<UpgradesAPI.Snapshot>;
    /// Runs inside `install`, to try a second call while an upgrade is in flight.
    var duringInstall : ?(() -> async ());
    /// Versions the fake factory holds as yanked, by `WasmVersion.key`.
    yanked : Set.Set<Text>;
    /// What the fake management canister reports as the module hash after an install. Null: the
    /// hash of the version installed last.
    var moduleHash : ?Blob;
    errors : List.List<Text>;
};

func fake() : Fake {
    let log = List.empty<Text>();
    let failing = Set.empty<Text>();
    let snapshots = List.empty<UpgradesAPI.Snapshot>();
    var clock : Nat64 = 0;
    var self : ?Fake = null;
    let yanked = Set.empty<Text>();
    let errors = List.empty<Text>();
    var lastInstalled : ?Blob = null;
    func step(name : Text, canisterId : Principal) : async () {
        List.add(log, name # " " # Principal.toText(canisterId));
        if (Set.contains(failing, Text.compare, name)) {
            throw Error.reject(name # " failed");
        };
    };
    let shopCanisters : ShopCanistersAPI.State = {
        wasmVersions = Map.new<Principal, ShopCanistersAPI.InstalledWasm>();
        vaultsByShop = Map.new<Principal, Principal>();
    };
    let ops : UpgradesAPI.Ops = {
        getWasm = func(name : UpgradesAPI.WasmName, version : UpgradesAPI.Version) : async Result<{ wasm : Blob; sha256 : Blob }, { #NotFound; #Yanked }> {
            if (version == missing) { #err(#NotFound) } else if (Set.contains(yanked, Text.compare, WasmVersion.key(name, version))) {
                #err(#Yanked);
            } else {
                #ok({ wasm = hashOf(version); sha256 = hashOf(version) });
            };
        };
        isYanked = func(name : UpgradesAPI.WasmName, version : UpgradesAPI.Version) : async ?Bool {
            if (version == missing) { null } else {
                ?Set.contains(yanked, Text.compare, WasmVersion.key(name, version));
            };
        };
        yankedVersions = func(name : UpgradesAPI.WasmName) : async [UpgradesAPI.Version] {
            [v1, v2, v3].filter(func(v : UpgradesAPI.Version) : Bool = Set.contains(yanked, Text.compare, WasmVersion.key(name, v)));
        };
        setYanked = func(name : UpgradesAPI.WasmName, version : UpgradesAPI.Version, y : Bool) : async Result<(), { #Unauthorized : Text; #NotFound }> {
            if (version == missing) { return #err(#NotFound) };
            if (y) {
                Set.add(yanked, Text.compare, WasmVersion.key(name, version));
            } else {
                Set.remove(yanked, Text.compare, WasmVersion.key(name, version));
            };
            #ok;
        };
        moduleHash = func(_ : Principal) : async ?Blob {
            switch (self) {
                case (?f) {
                    switch (f.moduleHash) {
                        case (?h) { ?h };
                        case (null) { lastInstalled };
                    };
                };
                case (null) { lastInstalled };
            };
        };
        stop = func(id : Principal) : async () { await step("stop", id) };
        start = func(id : Principal) : async () { await step("start", id) };
        listSnapshots = func(_ : Principal) : async [UpgradesAPI.Snapshot] {
            List.toArray(snapshots);
        };
        takeSnapshot = func(id : Principal, replace : ?Blob) : async UpgradesAPI.Snapshot {
            await step(if (replace == null) { "snapshot" } else { "replace-snapshot" }, id);
            List.clear(snapshots);
            clock += 1;
            let s : UpgradesAPI.Snapshot = {
                id = "\01" : Blob;
                taken_at_timestamp = clock;
                total_size = 0 : Nat64;
            };
            List.add(snapshots, s);
            s;
        };
        loadSnapshot = func(id : Principal, _ : Blob) : async () {
            await step("load", id);
        };
        install = func(id : Principal, wasm : Blob, _ : Blob) : async () {
            switch (self) {
                case (?f) {
                    switch (f.duringInstall) {
                        case (?run) { await run() };
                        case (null) {};
                    };
                };
                case (null) {};
            };
            await step("install", id);
            // The fake wasm's bytes are its hash, so the canister's module hash is the wasm.
            lastInstalled := ?wasm;
        };
    };
    let f : Fake = {
        deps = {
            state = UpgradesAPI.newState();
            shopCanisters;
            busy = Set.empty<Principal>();
            ops;
            logger = {
                info = func(_ : Text) {};
                warning = func(_ : Text) {};
                error = func(m : Text) { List.add(errors, m) };
                infoWith = func(_ : Text, _ : [Logger.Field]) {};
                warningWith = func(_ : Text, _ : [Logger.Field]) {};
                errorWith = func(m : Text, _ : [Logger.Field]) {
                    List.add(errors, m);
                };
            };
        };
        log;
        failing;
        snapshots;
        var duringInstall = null;
        yanked;
        var moduleHash = null;
        errors;
    };
    self := ?f;
    // Both test shops may be canaries unless a test says otherwise.
    UpgradesAPI.setCanaryEligible(f.deps.state, canary, true);
    UpgradesAPI.setCanaryEligible(f.deps.state, other, true);
    f;
};

let canaryVault = Principal.fromText("qhbym-qaaaa-aaaaa-aaafq-cai");

func steps(f : Fake) : Text {
    Text.join(List.values(f.log), ", ");
};

func version(f : Fake, id : Principal) : ?UpgradesAPI.Version {
    switch (ShopCanistersAPI.wasmVersion(f.deps.shopCanisters, id)) {
        case (?i) { ?i.version };
        case (null) { null };
    };
};

let c = Principal.toText(canary);

suite(
    "UpgradesAPI",
    func() : async () {
        await test(
            "stops, snapshots, installs and starts the canister",
            func() : async () {
                let f = fake();
                ShopCanistersAPI.recordInstall(f.deps.shopCanisters, canary, installed(v1));
                expect.bool((await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "")) == #ok).isTrue();
                expect.text(steps(f)).equal("stop " # c # ", snapshot " # c # ", install " # c # ", start " # c);
                expect.bool(version(f, canary) == ?v2).isTrue();
                expect.bool(CoreMap.get(f.deps.state.snapshotVersions, Principal.compare, canary) == ?installed(v1)).isTrue();
                expect.bool(Set.isEmpty(f.deps.busy)).isTrue();
            },
        );

        await test(
            "refuses a version older than the installed one, before stopping the canister",
            func() : async () {
                let f = fake();
                ShopCanistersAPI.recordInstall(f.deps.shopCanisters, canary, installed(v2));
                let result = await UpgradesAPI.upgrade(f.deps, canary, #shop, v1, "");
                expect.bool(result == #err(#Downgrade({ installed = v2 }))).isTrue();
                expect.text(steps(f)).equal("");
                expect.bool(version(f, canary) == ?v2).isTrue();
                // A refused upgrade makes no canary.
                expect.nat(UpgradesAPI.listRollouts(f.deps.state).size()).equal(0);
                // The same version installs again (a retry), and so does a newer one.
                expect.bool((await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "")) == #ok).isTrue();
                expect.bool((await UpgradesAPI.upgrade(f.deps, canary, #shop, v3, "")) == #ok).isTrue();
            },
        );

        await test(
            "upgrades a canister whose version core doesn't know to any version",
            func() : async () {
                let f = fake();
                expect.bool((await UpgradesAPI.upgrade(f.deps, canary, #shop, v1, "")) == #ok).isTrue();
                expect.bool(version(f, canary) == ?v1).isTrue();
            },
        );

        await test(
            "replaces the previous snapshot",
            func() : async () {
                let f = fake();
                ignore await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "");
                List.clear(f.log);
                ignore await UpgradesAPI.upgrade(f.deps, canary, #shop, v3, "");
                expect.text(steps(f)).equal("stop " # c # ", replace-snapshot " # c # ", install " # c # ", start " # c);
                expect.nat(List.size(f.snapshots)).equal(1);
            },
        );

        await test(
            "starts the canister again when the install fails",
            func() : async () {
                let f = fake();
                ShopCanistersAPI.recordInstall(f.deps.shopCanisters, canary, installed(v1));
                Set.add(f.failing, Text.compare, "install");
                let result = await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "");
                expect.bool(result == #err(#InstallFailed("install failed"))).isTrue();
                expect.text(steps(f)).equal("stop " # c # ", snapshot " # c # ", install " # c # ", start " # c);
                expect.bool(version(f, canary) == ?v1).isTrue();
                // The failed canary doesn't hold the version: another canister may go first.
                expect.nat(UpgradesAPI.listRollouts(f.deps.state).size()).equal(0);
            },
        );

        await test(
            "starts the canister again when the snapshot fails, without installing",
            func() : async () {
                let f = fake();
                Set.add(f.failing, Text.compare, "snapshot");
                let result = await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "");
                expect.bool(result == #err(#SnapshotFailed("snapshot failed"))).isTrue();
                expect.text(steps(f)).equal("stop " # c # ", snapshot " # c # ", start " # c);
            },
        );

        await test(
            "doesn't snapshot or install when the stop fails",
            func() : async () {
                let f = fake();
                Set.add(f.failing, Text.compare, "stop");
                let result = await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "");
                expect.bool(result == #err(#StopFailed("stop failed"))).isTrue();
                expect.text(steps(f)).equal("stop " # c # ", start " # c);
            },
        );

        await test(
            "reports a start that fails after the install",
            func() : async () {
                let f = fake();
                Set.add(f.failing, Text.compare, "start");
                let result = await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "");
                expect.bool(result == #err(#StartFailed("start failed"))).isTrue();
                expect.bool(version(f, canary) == ?v2).isTrue();
                Set.remove(f.failing, Text.compare, "start");
                expect.bool((await UpgradesAPI.startCanister(f.deps, canary)) == #ok).isTrue();
            },
        );

        await test(
            "a missing wasm leaves the canister alone",
            func() : async () {
                let f = fake();
                let result = await UpgradesAPI.upgrade(f.deps, canary, #shop, missing, "");
                expect.bool(result == #err(#WasmNotFound)).isTrue();
                expect.text(steps(f)).equal("");
            },
        );

        await test(
            "refuses a second upgrade or restore of a canister while one runs",
            func() : async () {
                let f = fake();
                var second : ?Result<(), UpgradesAPI.UpgradeError> = null;
                var restore : ?Result<(), UpgradesAPI.RestoreError> = null;
                f.duringInstall := ?(
                    func() : async () {
                        second := ?(await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, ""));
                        restore := ?(await UpgradesAPI.restore(f.deps, canary));
                    }
                );
                expect.bool((await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "")) == #ok).isTrue();
                expect.bool(second == ?#err(#UpgradeInProgress)).isTrue();
                expect.bool(restore == ?#err(#UpgradeInProgress)).isTrue();
            },
        );

        await test(
            "a new version reaches only its canary until the rollout is approved",
            func() : async () {
                let f = fake();
                expect.bool((await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "")) == #ok).isTrue();
                let refused = await UpgradesAPI.upgrade(f.deps, other, #shop, v2, "");
                expect.bool(refused == #err(#RolloutNotApproved({ canary }))).isTrue();
                expect.bool(version(f, other) == null).isTrue();
                // The canary can retry, and vaults roll out separately.
                expect.bool((await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "")) == #ok).isTrue();
                ShopCanistersAPI.linkVault(f.deps.shopCanisters, canary, canaryVault);
                expect.bool((await UpgradesAPI.upgrade(f.deps, canaryVault, #vault, v2, "")) == #ok).isTrue();

                switch (await UpgradesAPI.approveRollout(f.deps, #shop, v2)) {
                    case (#ok(r)) {
                        expect.bool(r.approved and r.canary == canary).isTrue();
                    };
                    case (#err(_)) { expect.bool(false).isTrue() };
                };
                expect.bool((await UpgradesAPI.upgrade(f.deps, other, #shop, v2, "")) == #ok).isTrue();
                expect.bool(version(f, other) == ?v2).isTrue();
            },
        );

        await test(
            "only a canary-eligible shop, or its vault, can be a new version's canary",
            func() : async () {
                let f = fake();
                UpgradesAPI.setCanaryEligible(f.deps.state, other, false);
                let refused = await UpgradesAPI.upgrade(f.deps, other, #shop, v2, "");
                expect.bool(refused == #err(#NotCanaryEligible)).isTrue();
                expect.text(steps(f)).equal("");
                expect.nat(UpgradesAPI.listRollouts(f.deps.state).size()).equal(0);

                // A vault takes its shop's eligibility; one core can't place is refused.
                ShopCanistersAPI.linkVault(f.deps.shopCanisters, other, canaryVault);
                expect.bool((await UpgradesAPI.upgrade(f.deps, canaryVault, #vault, v2, "")) == #err(#NotCanaryEligible)).isTrue();
                let unknownVault = Principal.fromText("aaaaa-aa");
                expect.bool((await UpgradesAPI.upgrade(f.deps, unknownVault, #vault, v2, "")) == #err(#NotCanaryEligible)).isTrue();
                UpgradesAPI.setCanaryEligible(f.deps.state, other, true);
                expect.bool((await UpgradesAPI.upgrade(f.deps, canaryVault, #vault, v2, "")) == #ok).isTrue();

                // Once a version has its canary, eligibility no longer matters to the other canisters.
                expect.bool((await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "")) == #ok).isTrue();
                ignore await UpgradesAPI.approveRollout(f.deps, #shop, v2);
                UpgradesAPI.setCanaryEligible(f.deps.state, other, false);
                expect.bool((await UpgradesAPI.upgrade(f.deps, other, #shop, v2, "")) == #ok).isTrue();
            },
        );

        await test(
            "lists the canary-eligible shops core still knows",
            func() : async () {
                let f = fake();
                let listed = UpgradesAPI.listCanaryShops(f.deps.state, func(id : Principal) : Bool = id == canary);
                expect.bool(listed == [canary]).isTrue();
            },
        );

        await test(
            "a rollout can't be approved before its canary runs the version",
            func() : async () {
                let f = fake();
                expect.bool((await UpgradesAPI.approveRollout(f.deps, #shop, v2)) == #err(#NotFound)).isTrue();
                ShopCanistersAPI.recordInstall(f.deps.shopCanisters, canary, installed(v1));
                ignore await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "");
                ignore await UpgradesAPI.restore(f.deps, canary);
                expect.bool((await UpgradesAPI.approveRollout(f.deps, #shop, v2)) == #err(#CanaryNotUpgraded({ canary }))).isTrue();
            },
        );

        await test(
            "restore loads the snapshot in a stopped canister and puts its version back",
            func() : async () {
                let f = fake();
                expect.bool((await UpgradesAPI.restore(f.deps, canary)) == #err(#NoSnapshot)).isTrue();
                ShopCanistersAPI.recordInstall(f.deps.shopCanisters, canary, installed(v1));
                ignore await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "");
                List.clear(f.log);
                expect.bool((await UpgradesAPI.restore(f.deps, canary)) == #ok).isTrue();
                expect.text(steps(f)).equal("stop " # c # ", load " # c # ", start " # c);
                expect.bool(version(f, canary) == ?v1).isTrue();
            },
        );

        await test(
            "restore starts the canister again when the load fails",
            func() : async () {
                let f = fake();
                ignore await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "");
                List.clear(f.log);
                Set.add(f.failing, Text.compare, "load");
                expect.bool((await UpgradesAPI.restore(f.deps, canary)) == #err(#RestoreFailed("load failed"))).isTrue();
                expect.text(steps(f)).equal("stop " # c # ", load " # c # ", start " # c);
                expect.bool(version(f, canary) == ?v2).isTrue();
            },
        );
        await test(
            "records the canister's module hash with the version after an upgrade",
            func() : async () {
                let f = fake();
                expect.bool((await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "")) == #ok).isTrue();
                let recorded = ShopCanistersAPI.wasmVersion(f.deps.shopCanisters, canary);
                expect.bool(recorded == ?{ version = v2; sha256 = ?hashOf(v2) }).isTrue();
                expect.nat(List.size(f.errors)).equal(0);
            },
        );

        await test(
            "logs an error when the module hash doesn't match the factory's",
            func() : async () {
                let f = fake();
                f.moduleHash := ?("\ff" : Blob);
                expect.bool((await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "")) == #ok).isTrue();
                expect.nat(List.size(f.errors)).equal(1);
                let recorded = ShopCanistersAPI.wasmVersion(f.deps.shopCanisters, canary);
                expect.bool(recorded == ?{ version = v2; sha256 = ?("\ff" : Blob) }).isTrue();
            },
        );

        await test(
            "a yanked version can't be installed or approved",
            func() : async () {
                let f = fake();
                expect.bool((await UpgradesAPI.upgrade(f.deps, canary, #shop, v2, "")) == #ok).isTrue();
                expect.bool((await UpgradesAPI.yank(f.deps, #shop, v2)) == #ok).isTrue();
                expect.bool((await UpgradesAPI.approveRollout(f.deps, #shop, v2)) == #err(#Yanked)).isTrue();
                expect.bool((await UpgradesAPI.yank(f.deps, #shop, v3)) == #ok).isTrue();
                List.clear(f.log);
                expect.bool((await UpgradesAPI.upgrade(f.deps, other, #shop, v3, "")) == #err(#WasmYanked)).isTrue();
                expect.text(steps(f)).equal("");
                // A yanked version's failed canary attempt doesn't claim the rollout.
                expect.nat(UpgradesAPI.listRollouts(f.deps.state).size()).equal(1);
                expect.bool((await UpgradesAPI.yank(f.deps, #shop, missing)) == #err(#NotFound)).isTrue();
            },
        );

        await test(
            "approving a rollout makes its version current, unless a newer one already is",
            func() : async () {
                let f = fake();
                UpgradesAPI.advanceCurrent(f.deps.state, #shop, v1);
                expect.bool(UpgradesAPI.currentVersion(f.deps.state, #shop) == ?v1).isTrue();
                expect.bool(UpgradesAPI.currentVersion(f.deps.state, #vault) == null).isTrue();
                ignore await UpgradesAPI.upgrade(f.deps, canary, #shop, v3, "");
                ignore await UpgradesAPI.approveRollout(f.deps, #shop, v3);
                expect.bool(UpgradesAPI.currentVersion(f.deps.state, #shop) == ?v3).isTrue();
                ignore await UpgradesAPI.upgrade(f.deps, other, #shop, v2, "");
                ignore await UpgradesAPI.approveRollout(f.deps, #shop, v2);
                expect.bool(UpgradesAPI.currentVersion(f.deps.state, #shop) == ?v3).isTrue();
                // Vaults keep their own current version.
                expect.bool(UpgradesAPI.currentVersion(f.deps.state, #vault) == null).isTrue();
            },
        );

        await test(
            "yanking the current version falls back to the last approved one that isn't yanked",
            func() : async () {
                let f = fake();
                UpgradesAPI.advanceCurrent(f.deps.state, #shop, v1);
                UpgradesAPI.advanceCurrent(f.deps.state, #shop, v2);
                UpgradesAPI.advanceCurrent(f.deps.state, #shop, v3);
                // Yanking a version that isn't current leaves current alone.
                expect.bool((await UpgradesAPI.yank(f.deps, #shop, v2)) == #ok).isTrue();
                expect.bool(UpgradesAPI.currentVersion(f.deps.state, #shop) == ?v3).isTrue();
                // v2 is yanked too, so current goes back past it to v1.
                expect.bool((await UpgradesAPI.yank(f.deps, #shop, v3)) == #ok).isTrue();
                expect.bool(UpgradesAPI.currentVersion(f.deps.state, #shop) == ?v1).isTrue();
                // Unyanking doesn't make a version current again.
                expect.bool((await UpgradesAPI.unyank(f.deps, #shop, v3)) == #ok).isTrue();
                expect.bool(UpgradesAPI.currentVersion(f.deps.state, #shop) == ?v1).isTrue();
                expect.bool((await UpgradesAPI.yank(f.deps, #shop, v1)) == #ok).isTrue();
                expect.bool(UpgradesAPI.currentVersion(f.deps.state, #shop) == null).isTrue();
            },
        );

        await test(
            "an initial version is set only while none is current, and never a yanked or missing one",
            func() : async () {
                let f = fake();
                expect.bool((await UpgradesAPI.setInitialVersion(f.deps, #shop, missing)) == #err(#NotFound)).isTrue();
                ignore await UpgradesAPI.yank(f.deps, #shop, v1);
                expect.bool((await UpgradesAPI.setInitialVersion(f.deps, #shop, v1)) == #err(#Yanked)).isTrue();
                expect.bool(UpgradesAPI.currentVersion(f.deps.state, #shop) == null).isTrue();

                expect.bool((await UpgradesAPI.setInitialVersion(f.deps, #shop, v2)) == #ok).isTrue();
                expect.bool(UpgradesAPI.currentVersion(f.deps.state, #shop) == ?v2).isTrue();
                expect.bool((await UpgradesAPI.setInitialVersion(f.deps, #shop, v3)) == #err(#AlreadySet({ current = v2 }))).isTrue();
                expect.bool(UpgradesAPI.currentVersion(f.deps.state, #shop) == ?v2).isTrue();
                // Vaults have their own.
                expect.bool((await UpgradesAPI.setInitialVersion(f.deps, #vault, v3)) == #ok).isTrue();
            },
        );
    },
);
