import Cycles "mo:core/Cycles";
import Principal "mo:core/Principal";
import Result "mo:core/Result";

import Management "../../../../interfaces/management";

// Installs a user wasm rather than importing the `user` actor class: an imported class is
// compiled into core's wasm without its own migration chain (src/backend/canisters/user/migrations).
module UserProvisioning {
    type Input = {
        controllers : ?[Principal];
        owner : Principal;
        wasm : Blob;
    };
    type Output = Result.Result<Principal, { #AnonymousOwner; #InsufficientCycles : Text }>;

    public class UserService() {};

    public func createUser(_ : UserService, input : Input) : async Output {
        let { controllers; owner; wasm } = input;

        if (Principal.isAnonymous(owner)) {
            return #err(#AnonymousOwner);
        };

        let USER_FREEZING_THRESHOLD_SECONDS = 30 * 24 * 60 * 60;

        let initArgs = { owner };
        let settings = ?{
            controllers = controllers;
            compute_allocation = null;
            memory_allocation = null;
            freezing_threshold = ?USER_FREEZING_THRESHOLD_SECONDS;
        };

        let installCycles = 600_000_000_000;
        let canisterCreationFee = 500_000_000_000;
        let initialCyclesBalance = 500_000_000;
        let totalRequiredCycles = canisterCreationFee + installCycles + initialCyclesBalance;

        if (Cycles.balance() < totalRequiredCycles) {
            return #err(
                #InsufficientCycles(
                    "Not enough cycles to create User canister. Have "
                    # debug_show (Cycles.balance())
                    # " but need "
                    # debug_show (totalRequiredCycles)
                )
            );
        };

        let ic = Management.getManagementCanister();
        let {
            canister_id;
        } = await (with cycles = totalRequiredCycles) ic.create_canister({
            settings;
        });
        await ic.install_code({
            mode = #install;
            canister_id;
            wasm_module = wasm;
            arg = to_candid (initArgs);
        });

        #ok(canister_id);
    };

    public func upgradeUserCanister(
        _service : UserService,
        canisterId : Principal,
        wasm : Blob,
    ) : async () {
        let ic = Management.getManagementCanister();
        await ic.install_code({
            mode = #upgrade(?{ skip_pre_upgrade = null; wasm_memory_persistence = ?#keep });
            canister_id = canisterId;
            wasm_module = wasm;
            arg = to_candid ({
                owner = Principal.fromText("aaaaa-aa"); // ignored on upgrade, but the arg must decode
            });
        });
    };
};
