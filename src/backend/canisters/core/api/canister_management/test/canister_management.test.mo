import { expect } "mo:test";
import { test; suite } "mo:test/async";

import List "mo:core/List";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import MockLogger "../../../../../lib/Logger/mock";

import CanisterManagementAPI "../lib";
import { mockCanisterFactory } "../mock";

suite(
    "releaseCanister",
    func() : async () {
        let canisterId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
        let logger = MockLogger.bind(MockLogger.new(Principal.fromText("aaaaa-aa")));

        await test(
            "adds canister to pool on success",
            func() : async () {
                let mockedFactory = mockCanisterFactory(null);
                await CanisterManagementAPI.releaseCanister(
                    canisterId,
                    {
                        logger;
                        canisterFactory = mockedFactory.canisterFactory;
                    },
                );

                expect.nat(List.size(mockedFactory.calls)).equal(1);

                let firstCall = Option.unwrap(List.get(mockedFactory.calls, 0));
                expect.principal(firstCall.canisterId).equal(canisterId);
            },
        );

        await test(
            "does not throw when addCanisterToPool returns unauthorized",
            func() : async () {
                func unauthorizedAddToPool(_ : Principal) : async Result<(), { #Unauthorized : Text }> {
                    #err(#Unauthorized("Access denied"));
                };
                let mockedFactory = mockCanisterFactory(?unauthorizedAddToPool);
                await CanisterManagementAPI.releaseCanister(
                    canisterId,
                    {
                        logger;
                        canisterFactory = mockedFactory.canisterFactory;
                    },
                );

                expect.nat(List.size(mockedFactory.calls)).equal(1);

                let firstCall = Option.unwrap(List.get(mockedFactory.calls, 0));
                expect.principal(firstCall.canisterId).equal(canisterId);
            },
        );
    },
);
