import List "mo:core/List";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import { type ReleaseCanisterDependencies; type ReleaseCanisterFunction } "./lib";

module {
    public type MockedAddCanisterToPoolCall = {
        canisterId : Principal;
    };

    public func mockCanisterFactory(
        implementation : ?(Principal -> async Result<(), { #Unauthorized : Text }>)
    ) : {
        canisterFactory : {
            addCanisterToPool : (Principal) -> async Result<(), { #Unauthorized : Text }>;
        };
        calls : List.List<MockedAddCanisterToPoolCall>;
    } {
        let recordedCalls : List.List<MockedAddCanisterToPoolCall> = List.empty();
        let canisterFactory = {
            addCanisterToPool = func(canisterId : Principal) : async Result<(), { #Unauthorized : Text }> {
                List.add(recordedCalls, { canisterId });
                switch (implementation) {
                    case (?impl) { await impl(canisterId) };
                    case (null) { #ok() };
                };
            };
        };

        return {
            canisterFactory;
            calls = recordedCalls;
        };
    };

    public type MockedReleaseCanisterCall = {
        args : (Principal, ReleaseCanisterDependencies);
    };

    public func mockReleaseCanister() : {
        fn : ReleaseCanisterFunction;
        calls : List.List<MockedReleaseCanisterCall>;
    } {
        let recordedReleasedCanisterCalls : List.List<MockedReleaseCanisterCall> = List.empty();
        let releaseCanister = func(canisterId : Principal, dependencies : ReleaseCanisterDependencies) : async () {
            List.add(recordedReleasedCanisterCalls, { args = (canisterId, dependencies) });
        };

        return {
            fn = releaseCanister;
            calls = recordedReleasedCanisterCalls;
        };
    };

};
