import { expect; suite; test } "mo:test";

import ShopFees "../../../../../lib/ShopCallFees";
import ShopCallFeesAPI "../lib";

suite(
    "ShopCallFees.required",
    func() {
        test(
            "charges nothing while the fees aren't enforced",
            func() {
                let state = ShopCallFeesAPI.newState();
                expect.nat(ShopCallFeesAPI.required(state)).equal(0);
            },
        );
        test(
            "charges every caller the event fee once enforced",
            func() {
                let state = ShopCallFeesAPI.newState();
                state.enforced := true;
                expect.nat(ShopCallFeesAPI.required(state)).equal(ShopFees.EVENT_CYCLES);
            },
        );
    },
);
