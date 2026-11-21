import { expect } "mo:test";
import { suite; test } "mo:test";

import Decimals "../Decimals";

suite(
    "Decimals.rescale",
    func() {
        test(
            "adds digits exactly",
            func() {
                // 1.50 USD (2 decimals) as 6 decimals.
                expect.nat(Decimals.rescale(150, 2, 6)).equal(1_500_000);
            },
        );
        test(
            "drops digits by rounding down",
            func() {
                expect.nat(Decimals.rescale(123_456_789, 10, 8)).equal(1_234_567);
                expect.nat(Decimals.rescale(99, 2, 0)).equal(0);
            },
        );
        test(
            "is a no-op for equal decimals",
            func() {
                expect.nat(Decimals.rescale(42, 8, 8)).equal(42);
            },
        );
    },
);

suite(
    "Decimals.compare",
    func() {
        test(
            "compares across decimals without rounding",
            func() {
                // 5 USDC as 6 decimals vs 5.00 as 2 decimals.
                expect.bool(Decimals.compare(5_000_000, 6, 500, 2) == #equal).isTrue();
                expect.bool(Decimals.compare(4_999_999, 6, 500, 2) == #less).isTrue();
                expect.bool(Decimals.compare(5, 0, 499, 2) == #greater).isTrue();
            },
        );
        test(
            "a fraction below the coarser side's precision still counts",
            func() {
                // 1.000000001 (9 decimals) is more than 1.00000000 (8 decimals).
                expect.bool(Decimals.compare(1_000_000_001, 9, 100_000_000, 8) == #greater).isTrue();
            },
        );
    },
);
