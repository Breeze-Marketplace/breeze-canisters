import List "mo:core/List";
import Principal "mo:core/Principal";

import { type CreateShopFunction; type CreateShopResponse } "./lib";

module {
    public type MockedCreateShopCall = {
        args : (Principal, Blob, { canisterId : Principal; isNewCanister : Bool }, { controllers : [Principal]; details : { name : Text; description : Text } });
    };

    public func mockCreateShop(implementation : ?CreateShopFunction) : {
        fn : CreateShopFunction;
        calls : List.List<MockedCreateShopCall>;
    } {
        let recordedCalls : List.List<MockedCreateShopCall> = List.empty();
        let fn = func(
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
            List.add(recordedCalls, { args = (caller, wasm, canister, args) });
            switch (implementation) {
                case (?impl) { await impl(caller, wasm, canister, args) };
                case (null) {
                    #ok(Principal.fromText("aaaaa-aa"));
                };
            };
        };

        return {
            fn = fn;
            calls = recordedCalls;
        };
    };

    public func buildMockCreateShopImplementation(fn : () -> async CreateShopResponse) : CreateShopFunction {
        func(
            _ : Principal,
            _ : Blob,
            _ : {
                canisterId : Principal;
                isNewCanister : Bool;
            },
            _ : {
                controllers : [Principal];
                details : {
                    name : Text;
                    description : Text;
                };
            },
        ) : async CreateShopResponse {
            await fn();
        };
    };

};
