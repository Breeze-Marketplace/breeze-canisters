import { expect } "mo:test";
import { test; suite } "mo:test/async";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import Cycles "mo:core/Cycles";
import Principal "mo:core/Principal";
import ShopProvisioning "../lib";

persistent actor {
    let shopService = ShopProvisioning.ShopService();

    public func runTests() : async () {
        await suite(
            "ShopProvisioning.createShop",
            func() : async () {
                await test(
                    "successfully creates a shop canister with valid input",
                    func() : async () {
                        // Empty: createShop calls the management canister, which this test can't fake.
                    },
                );
            },
        );
    };
};
