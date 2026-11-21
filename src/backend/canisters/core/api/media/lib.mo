import Blob "mo:core/Blob";
import Error "mo:core/Error";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Text "mo:core/Text";

import CanisterCycles "../../../../lib/CanisterCycles";
import Logger "../../../../lib/Logger";
import Management "../../../../interfaces/management";
import WasmVersion "../../../../lib/WasmVersion";

import { type ReleaseCanisterFunction } "../canister_management";

module {
    type CanisterFactoryInterface = {
        getWasm : (WasmVersion.WasmName, WasmVersion.Version) -> async Result<{ wasm : Blob; sha256 : Blob }, { #NotFound; #Yanked }>;
        createCanister : (?Management.CanisterSettings) -> async Result<{ canisterId : Principal; isNewCanister : Bool }, { #Unauthorized : Text }>;
        addCanisterToPool : (Principal) -> async Result<(), { #Unauthorized : Text }>;
    };

    public type CreateMediaCanisterError = {
        #Unauthorized;
        /// The factory has no such vault version, or it is yanked, or no vault version is current.
        #WasmNotFound;
        #InsufficientCycles : Text;
        #FailedToCreate : Text;
    };

    public type CreateMediaCanisterResponse = Result<Principal, CreateMediaCanisterError>;

    public type Dependencies = {
        logger : Logger.BoundLogger;
        canisterFactory : CanisterFactoryInterface;
        releaseCanister : ReleaseCanisterFunction;
        backendController : Principal;
        cycles : CanisterCycles.Operations;
    };

    /// Creates a vault running the vault wasm `version` (core's current vault version, BRE-85).
    public func createMediaCanister(
        caller : Principal,
        dependencies : Dependencies,
        version : WasmVersion.Version,
    ) : async CreateMediaCanisterResponse {
        let {
            logger;
            canisterFactory;
            releaseCanister;
            backendController;
            cycles;
        } = dependencies;

        let wasm = switch (await canisterFactory.getWasm(#vault, version)) {
            case (#ok(w)) { w.wasm };
            case (#err(#NotFound or #Yanked)) {
                return #err(#WasmNotFound);
            };
        };

        let controllers = [backendController];
        let canisterSettings : Management.CanisterSettings = {
            controllers = ?controllers;
            compute_allocation = null;
            memory_allocation = null;
            freezing_threshold = ?2_592_000;
        };
        let res = await canisterFactory.createCanister(?canisterSettings);
        let { canisterId; isNewCanister } = switch (res) {
            case (#ok(c)) { c };
            case (#err(#Unauthorized(_msg))) {
                return #err(#Unauthorized);
            };
        };

        // A pooled canister keeps whatever cycles it had when it was released, so check and top it up
        // before reinstalling. New canisters come funded by canister_factory (createCanisterCycles).
        if (not isNewCanister) {
            switch (await CanisterCycles.ensureReuseBalance(canisterId, cycles)) {
                case (#ok(deposited)) {
                    if (deposited > 0) {
                        logger.info("Topped up pooled media canister " # Principal.toText(canisterId) # " with " # debug_show (deposited) # " cycles");
                    };
                };
                case (#err(#InsufficientCycles(msg))) {
                    // Core is short, not the canister: return it to the pool for a later attempt.
                    await releaseCanister(canisterId, { logger; canisterFactory });
                    return #err(#InsufficientCycles(msg));
                };
                case (#err(#StatusUnavailable(msg) or #TopUpFailed(msg))) {
                    // Core can't check or fund this canister, so it would fail every reinstall.
                    // Leave it out of the pool rather than returning it.
                    logger.warning("Dropping pooled media canister " # Principal.toText(canisterId) # " from the pool: " # msg);
                    return #err(#FailedToCreate("Failed to create Media canister: " # msg));
                };
            };
        };

        try {
            let ic = Management.getManagementCanister();

            switch (isNewCanister) {
                case (true) {
                    await ic.install_code({
                        mode = #install;
                        canister_id = canisterId;
                        wasm_module = wasm;
                        arg = to_candid ();
                    });

                };
                case (false) {
                    await ic.install_code({
                        mode = #reinstall;
                        canister_id = canisterId;
                        wasm_module = wasm;
                        arg = to_candid ();
                    });

                    ic.update_settings({
                        canister_id = canisterId;
                        settings = canisterSettings;
                        sender_canister_version = null;
                    });

                };
            };
        } catch (err) {
            await releaseCanister(
                canisterId,
                {
                    logger;
                    canisterFactory;
                },
            );
            return #err(#FailedToCreate("Failed to create Media canister: " # debug_show (Error.message(err))));
        };

        let canister = actor (Principal.toText(canisterId)) : actor {
            authorize : (Principal) -> async ();
            setShopCanisterId : (Principal) -> async ();
            setHmacSecretKey : (Blob) -> async ();
        };

        await canister.authorize(caller);

        return #ok(canisterId);
    };
};
