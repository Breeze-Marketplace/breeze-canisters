import { expect } "mo:test";
import { test; suite } "mo:test/async";

import Error "mo:core/Error";
import List "mo:core/List";
import Principal "mo:core/Principal";

import CanisterCycles "../CanisterCycles";

let canisterId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");

// Operations that report `balance` for the pooled canister and `own` for the caller, and record
// each deposit. `failStatus`/`failDeposit` make those calls throw.
func makeOperations(
    balance : Nat,
    own : Nat,
    failStatus : Bool,
    failDeposit : Bool,
) : {
    ops : CanisterCycles.Operations;
    deposits : List.List<(Principal, Nat)>;
} {
    let deposits = List.empty<(Principal, Nat)>();
    let ops : CanisterCycles.Operations = {
        canisterBalance = func(_ : Principal) : async Nat {
            if (failStatus) { throw Error.reject("not a controller") };
            balance;
        };
        depositCycles = func(id : Principal, amount : Nat) : async () {
            if (failDeposit) { throw Error.reject("deposit rejected") };
            List.add(deposits, (id, amount));
        };
        ownBalance = func() : Nat { own };
    };
    { ops; deposits };
};

await suite(
    "CanisterCycles",
    func() : async () {
        await test(
            "reuseCycles leaves a new canister's balance after the largest creation fee",
            func() : async () {
                expect.nat(CanisterCycles.reuseCycles).equal(CanisterCycles.createCanisterCycles - 1_300_000_000_000);
            },
        );

        await test(
            "topUpAmount fills the gap to reuseCycles",
            func() : async () {
                expect.nat(CanisterCycles.topUpAmount(0)).equal(CanisterCycles.reuseCycles);
                expect.nat(CanisterCycles.topUpAmount(200_000_000_000)).equal(1_500_000_000_000);
                expect.nat(CanisterCycles.topUpAmount(CanisterCycles.reuseCycles)).equal(0);
                expect.nat(CanisterCycles.topUpAmount(5_000_000_000_000)).equal(0);
            },
        );

        await test(
            "does not top up a canister that can cover a reinstall",
            func() : async () {
                let m = makeOperations(2_000_000_000_000, 10_000_000_000_000, false, false);
                let res = await CanisterCycles.ensureReuseBalance(canisterId, m.ops);
                assert (res == #ok(0));
                expect.nat(List.size(m.deposits)).equal(0);
            },
        );

        await test(
            "tops up a drained canister to reuseCycles",
            func() : async () {
                let m = makeOperations(100_000_000_000, 10_000_000_000_000, false, false);
                let res = await CanisterCycles.ensureReuseBalance(canisterId, m.ops);
                assert (res == #ok(1_600_000_000_000));
                expect.nat(List.size(m.deposits)).equal(1);
                let ?(id, amount) = List.get(m.deposits, 0) else {
                    assert false;
                    return;
                };
                expect.principal(id).equal(canisterId);
                expect.nat(amount).equal(1_600_000_000_000);
            },
        );

        await test(
            "returns InsufficientCycles without depositing when the caller can't afford the top-up",
            func() : async () {
                let m = makeOperations(100_000_000_000, 1_000_000_000_000, false, false);
                let res = await CanisterCycles.ensureReuseBalance(canisterId, m.ops);
                switch (res) {
                    case (#err(#InsufficientCycles(_))) {};
                    case (_) { assert false };
                };
                expect.nat(List.size(m.deposits)).equal(0);
            },
        );

        await test(
            "returns StatusUnavailable when canister_status fails",
            func() : async () {
                let m = makeOperations(0, 10_000_000_000_000, true, false);
                let res = await CanisterCycles.ensureReuseBalance(canisterId, m.ops);
                switch (res) {
                    case (#err(#StatusUnavailable(_))) {};
                    case (_) { assert false };
                };
                expect.nat(List.size(m.deposits)).equal(0);
            },
        );

        await test(
            "returns TopUpFailed when deposit_cycles fails",
            func() : async () {
                let m = makeOperations(0, 10_000_000_000_000, false, true);
                let res = await CanisterCycles.ensureReuseBalance(canisterId, m.ops);
                switch (res) {
                    case (#err(#TopUpFailed(_))) {};
                    case (_) { assert false };
                };
            },
        );
    },
);
