import Cycles "mo:core/Cycles";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import List "mo:core/List";
import Text "mo:base/Text";
import Debug "mo:base/Debug";

import CanisterCycles "../../../../lib/CanisterCycles";
import Management "../../../../interfaces/management";

import ShopInterface "../../../../interfaces/shop";

module ShopProvisioning {
    type ShopInitArgs = {
        name : Text;
        description : Text;
        hmacSecretKey : Blob;
    };

    public class ShopService() {};

    public type CreateShopError = {
        /// Core can't spare the cycles to top up a pooled canister. The canister is fine to pool again.
        #InsufficientCycles : Text;
        /// A pooled canister can't be checked or topped up, so it shouldn't go back to the pool.
        #UnusableCanister : Text;
    };

    public type CreateShopResponse = Result.Result<(canisterId : Principal), CreateShopError>;
    public type CreateShopFunction = (
        caller : Principal,
        wasm : Blob,
        canister : {
            canisterId : Principal;
            isNewCanister : Bool;
        },
        args : {
            controllers : [Principal];
            details : {
                name : Text;
                description : Text;
            };
        },
    ) -> async CreateShopResponse;

    /// Installs `wasm` into `canister` (topping up and reinstalling a pooled one) and makes `caller`
    /// the shop's owner.
    public func createShop(
        caller : Principal,
        wasm : Blob,
        canister : {
            canisterId : Principal;
            isNewCanister : Bool;
        },
        args : {
            controllers : [Principal];
            details : {
                name : Text;
                description : Text;
            };
        },
    ) : async CreateShopResponse {
        let initArgs : ShopInitArgs = {
            name = args.details.name;
            description = args.details.description;
            // Shop wasms before the arg was dropped still require it to decode; current ones ignore
            // it. Empty, so those older shops draw their own delivery key from `raw_rand` (BRE-55).
            hmacSecretKey = "";
        };

        let FREEZING_THRESHOLD_SECONDS = 30 * 24 * 60 * 60;

        let canisterSettings : Management.CanisterSettings = {
            controllers = ?args.controllers;
            compute_allocation = null;
            memory_allocation = null;
            freezing_threshold = ?FREEZING_THRESHOLD_SECONDS;
        };

        let ic = Management.getManagementCanister();
        let { canisterId; isNewCanister } = canister;

        switch (isNewCanister) {
            case (true) {
                await ic.install_code({
                    mode = #install;
                    canister_id = canisterId;
                    wasm_module = wasm;
                    arg = to_candid (initArgs);
                });
            };
            case (false) {
                // A pooled canister keeps whatever cycles it had when it was released, so check and
                // top it up before reinstalling. New canisters come funded by canister_factory.
                switch (await CanisterCycles.ensureReuseBalance(canisterId, CanisterCycles.managementOperations())) {
                    case (#ok(deposited)) {
                        if (deposited > 0) {
                            Debug.print("Topped up pooled shop canister " # Principal.toText(canisterId) # " with " # debug_show (deposited) # " cycles");
                        };
                    };
                    case (#err(#InsufficientCycles(msg))) {
                        return #err(#InsufficientCycles(msg));
                    };
                    case (#err(#StatusUnavailable(msg) or #TopUpFailed(msg))) {
                        return #err(#UnusableCanister(msg));
                    };
                };

                await ic.install_code({
                    mode = #reinstall;
                    canister_id = canisterId;
                    wasm_module = wasm;
                    arg = to_candid (initArgs);
                });

                ic.update_settings({
                    canister_id = canisterId;
                    settings = canisterSettings;
                    sender_canister_version = null;
                });

            };
        };

        let shop = actor (Principal.toText(canisterId)) : ShopInterface.Shop;

        // This should happen last so that the media canister ID is set before the owner is reassigned.
        let setOwnerRes = await shop.setOwner(caller);
        switch (setOwnerRes) {
            case (#ok()) {
                Debug.print("Successfully set owner for shop: " # Principal.toText(canisterId));
            };
            case (#err(err)) {
                Debug.print("Failed to set owner for shop: " # Principal.toText(canisterId) # ": " # debug_show (err));
            };
        };

        return #ok(canisterId);
    };
};
