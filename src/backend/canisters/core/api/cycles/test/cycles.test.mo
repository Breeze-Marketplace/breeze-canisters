import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Array "mo:core/Array";
import Error "mo:core/Error";
import Principal "mo:core/Principal";

import CyclesAPI "../lib";

let core = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let productIndex = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
// A sibling core isn't a status viewer of: canister_status fails.
let frontend = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");

let canisters : [(CyclesAPI.CanisterKind, Principal)] = [(#core, core), (#productIndex, productIndex), (#frontend, frontend)];

func mockOps(viewsCore : Bool) : CyclesAPI.Operations {
    {
        canisterStatus = func(id : Principal) : async* CyclesAPI.RawStatus {
            if (id == frontend or (id == core and not viewsCore)) {
                throw Error.reject("Only controllers of canister " # Principal.toText(id) # " can call canister_status");
            };
            // 1T a day for 30 days: a 1T * 30 freezing threshold.
            {
                cycles = 50_000_000_000_000;
                idleCyclesBurnedPerDay = 1_000_000_000_000;
                freezingThresholdSeconds = 2_592_000;
            };
        };
        ownBalance = func() : Nat { 7 };
    };
};

suite(
    "CyclesAPI",
    func() : async () {
        await test(
            "the freezing threshold is the idle burn for the threshold duration",
            func() : async () {
                expect.nat(CyclesAPI.freezingThresholdCycles(1_000_000_000_000, 2_592_000)).equal(30_000_000_000_000);
                expect.nat(CyclesAPI.freezingThresholdCycles(86_400, 1)).equal(1);
                expect.nat(CyclesAPI.freezingThresholdCycles(0, 2_592_000)).equal(0);
            },
        );

        await test(
            "lists each canister in order with its cycles and freezing threshold",
            func() : async () {
                let rows = await* CyclesAPI.list(mockOps(true), canisters);
                expect.bool(Array.map<CyclesAPI.CanisterCycles, Principal>(rows, func(row) = row.canisterId) == [core, productIndex, frontend]).isTrue();
                expect.bool(rows[1].kind == #productIndex).isTrue();
                switch (rows[1].status) {
                    case (#ok(status)) {
                        expect.nat(status.cycles).equal(50_000_000_000_000);
                        switch (status.freezing) {
                            case (?f) {
                                expect.nat(f.thresholdCycles).equal(30_000_000_000_000);
                            };
                            case null { assert false };
                        };
                    };
                    case (#err(_)) { assert false };
                };
            },
        );

        await test(
            "a canister core can't read gets an error row; core falls back to its own balance",
            func() : async () {
                let rows = await* CyclesAPI.list(mockOps(false), canisters);
                switch (rows[0].status) {
                    case (#ok(status)) {
                        expect.nat(status.cycles).equal(7);
                        expect.bool(status.freezing == null).isTrue();
                    };
                    case (#err(_)) { assert false };
                };
                switch (rows[2].status) {
                    case (#err(msg)) {
                        expect.text(msg).contains("Only controllers");
                    };
                    case (#ok(_)) { assert false };
                };
            },
        );
    },
);
