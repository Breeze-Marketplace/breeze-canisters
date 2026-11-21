import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Text "mo:core/Text";

import Logger "../../../../lib/Logger";

module {
    type CanisterFactoryInterface = {
        addCanisterToPool : (Principal) -> async Result<(), { #Unauthorized : Text }>;
    };

    public type ReleaseCanisterDependencies = {
        logger : Logger.BoundLogger;
        canisterFactory : CanisterFactoryInterface;
    };

    public type ReleaseCanisterFunction = (Principal, ReleaseCanisterDependencies) -> async ();

    public func releaseCanister(
        canisterId : Principal,
        dependencies : ReleaseCanisterDependencies,
    ) : async () {
        let { logger; canisterFactory } = dependencies;
        let res = await canisterFactory.addCanisterToPool(canisterId);
        switch (res) {
            case (#ok(_)) {
                logger.info("Released canister " # Principal.toText(canisterId) # " back to the pool");
            };
            case (#err(#Unauthorized(_))) {
                logger.warning("Failed to release canister " # Principal.toText(canisterId) # " due to unauthorized access");
            };
        };
    };
};
