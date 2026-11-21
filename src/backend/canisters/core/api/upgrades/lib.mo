import Array "mo:core/Array";
import Error "mo:core/Error";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Set "mo:core/Set";
import Text "mo:core/Text";

import Management "../../../../interfaces/management";
import Logger "../../../../lib/Logger";
import WasmVersion "../../../../lib/WasmVersion";
import ShopCanistersAPI "../shop_canisters";

/// How core upgrades shop and vault canisters (BRE-61, BRE-69).
///
/// Each upgrade stops the canister, so its in-flight calls finish first, snapshots it, installs the
/// new wasm and starts it again, also when the snapshot or the install fails. Core keeps one snapshot
/// per canister and replaces it on each upgrade; `restore` loads it back.
///
/// Upgrades only move forward: core refuses a version older than the one it recorded on the
/// canister (`#Downgrade`). Canisters whose version core doesn't know may get any version.
///
/// A new version rolls out gradually: the first canister upgraded to a (wasm name, version) is its
/// canary, and core refuses that version on every other canister until an admin approves the
/// rollout (`approveRollout`), which needs the canary to be running that version. Only shops an admin
/// marked as canary-eligible (`setCanaryEligible`), or their vaults, can be a canary (BRE-147), so a
/// version is never tried first on a merchant's live shop by mistake.
///
/// Approving a rollout also makes its version the current one for its name (BRE-85): new shops and
/// vaults get the current version. Yanking a version (`yank`) withdraws it in the canister factory
/// and, if it was current, moves current back to the last approved version that isn't yanked.
module {
    public type Snapshot = Management.Snapshot;
    public type WasmName = WasmVersion.WasmName;
    public type Version = WasmVersion.Version;

    /// A wasm version's rollout. `canary` is the first canister core upgraded to it.
    public type Rollout = {
        name : WasmName;
        version : Version;
        canary : Principal;
        approved : Bool;
    };

    public type State = {
        /// Rollouts by `WasmVersion.key(name, version)`.
        rollouts : Map.Map<Text, Rollout>;
        /// The wasm a canister ran when core took its snapshot, so `restore` can put the version
        /// back. No entry: unknown.
        snapshotVersions : Map.Map<Principal, ShopCanistersAPI.InstalledWasm>;
        /// Each name's current versions, oldest first: the last one is what new shops and vaults
        /// get. Approving a newer version appends it; yanking the current one drops it (`yank`).
        currentVersions : Map.Map<WasmName, [Version]>;
        /// Shops whose shop or vault may be a new version's canary. May hold unregistered shops:
        /// `listCanaryShops` filters them out.
        canaryShops : Set.Set<Principal>;
    };

    /// The canister factory and management canister calls core makes, so tests can replace them.
    public type Ops = {
        getWasm : (WasmName, Version) -> async Result<{ wasm : Blob; sha256 : Blob }, { #NotFound; #Yanked }>;
        /// Whether a version is yanked; null when the factory doesn't hold it.
        isYanked : (WasmName, Version) -> async ?Bool;
        /// Every version of `name` the factory holds that is yanked.
        yankedVersions : (WasmName) -> async [Version];
        setYanked : (WasmName, Version, Bool) -> async Result<(), { #Unauthorized : Text; #NotFound }>;
        /// The canister's module hash (`canister_status`).
        moduleHash : (Principal) -> async ?Blob;
        stop : (Principal) -> async ();
        start : (Principal) -> async ();
        listSnapshots : (Principal) -> async [Snapshot];
        takeSnapshot : (Principal, replace : ?Blob) -> async Snapshot;
        loadSnapshot : (Principal, snapshotId : Blob) -> async ();
        install : (Principal, wasm : Blob, arg : Blob) -> async ();
    };

    public type Deps = {
        state : State;
        shopCanisters : ShopCanistersAPI.State;
        /// Canisters with an upgrade, restore or start running. Transient: a core upgrade waits for
        /// these calls to finish anyway (`scripts/release.sh` stops core first).
        busy : Set.Set<Principal>;
        ops : Ops;
        logger : Logger.BoundLogger;
    };

    public type UpgradeError = {
        #Unauthorized;
        /// Not a registered shop (`upgradeShop`) or a vault core recorded for one (`upgradeVault`).
        #NotFound;
        /// Core handed the canister over to its merchant (BRE-79) and no longer controls it.
        #SelfManaged;
        #WasmNotFound;
        /// The version was yanked: nothing installs it.
        #WasmYanked;
        /// Another upgrade, restore or start of this canister hasn't finished.
        #UpgradeInProgress;
        /// The version's canary is another canister, and the rollout isn't approved yet.
        #RolloutNotApproved : { canary : Principal };
        /// No canister runs the version yet, so this one would be its canary, but its shop isn't
        /// canary-eligible (`setCanaryEligible`).
        #NotCanaryEligible;
        /// The canister runs a newer version. Core never installs an older one: its stable state may
        /// not fit, and the upgrade would replace the snapshot taken before the newer version. Undo a
        /// bad upgrade with `restoreSnapshot`, or roll out a fixed, higher version.
        #Downgrade : { installed : Version };
        /// The canister didn't stop (in-flight calls didn't finish in time). Nothing changed.
        #StopFailed : Text;
        /// Nothing was installed; the canister was started again.
        #SnapshotFailed : Text;
        /// The old wasm still runs; the canister was started again.
        #InstallFailed : Text;
        /// The step before succeeded (for an upgrade, the new wasm is installed), but the canister
        /// is still stopped. Retry with `startCanister`.
        #StartFailed : Text;
    };

    public type RestoreError = {
        #Unauthorized;
        #NotFound;
        /// Core handed the canister over to its merchant (BRE-79) and no longer controls it.
        #SelfManaged;

        #UpgradeInProgress;
        /// Core holds no snapshot of the canister.
        #NoSnapshot;
        #StopFailed : Text;
        /// The snapshot wasn't loaded; the canister was started again.
        #RestoreFailed : Text;
        #StartFailed : Text;
    };

    public type StartError = {
        #Unauthorized;
        #NotFound;
        /// Core handed the canister over to its merchant (BRE-79) and no longer controls it.
        #SelfManaged;

        #UpgradeInProgress;
        #StartFailed : Text;
    };

    public type ApproveError = {
        #Unauthorized;
        /// No canister has been upgraded to this version yet.
        #NotFound;
        /// The canary isn't running the version (its upgrade failed, or it was restored).
        #CanaryNotUpgraded : { canary : Principal };
        /// The version was yanked in the canister factory.
        #Yanked;
    };

    public type InitialVersionError = {
        #Unauthorized;
        /// A version is already current: move it with `approveRollout` instead.
        #AlreadySet : { current : Version };
        /// The canister factory holds no such version.
        #NotFound;
        /// The version was yanked in the canister factory.
        #Yanked;
    };

    public type YankError = {
        #Unauthorized;
        /// The canister factory holds no such version.
        #NotFound;
        /// The factory refused core's call (core needs the factory's Owner or Admin role).
        #FactoryError : Text;
    };

    public func newState() : State {
        {
            rollouts = Map.empty<Text, Rollout>();
            snapshotVersions = Map.empty<Principal, ShopCanistersAPI.InstalledWasm>();
            currentVersions = Map.empty<WasmName, [Version]>();
            canaryShops = Set.empty<Principal>();
        };
    };

    public func rolloutKey(name : WasmName, version : Version) : Text {
        WasmVersion.key(name, version);
    };

    /// The version new `name` canisters get. Null: none yet (no version was ever approved or set by
    /// a migration, or every one was yanked).
    public func currentVersion(state : State, name : WasmName) : ?Version {
        switch (Map.get(state.currentVersions, WasmVersion.compareName, name)) {
            case (?history) {
                if (history.size() == 0) { null } else {
                    ?history[history.size() - 1];
                };
            };
            case (null) { null };
        };
    };

    /// Makes `version` current for `name` if it's newer than the current one.
    public func advanceCurrent(state : State, name : WasmName, version : Version) {
        let history = switch (Map.get(state.currentVersions, WasmVersion.compareName, name)) {
            case (?h) { h };
            case (null) { [] };
        };
        let newer = switch (currentVersion(state, name)) {
            case (?current) {
                WasmVersion.compare(version, current) == #greater;
            };
            case (null) { true };
        };
        if (newer) {
            Map.add(state.currentVersions, WasmVersion.compareName, name, history.concat([version]));
        };
    };

    /// Drops yanked versions from the end of `name`'s history, so the current version is the last
    /// approved one that isn't yanked. Earlier yanked entries stay: they'd only matter if every later
    /// one were yanked too, and then they are dropped as well.
    public func dropYankedCurrent(state : State, name : WasmName, yanked : [Version]) {
        let history = switch (Map.get(state.currentVersions, WasmVersion.compareName, name)) {
            case (?h) { h };
            case (null) { return };
        };
        func isYanked(v : Version) : Bool {
            yanked.find(func(y : Version) : Bool = WasmVersion.equal(y, v)) != null;
        };
        var keep = history.size();
        while (keep > 0 and isYanked(history[keep - 1])) { keep -= 1 };
        if (keep < history.size()) {
            Map.add(state.currentVersions, WasmVersion.compareName, name, Array.sliceToArray(history, 0, keep));
        };
    };

    /// Upgrades `canisterId` to `name`'s wasm `version` from the canister factory. The caller checks
    /// that the caller is an admin and that `canisterId` holds a `name` wasm.
    public func upgrade(deps : Deps, canisterId : Principal, name : WasmName, version : Version, arg : Blob) : async Result<(), UpgradeError> {
        if (Set.contains(deps.busy, Principal.compare, canisterId)) {
            return #err(#UpgradeInProgress);
        };
        switch (ShopCanistersAPI.wasmVersion(deps.shopCanisters, canisterId)) {
            case (?current) {
                if (WasmVersion.compare(version, current.version) == #less) {
                    return #err(#Downgrade({ installed = current.version }));
                };
            };
            case (null) {};
        };
        let key = rolloutKey(name, version);
        let isNewCanary = switch (Map.get(deps.state.rollouts, Text.compare, key)) {
            case (null) {
                if (not isCanaryEligible(deps, canisterId, name)) {
                    return #err(#NotCanaryEligible);
                };
                true;
            };
            case (?rollout) {
                if (not rollout.approved and rollout.canary != canisterId) {
                    return #err(#RolloutNotApproved({ canary = rollout.canary }));
                };
                false;
            };
        };
        // Both are set before the first await, so a concurrent call sees them.
        if (isNewCanary) {
            Map.add(deps.state.rollouts, Text.compare, key, { name; version; canary = canisterId; approved = false });
        };
        Set.add(deps.busy, Principal.compare, canisterId);
        var installed = false;
        try {
            await* upgradeLocked(deps, canisterId, name, version, arg, func() { installed := true });
        } finally {
            Set.remove(deps.busy, Principal.compare, canisterId);
            // A canary whose install failed doesn't hold the version: the next canister upgraded to
            // it becomes the canary instead.
            if (isNewCanary and not installed) {
                Map.remove(deps.state.rollouts, Text.compare, key);
            };
        };
    };

    /// Whether `canisterId`, a `name` canister, belongs to a canary-eligible shop.
    func isCanaryEligible(deps : Deps, canisterId : Principal, name : WasmName) : Bool {
        let shopId = switch (name) {
            case (#shop) { ?canisterId };
            case (#vault) {
                ShopCanistersAPI.shopOfVault(deps.shopCanisters, canisterId);
            };
        };
        switch (shopId) {
            case (?id) {
                Set.contains(deps.state.canaryShops, Principal.compare, id);
            };
            case (null) { false };
        };
    };

    /// Allows or stops `shopId`'s shop and vault being a new version's canary. Rollouts that already
    /// have a canary keep it. The caller checks the caller and that `shopId` is a registered shop.
    public func setCanaryEligible(state : State, shopId : Principal, eligible : Bool) {
        if (eligible) {
            Set.add(state.canaryShops, Principal.compare, shopId);
        } else {
            Set.remove(state.canaryShops, Principal.compare, shopId);
        };
    };

    /// The canary-eligible shops that `isShop` accepts (core still lists them).
    public func listCanaryShops(state : State, isShop : Principal -> Bool) : [Principal] {
        Array.fromIter(Set.values(state.canaryShops)).filter(isShop);
    };

    func upgradeLocked(
        deps : Deps,
        canisterId : Principal,
        name : WasmName,
        version : Version,
        arg : Blob,
        onInstalled : () -> (),
    ) : async* Result<(), UpgradeError> {
        let { wasm; sha256 } = try {
            switch (await deps.ops.getWasm(name, version)) {
                case (#ok(w)) { w };
                case (#err(#NotFound)) { return #err(#WasmNotFound) };
                case (#err(#Yanked)) { return #err(#WasmYanked) };
            };
        } catch (_) {
            return #err(#WasmNotFound);
        };
        switch (await* stop(deps, canisterId)) {
            case (#err(msg)) { return #err(#StopFailed(msg)) };
            case (#ok) {};
        };
        let outcome : Result<(), UpgradeError> = try {
            await* takeSnapshot(deps, canisterId);
            try {
                await deps.ops.install(canisterId, wasm, arg);
                onInstalled();
                await* ShopCanistersAPI.verifyInstall(deps.shopCanisters, canisterId, name, version, sha256, deps.ops.moduleHash, deps.logger);
                #ok;
            } catch (e) {
                #err(#InstallFailed(Error.message(e)));
            };
        } catch (e) {
            #err(#SnapshotFailed(Error.message(e)));
        };
        switch (await* start(deps, canisterId), outcome) {
            case (#err(msg), #ok) { #err(#StartFailed(msg)) };
            case _ { outcome };
        };
    };

    /// Replaces core's snapshot of a stopped canister with a new one, and records the version it ran.
    func takeSnapshot(deps : Deps, canisterId : Principal) : async* () {
        let existing = await deps.ops.listSnapshots(canisterId);
        // Core keeps one snapshot per canister, so there is at most one to replace. Should there be
        // more, the oldest goes.
        let replace = switch (oldest(existing)) {
            case (?snapshot) { ?snapshot.id };
            case (null) { null };
        };
        ignore await deps.ops.takeSnapshot(canisterId, replace);
        switch (ShopCanistersAPI.wasmVersion(deps.shopCanisters, canisterId)) {
            case (?v) {
                Map.add(deps.state.snapshotVersions, Principal.compare, canisterId, v);
            };
            case (null) {
                Map.remove(deps.state.snapshotVersions, Principal.compare, canisterId);
            };
        };
    };

    /// Puts `canisterId` back to core's latest snapshot of it: its wasm and all of its state as they
    /// were before its last upgrade. Anything the canister recorded since (orders, payments) is lost,
    /// so this is for an upgrade that broke the canister, not an undo. The caller checks the caller
    /// and the target.
    public func restore(deps : Deps, canisterId : Principal) : async Result<(), RestoreError> {
        if (Set.contains(deps.busy, Principal.compare, canisterId)) {
            return #err(#UpgradeInProgress);
        };
        Set.add(deps.busy, Principal.compare, canisterId);
        try {
            await* restoreLocked(deps, canisterId);
        } finally {
            Set.remove(deps.busy, Principal.compare, canisterId);
        };
    };

    func restoreLocked(deps : Deps, canisterId : Principal) : async* Result<(), RestoreError> {
        let snapshot = try {
            switch (latest(await deps.ops.listSnapshots(canisterId))) {
                case (?s) { s };
                case (null) { return #err(#NoSnapshot) };
            };
        } catch (e) {
            return #err(#RestoreFailed(Error.message(e)));
        };
        switch (await* stop(deps, canisterId)) {
            case (#err(msg)) { return #err(#StopFailed(msg)) };
            case (#ok) {};
        };
        let outcome : Result<(), RestoreError> = try {
            await deps.ops.loadSnapshot(canisterId, snapshot.id);
            switch (Map.get(deps.state.snapshotVersions, Principal.compare, canisterId)) {
                case (?v) {
                    ShopCanistersAPI.recordInstall(deps.shopCanisters, canisterId, v);
                };
                case (null) {
                    ShopCanistersAPI.forgetVersion(deps.shopCanisters, canisterId);
                };
            };
            #ok;
        } catch (e) {
            #err(#RestoreFailed(Error.message(e)));
        };
        switch (await* start(deps, canisterId), outcome) {
            case (#err(msg), #ok) { #err(#StartFailed(msg)) };
            case _ { outcome };
        };
    };

    /// Starts a canister an upgrade or restore left stopped (`#StartFailed`). The caller checks the
    /// caller and the target.
    public func startCanister(deps : Deps, canisterId : Principal) : async Result<(), StartError> {
        if (Set.contains(deps.busy, Principal.compare, canisterId)) {
            return #err(#UpgradeInProgress);
        };
        Set.add(deps.busy, Principal.compare, canisterId);
        try {
            switch (await* start(deps, canisterId)) {
                case (#ok) { #ok };
                case (#err(msg)) { #err(#StartFailed(msg)) };
            };
        } finally {
            Set.remove(deps.busy, Principal.compare, canisterId);
        };
    };

    /// Lets every canister upgrade to `name`'s `version`, once its canary runs it, and makes it the
    /// version new canisters get if it's newer than the current one. A yanked version is refused.
    public func approveRollout(deps : Deps, name : WasmName, version : Version) : async Result<Rollout, ApproveError> {
        // Ask the factory first: the checks below must hold after this await.
        switch (await deps.ops.isYanked(name, version)) {
            case (?true) { return #err(#Yanked) };
            case (?false) {};
            case (null) { return #err(#NotFound) };
        };
        let key = rolloutKey(name, version);
        let rollout = switch (Map.get(deps.state.rollouts, Text.compare, key)) {
            case (?r) { r };
            case (null) { return #err(#NotFound) };
        };
        let canaryRuns = switch (ShopCanistersAPI.wasmVersion(deps.shopCanisters, rollout.canary)) {
            case (?installed) { WasmVersion.equal(installed.version, version) };
            case (null) { false };
        };
        if (not canaryRuns) {
            return #err(#CanaryNotUpgraded({ canary = rollout.canary }));
        };
        let approved = { rollout with approved = true };
        Map.add(deps.state.rollouts, Text.compare, key, approved);
        advanceCurrent(deps.state, name, version);
        #ok(approved);
    };

    /// Makes `version` current for `name` when no version is, for a network without canisters to
    /// canary on (a fresh install, or every approved version yanked). Once one is current, only
    /// `approveRollout` moves it. A yanked version is refused. The caller checks the caller.
    public func setInitialVersion(deps : Deps, name : WasmName, version : Version) : async Result<(), InitialVersionError> {
        switch (currentVersion(deps.state, name)) {
            case (?current) { return #err(#AlreadySet({ current })) };
            case (null) {};
        };
        switch (await deps.ops.isYanked(name, version)) {
            case (?true) { return #err(#Yanked) };
            case (?false) {};
            case (null) { return #err(#NotFound) };
        };
        // Another call may have made a version current during the await.
        switch (currentVersion(deps.state, name)) {
            case (?current) { return #err(#AlreadySet({ current })) };
            case (null) {};
        };
        advanceCurrent(deps.state, name, version);
        deps.logger.info("Made " # WasmVersion.key(name, version) # " the initial current version");
        #ok;
    };

    /// Yanks `name`'s `version` in the canister factory, so nothing installs it, and if it was the
    /// current version, moves current back to the last approved one that isn't yanked. Canisters
    /// already running it keep running it. The caller checks the caller.
    public func yank(deps : Deps, name : WasmName, version : Version) : async Result<(), YankError> {
        switch (await deps.ops.setYanked(name, version, true)) {
            case (#ok) {};
            case (#err(#NotFound)) { return #err(#NotFound) };
            case (#err(#Unauthorized(msg))) { return #err(#FactoryError(msg)) };
        };
        // Read the yanked set after the yank, and apply it to the history as it is now.
        let yanked = await deps.ops.yankedVersions(name);
        dropYankedCurrent(deps.state, name, yanked);
        switch (currentVersion(deps.state, name)) {
            case (?v) {
                deps.logger.info("Yanked " # WasmVersion.key(name, version) # "; current " # WasmVersion.nameText(name) # " version is " # WasmVersion.toText(v));
            };
            case (null) {
                deps.logger.warning("Yanked " # WasmVersion.key(name, version) # "; no " # WasmVersion.nameText(name) # " version is current, so new shops can't be created until one is approved");
            };
        };
        #ok;
    };

    /// Undoes `yank` in the canister factory. It doesn't make the version current again: approve a
    /// rollout for that. The caller checks the caller.
    public func unyank(deps : Deps, name : WasmName, version : Version) : async Result<(), YankError> {
        switch (await deps.ops.setYanked(name, version, false)) {
            case (#ok) { #ok };
            case (#err(#NotFound)) { #err(#NotFound) };
            case (#err(#Unauthorized(msg))) { #err(#FactoryError(msg)) };
        };
    };

    public func listRollouts(state : State) : [Rollout] {
        Array.fromIter(Map.values(state.rollouts));
    };

    func stop(deps : Deps, canisterId : Principal) : async* Result<(), Text> {
        try {
            await deps.ops.stop(canisterId);
            #ok;
        } catch (e) {
            // A stop the management canister rejects leaves the canister running, but start it to
            // be sure it isn't left stopping.
            ignore await* start(deps, canisterId);
            #err(Error.message(e));
        };
    };

    func start(deps : Deps, canisterId : Principal) : async* Result<(), Text> {
        try {
            await deps.ops.start(canisterId);
            #ok;
        } catch (e) {
            #err(Error.message(e));
        };
    };

    func oldest(snapshots : [Snapshot]) : ?Snapshot {
        pick(snapshots, func(a, b) = a.taken_at_timestamp < b.taken_at_timestamp);
    };

    func latest(snapshots : [Snapshot]) : ?Snapshot {
        pick(snapshots, func(a, b) = a.taken_at_timestamp > b.taken_at_timestamp);
    };

    func pick(snapshots : [Snapshot], better : (Snapshot, Snapshot) -> Bool) : ?Snapshot {
        var best : ?Snapshot = null;
        for (s in snapshots.vals()) {
            switch (best) {
                case (?b) { if (better(s, b)) { best := ?s } };
                case (null) { best := ?s };
            };
        };
        best;
    };

    /// The canister factory's calls core makes during upgrades and yanks.
    public type FactoryOps = {
        getWasm : (WasmName, Version) -> async Result<{ wasm : Blob; sha256 : Blob }, { #NotFound; #Yanked }>;
        isYanked : (WasmName, Version) -> async ?Bool;
        yankedVersions : (WasmName) -> async [Version];
        setYanked : (WasmName, Version, Bool) -> async Result<(), { #Unauthorized : Text; #NotFound }>;
    };

    /// The canister's module hash, read with `canister_status` (core controls the canister).
    public func moduleHash(canister_id : Principal) : async ?Blob {
        (await Management.getManagementCanister().canister_status({ canister_id })).module_hash;
    };

    /// The management canister calls, on `aaaaa-aa`, and the factory's.
    public func managementOps(factory : FactoryOps) : Ops {
        let ic = Management.getManagementCanister();
        {
            getWasm = factory.getWasm;
            isYanked = factory.isYanked;
            yankedVersions = factory.yankedVersions;
            setYanked = factory.setYanked;
            moduleHash;
            stop = func(canister_id : Principal) : async () {
                await ic.stop_canister({ canister_id });
            };
            start = func(canister_id : Principal) : async () {
                await ic.start_canister({ canister_id });
            };
            listSnapshots = func(canister_id : Principal) : async [Snapshot] {
                await ic.list_canister_snapshots({ canister_id });
            };
            takeSnapshot = func(canister_id : Principal, replace_snapshot : ?Blob) : async Snapshot {
                await ic.take_canister_snapshot({
                    canister_id;
                    replace_snapshot;
                });
            };
            loadSnapshot = func(canister_id : Principal, snapshot_id : Blob) : async () {
                await ic.load_canister_snapshot({
                    canister_id;
                    snapshot_id;
                    sender_canister_version = null;
                });
            };
            install = func(canister_id : Principal, wasm_module : Blob, arg : Blob) : async () {
                await ic.install_code({
                    mode = #upgrade(?{ skip_pre_upgrade = ?false; wasm_memory_persistence = ?#keep });
                    canister_id;
                    wasm_module;
                    arg;
                });
            };
        };
    };
};
