import { suite; test } "mo:test";

import DeliveryToken "../DeliveryToken";

suite(
    "DeliveryToken.normalizeAssetPath",
    func() {
        test(
            "adds a missing leading slash and keeps an existing one",
            func() {
                assert DeliveryToken.normalizeAssetPath("digital/3/7") == "/digital/3/7";
                assert DeliveryToken.normalizeAssetPath("/private/book.pdf") == "/private/book.pdf";
                assert DeliveryToken.normalizeAssetPath("") == "/";
            },
        );
    },
);
