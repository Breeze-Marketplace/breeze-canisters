import { expect; test; suite } "mo:test";

import Map "mo:core/Map";
import Principal "mo:core/Principal";

import RateLimit "../RateLimit";

let alice = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
let bob = Principal.fromText("2vxsx-fae");
let hour = 3_600_000_000_000;

suite(
    "RateLimit.PerCaller",
    func() {
        test(
            "limits each caller separately within a window",
            func() {
                let s = RateLimit.perCaller(3, hour);
                expect.bool(RateLimit.take(s, alice, 2, 10)).equal(true);
                expect.bool(RateLimit.take(s, alice, 2, 20)).equal(false);
                expect.nat(RateLimit.remaining(s, alice, 20)).equal(1);
                expect.bool(RateLimit.take(s, alice, 1, 20)).equal(true);
                expect.bool(RateLimit.take(s, alice, 1, 30)).equal(false);
                expect.nat(RateLimit.remaining(s, bob, 30)).equal(3);
            },
        );
        test(
            "a refused take spends nothing",
            func() {
                let s = RateLimit.perCaller(2, hour);
                expect.bool(RateLimit.take(s, alice, 3, 1)).equal(false);
                expect.nat(RateLimit.remaining(s, alice, 1)).equal(2);
            },
        );
        test(
            "the allowance returns after the window and old callers are swept",
            func() {
                let s = RateLimit.perCaller(1, hour);
                expect.bool(RateLimit.take(s, alice, 1, hour)).equal(true);
                expect.bool(RateLimit.take(s, alice, 1, hour + 5)).equal(false);
                expect.bool(RateLimit.take(s, bob, 1, 3 * hour)).equal(true);
                expect.nat(Map.size(s.windows)).equal(1);
                expect.bool(RateLimit.take(s, alice, 1, 3 * hour)).equal(true);
            },
        );
    },
);

suite(
    "RateLimit.Global",
    func() {
        test(
            "spends a shared budget and refills each window",
            func() {
                let s = RateLimit.global(2, hour);
                expect.bool(RateLimit.takeGlobal(s, hour)).equal(true);
                expect.bool(RateLimit.takeGlobal(s, hour + 1)).equal(true);
                expect.bool(RateLimit.takeGlobal(s, hour + 2)).equal(false);
                expect.bool(RateLimit.takeGlobal(s, 2 * hour)).equal(true);
            },
        );
    },
);
