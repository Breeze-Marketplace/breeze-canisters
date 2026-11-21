import { expect; suite; test } "mo:test";

import DeliveryToken "../../../lib/DeliveryToken";
import Initial "../migrations/20261101_000000";
import GroupProfileAndMedia "../migrations/20261102_120000";

// The constant the first migration installed. Public in the repository, so nothing may sign or
// check tickets with it (BRE-55).
let placeholder : Blob = "\01\02\03\04";

suite(
    "Shop HMAC secret key (BRE-55)",
    func() {
        test(
            "the placeholder key and the empty key core passes are not usable",
            func() {
                expect.bool(DeliveryToken.isUsableKey(placeholder)).isFalse();
                expect.bool(DeliveryToken.isUsableKey("")).isFalse();
                expect.bool(DeliveryToken.isUsableKey("0123456789abcdef")).isTrue();
            },
        );
        test(
            "the migration chain leaves no usable key, so main.mo draws one from raw_rand",
            func() {
                let installed = GroupProfileAndMedia.migration(Initial.migration({}));
                expect.bool(DeliveryToken.isUsableKey(installed.media.hmacSecretKey)).isFalse();
            },
        );
    },
);
