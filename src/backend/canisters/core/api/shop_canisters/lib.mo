import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Error "mo:core/Error";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Text "mo:core/Text";
import Time "mo:core/Time";
import CoreSet "mo:core/Set";
import Map "mo:map/Map";

import Hex "../../../../lib/Hex";
import Logger "../../../../lib/Logger";
import WasmVersion "../../../../lib/WasmVersion";
import Pagination "../../../../lib/Pagination";
import HandoverAPI "../handover";
import ShopAPI "../shop";

/// What core knows about the canisters behind each shop, for the admin shop registry (BRE-26): the
/// wasm version core last installed on each shop and vault, and each shop's vault.
module {
    /// The wasm core last installed on a canister (BRE-85).
    public type InstalledWasm = {
        version : WasmVersion.Version;
        /// The canister's module hash, as core read it right after installing. It equals the
        /// factory's SHA-256 of `version` unless the install went wrong (core logs an error then).
        /// Null: core couldn't read it, or installed before hashes were recorded.
        sha256 : ?Blob;
    };

    public type State = {
        /// The wasm core last installed on a shop or vault canister, by canister ID. A canister core
        /// installed before versions were recorded, or never installed (a shop registered with
        /// `registerShop`), has no entry.
        wasmVersions : Map.Map<Principal, InstalledWasm>;
        /// The vault core created for a shop, by shop canister ID. Shops created before this was
        /// recorded, and registered shops, have no entry.
        vaultsByShop : Map.Map<Principal, Principal>;
    };

    public type AdminShopInfo = {
        canisterId : Principal;
        name : Text;
        /// The shop's current URL slug (BRE-71).
        slug : Text;
        owner : Principal;
        registrationDate : Time.Time;
        /// Null when core doesn't know the shop's vault (see `State.vaultsByShop`).
        vaultId : ?Principal;
        /// Null when the version is unknown (see `State.wasmVersions`).
        shopVersion : ?InstalledWasm;
        vaultVersion : ?InstalledWasm;
        /// Whether core or the merchant controls the shop and vault (BRE-79).
        control : HandoverAPI.ControlStatus;
    };

    /// Where a `listShopRegistry` page ends: rows are ordered by name, then canister ID.
    public type RegistryCursor = ShopAPI.ShopNameKey;

    public func registryCursor(row : AdminShopInfo) : RegistryCursor {
        { name = row.name; canisterId = row.canisterId };
    };

    public func compareRegistryCursor(a : RegistryCursor, b : RegistryCursor) : {
        #less;
        #equal;
        #greater;
    } {
        ShopAPI.compareShopNameKey(a, b);
    };

    /// Records the wasm `canisterId` runs, on creation, upgrade or restore.
    public func recordInstall(state : State, canisterId : Principal, installed : InstalledWasm) {
        Map.set(state.wasmVersions, Map.phash, canisterId, installed);
    };

    /// Reads `canisterId`'s module hash after core installed `name`'s `version` on it, checks it
    /// against `expected` (the factory's SHA-256 of that version), and records both. A mismatch, or
    /// a hash core can't read, is logged as an error: the install itself already happened.
    public func verifyInstall(
        state : State,
        canisterId : Principal,
        name : WasmVersion.WasmName,
        version : WasmVersion.Version,
        expected : Blob,
        moduleHash : (Principal) -> async ?Blob,
        logger : Logger.BoundLogger,
    ) : async* () {
        let target = WasmVersion.key(name, version) # " on " # Principal.toText(canisterId);
        let actual = try { await moduleHash(canisterId) } catch (e) {
            logger.error("Couldn't read the module hash after installing " # target # ": " # Error.message(e));
            null;
        };
        switch (actual) {
            case (?hash) {
                if (hash != expected) {
                    logger.error("Module hash mismatch after installing " # target # ": the canister runs " # hex(hash) # ", the factory's hash is " # hex(expected));
                };
            };
            case (null) {
                logger.error("No module hash after installing " # target);
            };
        };
        recordInstall(state, canisterId, { version; sha256 = actual });
    };

    func hex(b : Blob) : Text {
        Hex.encode(Blob.toArray(b));
    };

    /// Forgets the version recorded for `canisterId`: core no longer knows what it runs.
    public func forgetVersion(state : State, canisterId : Principal) {
        Map.delete(state.wasmVersions, Map.phash, canisterId);
    };

    /// Whether core recorded `canisterId` as a shop's vault.
    public func isVault(state : State, canisterId : Principal) : Bool {
        Option.isSome(shopOfVault(state, canisterId));
    };

    /// The shop whose vault core recorded as `vaultId`, if any.
    public func shopOfVault(state : State, vaultId : Principal) : ?Principal {
        for ((shopId, v) in Map.entries(state.vaultsByShop)) {
            if (v == vaultId) { return ?shopId };
        };
        null;
    };

    public func linkVault(state : State, shopId : Principal, vaultId : Principal) {
        Map.set(state.vaultsByShop, Map.phash, shopId, vaultId);
    };

    public type LinkShopVaultError = { #NotFound };

    /// Records the vault of a registered shop core didn't record one for, as the shop reports it
    /// (`getMediaCanisterId`). Returns the shop's vault, or null if it has none. A vault core already
    /// recorded is returned without asking the shop.
    public func linkShopVault(
        state : State,
        shopRegistry : Map.Map<Principal, ShopAPI.ShopRegistryItem>,
        shopId : Principal,
        getMediaCanisterId : (Principal) -> async ?Principal,
    ) : async Result<?Principal, LinkShopVaultError> {
        if (not Map.has(shopRegistry, Map.phash, shopId)) {
            return #err(#NotFound);
        };
        switch (Map.get(state.vaultsByShop, Map.phash, shopId)) {
            case (?vaultId) {
                return #ok(?vaultId);
            };
            case (null) {};
        };
        let vaultId = await getMediaCanisterId(shopId);
        switch (vaultId) {
            case (?id) { linkVault(state, shopId, id) };
            case (null) {};
        };
        #ok(vaultId);
    };

    public type LinkRegisteredVaultHooks = {
        /// The vault the shop reports (`getMediaCanisterId`).
        getMediaCanisterId : (shopId : Principal) -> async ?Principal;
        /// The canister's controllers, read from its `canister_status`. Throws when they can't be read.
        getControllers : (canisterId : Principal) -> async [Principal];
    };

    /// After `registerShop`: records the vault a registered shop reports, but only if `owner`
    /// controls it too, since the shop names it itself and a recorded vault is one core upgrades.
    /// Best effort: a shop with no vault, one core can't read the controllers of, or one that is
    /// another shop's vault stays unlinked (an admin can still `linkShopVault`). Returns whether a
    /// vault is now recorded.
    public func linkRegisteredShopVault(
        state : State,
        shopId : Principal,
        owner : Principal,
        hooks : LinkRegisteredVaultHooks,
    ) : async Bool {
        if (Option.isSome(Map.get(state.vaultsByShop, Map.phash, shopId))) {
            return true;
        };
        try {
            let ?vaultId = await hooks.getMediaCanisterId(shopId) else {
                return false;
            };
            let controllers = await hooks.getControllers(vaultId);
            if (Option.isNull(Array.find(controllers, func(c : Principal) : Bool { c == owner }))) {
                return false;
            };
            // The awaits above let another call record a vault for this shop or claim this one.
            if (Option.isSome(Map.get(state.vaultsByShop, Map.phash, shopId)) or isVault(state, vaultId)) {
                return Option.isSome(Map.get(state.vaultsByShop, Map.phash, shopId));
            };
            linkVault(state, shopId, vaultId);
            true;
        } catch (_) { false };
    };

    public func wasmVersion(state : State, canisterId : Principal) : ?InstalledWasm {
        Map.get(state.wasmVersions, Map.phash, canisterId);
    };

    /// Registered shops with their vaults and wasm versions, a page at a time by name, read from
    /// `shopsByDisplayName` from the cursor (BRE-96).
    public func page(
        state : State,
        shopRegistry : Map.Map<Principal, ShopAPI.ShopRegistryItem>,
        shopsByDisplayName : CoreSet.Set<ShopAPI.ShopNameKey>,
        control : (Principal) -> HandoverAPI.ControlStatus,
        after : ?RegistryCursor,
        limit : ?Nat,
    ) : Pagination.Page<AdminShopInfo, RegistryCursor> {
        let keys = switch (after) {
            case (?a) {
                CoreSet.valuesFrom(shopsByDisplayName, compareRegistryCursor, a);
            };
            case null { CoreSet.values(shopsByDisplayName) };
        };
        Pagination.scan<RegistryCursor, AdminShopInfo, RegistryCursor>(
            keys,
            func k = k,
            compareRegistryCursor,
            after,
            func k = switch (Map.get(shopRegistry, Map.phash, k.canisterId)) {
                case (?item) {
                    let vaultId = Map.get(state.vaultsByShop, Map.phash, item.canisterId);
                    ?{
                        canisterId = item.canisterId;
                        name = item.shopDetails.name;
                        slug = item.slug;
                        owner = item.owner;
                        registrationDate = item.registrationDate;
                        vaultId;
                        shopVersion = wasmVersion(state, item.canisterId);
                        vaultVersion = switch (vaultId) {
                            case (?id) { wasmVersion(state, id) };
                            case (null) { null };
                        };
                        control = control(item.canisterId);
                    };
                };
                case null { null };
            },
            limit,
        );
    };
};
