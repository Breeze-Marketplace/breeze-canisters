import { expect } "mo:test";
import { suite; test } "mo:test";

import Blob "mo:core/Blob";
import Principal "mo:core/Principal";

import Withdrawals "../withdrawals";

let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
let merchant = Principal.fromBlob(Blob.fromArray([1, 2, 3, 4]));

func isOk<T, E>(result : { #ok : T; #err : E }) : Bool {
    switch (result) {
        case (#ok(_)) true;
        case (#err(_)) false;
    };
};

func amount(result : { #ok : Nat; #err : Withdrawals.WithdrawError }) : ?Nat {
    switch (result) {
        case (#ok(n)) ?n;
        case (#err(_)) null;
    };
};

func isInsufficient(result : { #ok : Nat; #err : Withdrawals.WithdrawError }) : Bool {
    switch (result) {
        case (#err(#InsufficientFunds(_))) true;
        case _ false;
    };
};

func isInvalidAmount(result : { #ok : Nat; #err : Withdrawals.WithdrawError }) : Bool {
    switch (result) {
        case (#err(#InvalidAmount(_))) true;
        case _ false;
    };
};

suite(
    "Withdrawals.checkDestination",
    func() {
        test(
            "accepts another principal's account, with or without a 32-byte subaccount",
            func() {
                expect.bool(isOk(Withdrawals.checkDestination({ owner = merchant; subaccount = null }, shopId))).isTrue();
                let sub = Blob.fromArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7]);
                expect.bool(isOk(Withdrawals.checkDestination({ owner = merchant; subaccount = ?sub }, shopId))).isTrue();
            },
        );
        test(
            "refuses the shop's own accounts",
            func() {
                expect.bool(isOk(Withdrawals.checkDestination({ owner = shopId; subaccount = null }, shopId))).isFalse();
            },
        );
        test(
            "refuses the anonymous principal",
            func() {
                expect.bool(isOk(Withdrawals.checkDestination({ owner = Principal.anonymous(); subaccount = null }, shopId))).isFalse();
            },
        );
        test(
            "refuses a subaccount that isn't 32 bytes",
            func() {
                expect.bool(isOk(Withdrawals.checkDestination({ owner = merchant; subaccount = ?Blob.fromArray([1]) }, shopId))).isFalse();
            },
        );
    },
);

suite(
    "Withdrawals.amountToSend",
    func() {
        test(
            "everything is the balance minus the fee",
            func() {
                expect.bool(amount(Withdrawals.amountToSend(null, 1_000_000, 10_000)) == ?990_000).isTrue();
            },
        );
        test(
            "everything from a balance that doesn't cover the fee is refused",
            func() {
                expect.bool(isInsufficient(Withdrawals.amountToSend(null, 10_000, 10_000))).isTrue();
                expect.bool(isInsufficient(Withdrawals.amountToSend(null, 0, 10_000))).isTrue();
            },
        );
        test(
            "a given amount is sent when the balance covers it and the fee",
            func() {
                expect.bool(amount(Withdrawals.amountToSend(?990_000, 1_000_000, 10_000)) == ?990_000).isTrue();
                expect.bool(isInsufficient(Withdrawals.amountToSend(?990_001, 1_000_000, 10_000))).isTrue();
            },
        );
        test(
            "zero and amounts over nat64 are refused",
            func() {
                expect.bool(isInvalidAmount(Withdrawals.amountToSend(?0, 1_000_000, 10_000))).isTrue();
                expect.bool(isInvalidAmount(Withdrawals.amountToSend(?18_446_744_073_709_551_616, 1_000_000, 10_000))).isTrue();
            },
        );
    },
);

suite(
    "Withdrawals.createdAt",
    func() {
        test(
            "keeps the caller's timestamp, so a retry is a ledger duplicate",
            func() {
                expect.nat64(Withdrawals.createdAt(?42, 1_700_000_000_000_000_000)).equal(42);
            },
        );
        test(
            "defaults to now",
            func() {
                expect.nat64(Withdrawals.createdAt(null, 1_700_000_000_000_000_000)).equal(1_700_000_000_000_000_000);
            },
        );
    },
);
