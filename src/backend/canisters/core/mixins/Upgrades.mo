import Array "mo:core/Array";
import { type Result } "mo:core/Result";
import Set "mo:core/Set";
import Map "mo:map/Map";

import Logger "../../../lib/Logger";
import AdminAPI "../api/admin";
import PlatformPermissions "../../../lib/PlatformPermissions";
import HandoverAPI "../api/handover";
import ShopAPI "../api/shop";
import ShopCanistersAPI "../api/shop_canisters";
import UpgradesAPI "../api/upgrades";
import Siblings "../lib/Siblings";
import Types "../types";
import HistoryAPI "../api/history";

/// Upgrades shop and vault canisters to a wasm version stored in the canister factory: stop,
/// snapshot, install, start. A new version reaches one canary canister first and the rest only after
/// `approveRollout` (see `api/upgrades`), which also makes the version the one new shops or vaults
/// get (BRE-85). Each method needs a platform permission (`Upgrades.View`, `Run` or `Approve`). Shops and vaults handed over to their merchant (BRE-79)
/// are refused with `#SelfManaged`: core no longer controls them.
mixin (
    adminApi : AdminAPI.API,
    shopCanistersState : ShopCanistersAPI.State,
    shopRegistry : Map.Map<Principal, ShopAPI.ShopRegistryItem>,
    upgradesState : UpgradesAPI.State,
    upgradesBusy : Set.Set<Principal>,
    handoverState : HandoverAPI.State,
    history : HistoryAPI.State,
    logger : Logger.BoundLogger,
) {
    func factoryOps<system>() : UpgradesAPI.FactoryOps {
        let factory = Siblings.canisterFactory<system>();
        {
            getWasm = func(name : UpgradesAPI.WasmName, version : UpgradesAPI.Version) : async Result<{ wasm : Blob; sha256 : Blob }, { #NotFound; #Yanked }> {
                await factory.getWasm(name, version);
            };
            isYanked = func(name : UpgradesAPI.WasmName, version : UpgradesAPI.Version) : async ?Bool {
                switch (await factory.getWasmInfo(name, version)) {
                    case (?info) { ?info.yanked };
                    case (null) { null };
                };
            };
            yankedVersions = func(name : UpgradesAPI.WasmName) : async [UpgradesAPI.Version] {
                let all = await factory.listWasms(name);
                all.filterMap(func(w : Siblings.WasmInfo) : ?UpgradesAPI.Version = if (w.yanked) ?w.version else null);
            };
            setYanked = func(name : UpgradesAPI.WasmName, version : UpgradesAPI.Version, yanked : Bool) : async Result<(), { #Unauthorized : Text; #NotFound }> {
                if (yanked) { await factory.yankWasm(name, version) } else {
                    await factory.unyankWasm(name, version);
                };
            };
        };
    };

    func upgradesDeps<system>() : UpgradesAPI.Deps {
        {
            state = upgradesState;
            shopCanisters = shopCanistersState;
            busy = upgradesBusy;
            ops = UpgradesAPI.managementOps(factoryOps<system>());
            logger;
        };
    };

    func isShopCanister(canisterId : Principal) : Bool {
        Map.has(shopRegistry, Map.phash, canisterId);
    };

    func selfManaged(canisterId : Principal) : Bool {
        HandoverAPI.isSelfManaged(handoverState, canisterId);
    };

    /// The shop a shop or vault belongs to, for the history.
    func shopOf(canisterId : Principal) : ?Principal {
        if (isShopCanister(canisterId)) ?canisterId else ShopCanistersAPI.shopOfVault(shopCanistersState, canisterId);
    };

    /// Records an upgrade that got as far as the canister, ended well or not. Refusals that changed
    /// nothing (busy, a downgrade, an unapproved rollout) aren't history.
    func recordUpgrade(caller : Principal, canisterId : Principal, name : HistoryAPI.WasmName, version : HistoryAPI.Version, result : Result<(), UpgradesAPI.UpgradeError>) {
        let reachedCanister = switch (result) {
            case (#ok or #err(#StopFailed(_) or #SnapshotFailed(_) or #InstallFailed(_) or #StartFailed(_))) true;
            case (#err(_)) false;
        };
        if (reachedCanister) {
            ignore HistoryAPI.record(history, caller, shopOf(canisterId), #upgraded({ canister = canisterId; name; version; outcome = HistoryAPI.outcome(result, func e = debug_show e) }));
        };
    };

    func isShopOrVault(canisterId : Principal) : Bool {
        isShopCanister(canisterId) or ShopCanistersAPI.isVault(shopCanistersState, canisterId);
    };

    /// The versions of a wasm stored in the canister factory, oldest first (version, SHA-256, size,
    /// note, whether it's yanked; not the bytes), to pick one for `upgradeShop` / `upgradeVault`.
    /// Needs `Upgrades.View`.
    public shared ({ caller }) func listWasms(name : UpgradesAPI.WasmName) : async Result<[Siblings.WasmInfo], { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesView)) {
            return #err(#Unauthorized);
        };
        #ok(await Siblings.canisterFactory<system>().listWasms(name));
    };

    /// The shop and vault versions new shops get: each is the newest approved rollout, unless it was
    /// yanked (BRE-85). Null: none, so shop creation fails until a version is approved. Needs `Upgrades.View`.
    public query ({ caller }) func getCurrentWasmVersions() : async Result<{ shop : ?UpgradesAPI.Version; vault : ?UpgradesAPI.Version }, { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesView)) {
            return #err(#Unauthorized);
        };
        #ok({
            shop = UpgradesAPI.currentVersion(upgradesState, #shop);
            vault = UpgradesAPI.currentVersion(upgradesState, #vault);
        });
    };

    /// Makes a wasm version the one new shops or vaults get while none is, with no canary: for a
    /// fresh network (`scripts/setup.sh`) or after every approved version was yanked. Once a
    /// version is current, only `approveRollout` changes it. Needs `Upgrades.Approve`.
    public shared ({ caller }) func setInitialWasmVersion(name : UpgradesAPI.WasmName, version : UpgradesAPI.Version) : async Result<(), UpgradesAPI.InitialVersionError> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesApprove)) {
            return #err(#Unauthorized);
        };
        let result = await UpgradesAPI.setInitialVersion(upgradesDeps<system>(), name, version);
        if (result == #ok) ignore HistoryAPI.record(history, caller, null, #initialVersionSet({ name; version }));
        result;
    };

    /// Withdraws a wasm version in the canister factory, so nothing can install it (new shops,
    /// upgrades, publishing), and if new shops were getting it, moves them back to the last approved
    /// version that isn't yanked. Canisters already running it keep it: upgrade them off it. Needs `Upgrades.Approve`.
    public shared ({ caller }) func yankWasm(name : UpgradesAPI.WasmName, version : UpgradesAPI.Version) : async Result<(), UpgradesAPI.YankError> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesApprove)) {
            return #err(#Unauthorized);
        };
        let result = await UpgradesAPI.yank(upgradesDeps<system>(), name, version);
        if (result == #ok) ignore HistoryAPI.record(history, caller, null, #wasmYanked({ name; version }));
        result;
    };

    /// Undoes `yankWasm`. It doesn't make the version current again. Needs `Upgrades.Approve`.
    public shared ({ caller }) func unyankWasm(name : UpgradesAPI.WasmName, version : UpgradesAPI.Version) : async Result<(), UpgradesAPI.YankError> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesApprove)) {
            return #err(#Unauthorized);
        };
        let result = await UpgradesAPI.unyank(upgradesDeps<system>(), name, version);
        if (result == #ok) ignore HistoryAPI.record(history, caller, null, #wasmUnyanked({ name; version }));
        result;
    };

    /// Upgrades a vault core recorded for a shop to a wasm version stored in the canister factory.
    /// The first vault upgraded to a version is its canary, and its shop must be canary-eligible
    /// (`setCanaryEligible`); others wait for `approveRollout`. Needs `Upgrades.Run`.
    public shared ({ caller }) func upgradeVault(canisterId : Principal, version : UpgradesAPI.Version) : async Result<(), UpgradesAPI.UpgradeError> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesRun)) {
            return #err(#Unauthorized);
        };
        if (not ShopCanistersAPI.isVault(shopCanistersState, canisterId)) {
            return #err(#NotFound);
        };
        if (selfManaged(canisterId)) {
            return #err(#SelfManaged);
        };
        let result = await UpgradesAPI.upgrade(upgradesDeps<system>(), canisterId, #vault, version, to_candid ());
        recordUpgrade(caller, canisterId, #vault, version, result);
        result;
    };

    /// Upgrades a registered shop to a wasm version stored in the canister factory. The first shop
    /// upgraded to a version is its canary, and must be canary-eligible (`setCanaryEligible`); others
    /// wait for `approveRollout`. Needs `Upgrades.Run`.
    public shared ({ caller }) func upgradeShop(
        canisterId : Principal,
        version : UpgradesAPI.Version,
        args : Types.ShopInitArgs,
    ) : async Result<(), UpgradesAPI.UpgradeError> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesRun)) {
            return #err(#Unauthorized);
        };
        if (not isShopCanister(canisterId)) {
            return #err(#NotFound);
        };
        if (selfManaged(canisterId)) {
            return #err(#SelfManaged);
        };
        // The shop reads its init args on the first install only, but the arg must still decode.
        // Shop wasms before the arg was dropped require `hmacSecretKey`; current ones ignore it.
        // An empty key leaves the shop's own key alone.
        let shopArgs = { args with hmacSecretKey = "" : Blob };
        let result = await UpgradesAPI.upgrade(upgradesDeps<system>(), canisterId, #shop, version, to_candid (shopArgs));
        recordUpgrade(caller, canisterId, #shop, version, result);
        result;
    };

    /// Lets every shop or vault upgrade to `version`, once its canary runs it, and makes it the
    /// version new shops or vaults get when it's newer than the current one. Check the canary works
    /// before approving. A yanked version is refused. Needs `Upgrades.Approve`.
    public shared ({ caller }) func approveRollout(name : UpgradesAPI.WasmName, version : UpgradesAPI.Version) : async Result<UpgradesAPI.Rollout, UpgradesAPI.ApproveError> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesApprove)) {
            return #err(#Unauthorized);
        };
        let result = await UpgradesAPI.approveRollout(upgradesDeps<system>(), name, version);
        switch (result) {
            case (#ok(_)) ignore HistoryAPI.record(history, caller, null, #rolloutApproved({ name; version }));
            case (#err(_)) {};
        };
        result;
    };

    /// Allows (`eligible = true`) or stops a registered shop's shop and vault being the canary of a
    /// new version (BRE-147). Mark test shops, not merchants' live ones. Rollouts that already have a
    /// canary keep it. Needs `Upgrades.Run`.
    public shared ({ caller }) func setCanaryEligible(shopId : Principal, eligible : Bool) : async Result<(), { #Unauthorized; #NotFound; #SelfManaged }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesRun)) {
            return #err(#Unauthorized);
        };
        if (eligible) {
            if (not isShopCanister(shopId)) {
                return #err(#NotFound);
            };
            if (selfManaged(shopId)) {
                return #err(#SelfManaged);
            };
        };
        UpgradesAPI.setCanaryEligible(upgradesState, shopId, eligible);
        ignore HistoryAPI.record(history, caller, ?shopId, #canaryEligibilitySet({ eligible }));
        #ok;
    };

    /// The registered shops whose shop or vault may be a new version's canary. Needs `Upgrades.View`.
    public query ({ caller }) func listCanaryShops() : async Result<[Principal], { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesView)) {
            return #err(#Unauthorized);
        };
        #ok(UpgradesAPI.listCanaryShops(upgradesState, isShopCanister));
    };

    /// Every wasm version core has upgraded a canister to, with its canary and whether it's approved.
    /// Needs `Upgrades.View`.
    public query ({ caller }) func listRollouts() : async Result<[UpgradesAPI.Rollout], { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesView)) {
            return #err(#Unauthorized);
        };
        #ok(UpgradesAPI.listRollouts(upgradesState));
    };

    /// Loads core's snapshot of a shop or vault, taken just before its last upgrade: its wasm and
    /// state go back to how they were then, and anything recorded since is lost. For an upgrade
    /// that broke the canister. Needs `Upgrades.Run`.
    public shared ({ caller }) func restoreSnapshot(canisterId : Principal) : async Result<(), UpgradesAPI.RestoreError> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesRun)) {
            return #err(#Unauthorized);
        };
        if (not isShopOrVault(canisterId)) {
            return #err(#NotFound);
        };
        if (selfManaged(canisterId)) {
            return #err(#SelfManaged);
        };
        let result = await UpgradesAPI.restore(upgradesDeps<system>(), canisterId);
        // Refusals that changed nothing (busy, no snapshot) aren't history.
        let reachedCanister = switch (result) {
            case (#ok or #err(#StopFailed(_) or #RestoreFailed(_) or #StartFailed(_))) true;
            case (#err(_)) false;
        };
        if (reachedCanister) ignore HistoryAPI.record(history, caller, shopOf(canisterId), #snapshotRestored({ canister = canisterId; outcome = HistoryAPI.outcome(result, func e = debug_show e) }));
        result;
    };

    /// Starts a shop or vault that an upgrade or restore left stopped (it returned `#StartFailed`).
    /// Needs `Upgrades.Run`.
    public shared ({ caller }) func startCanister(canisterId : Principal) : async Result<(), UpgradesAPI.StartError> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesRun)) {
            return #err(#Unauthorized);
        };
        if (not isShopOrVault(canisterId)) {
            return #err(#NotFound);
        };
        if (selfManaged(canisterId)) {
            return #err(#SelfManaged);
        };
        let result = await UpgradesAPI.startCanister(upgradesDeps<system>(), canisterId);
        let reachedCanister = switch (result) {
            case (#ok or #err(#StartFailed(_))) true;
            case (#err(_)) false;
        };
        if (reachedCanister) ignore HistoryAPI.record(history, caller, shopOf(canisterId), #canisterStarted({ canister = canisterId; outcome = HistoryAPI.outcome(result, func e = debug_show e) }));
        result;
    };
};
