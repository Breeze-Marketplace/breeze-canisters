import { expect } "mo:test";
import { suite; test } "mo:test";

import TimeUtil "../Time";

suite(
    "Time.remainingUntil",
    func() {
        let deadline : Int = 600_000_000_000;
        test(
            "counts down to the deadline",
            func() {
                expect.nat(TimeUtil.remainingUntil(deadline, 0)).equal(600_000_000_000);
                expect.nat(TimeUtil.remainingUntil(deadline, deadline - 1)).equal(1);
            },
        );
        test(
            "is zero at and after the deadline",
            func() {
                expect.nat(TimeUtil.remainingUntil(deadline, deadline)).equal(0);
                expect.nat(TimeUtil.remainingUntil(deadline, deadline + 5)).equal(0);
            },
        );
    },
);
