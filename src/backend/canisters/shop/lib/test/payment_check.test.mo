import { expect; suite; test } "mo:test";

import PaymentCheck "../payment_check";

let second : Int = 1_000_000_000;
let t0 : Int = 1_700_000_000 * second;

func isRead(d : PaymentCheck.Decision) : Bool {
    switch (d) { case (#read) true; case (#recent(_)) false };
};

func recentBalance(d : PaymentCheck.Decision) : ??Nat {
    switch (d) { case (#read) null; case (#recent(b)) ?b };
};

suite(
    "PaymentCheck",
    func() {
        test(
            "the first check of an order reads the ledger",
            func() {
                let state = PaymentCheck.empty();
                expect.bool(isRead(PaymentCheck.begin(state, 1, t0))).isTrue();
            },
        );

        test(
            "a second check inside the cooldown does not read the ledger",
            func() {
                let state = PaymentCheck.empty();
                ignore PaymentCheck.begin(state, 1, t0);
                expect.bool(isRead(PaymentCheck.begin(state, 1, t0 + 1 * second))).isFalse();
                expect.bool(isRead(PaymentCheck.begin(state, 1, t0 + PaymentCheck.COOLDOWN_NANOS - 1))).isFalse();
            },
        );

        test(
            "a check while the read is still in flight gets no balance",
            func() {
                let state = PaymentCheck.empty();
                ignore PaymentCheck.begin(state, 1, t0);
                expect.bool(recentBalance(PaymentCheck.begin(state, 1, t0 + second)) == ?null).isTrue();
            },
        );

        test(
            "a check inside the cooldown gets the last read's balance",
            func() {
                let state = PaymentCheck.empty();
                ignore PaymentCheck.begin(state, 1, t0);
                PaymentCheck.record(state, 1, t0, 42);
                expect.bool(recentBalance(PaymentCheck.begin(state, 1, t0 + second)) == ??42).isTrue();
            },
        );

        test(
            "the ledger is read again once the cooldown has passed",
            func() {
                let state = PaymentCheck.empty();
                ignore PaymentCheck.begin(state, 1, t0);
                PaymentCheck.record(state, 1, t0, 42);
                expect.bool(isRead(PaymentCheck.begin(state, 1, t0 + PaymentCheck.COOLDOWN_NANOS))).isTrue();
            },
        );

        test(
            "repeated checks make one ledger read per cooldown",
            func() {
                let state = PaymentCheck.empty();
                var reads = 0;
                var now = t0;
                // One check every 100 ms for 20 seconds.
                while (now < t0 + 20 * second) {
                    if (isRead(PaymentCheck.begin(state, 1, now))) {
                        reads += 1;
                    };
                    now += second / 10;
                };
                expect.nat(reads).equal(4);
            },
        );

        test(
            "the limit is per order",
            func() {
                let state = PaymentCheck.empty();
                ignore PaymentCheck.begin(state, 1, t0);
                expect.bool(isRead(PaymentCheck.begin(state, 2, t0))).isTrue();
                expect.bool(isRead(PaymentCheck.begin(state, 1, t0))).isFalse();
            },
        );

        test(
            "a stale read's balance is not recorded over a newer read",
            func() {
                let state = PaymentCheck.empty();
                ignore PaymentCheck.begin(state, 1, t0);
                let later = t0 + PaymentCheck.COOLDOWN_NANOS;
                ignore PaymentCheck.begin(state, 1, later);
                PaymentCheck.record(state, 1, t0, 7);
                expect.bool(recentBalance(PaymentCheck.begin(state, 1, later + 1)) == ?null).isTrue();
            },
        );

        test(
            "a forgotten order is read again at once",
            func() {
                let state = PaymentCheck.empty();
                ignore PaymentCheck.begin(state, 1, t0);
                PaymentCheck.forget(state, 1);
                expect.bool(isRead(PaymentCheck.begin(state, 1, t0 + 1))).isTrue();
            },
        );
    },
);
