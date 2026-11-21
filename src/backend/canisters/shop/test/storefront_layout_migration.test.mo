import { expect; suite; test } "mo:test";

import Migration "../migrations/20261119_095956_StorefrontLayout";

let theme = {
    primary = { red = 194 : Nat8; green = 248 : Nat8; blue = 61 : Nat8 };
    onPrimary = #dark;
    accent = { red = 220 : Nat8; green = 255 : Nat8; blue = 120 : Nat8 };
    onAccent = #dark;
    fonts = #grotesk;
    shape = #rounded;
    colorScheme = #light;
    hero = #split;
};

suite(
    "StorefrontLayout migration",
    func() {
        test(
            "keeps the theme and starts with no draft, no published layout and revision 0",
            func() {
                let next = Migration.migration({
                    storefront = { var theme = ?theme };
                });
                expect.bool(next.storefront.theme == ?theme).isTrue();
                expect.bool(next.storefront.draft == null).isTrue();
                expect.bool(next.storefront.published == null).isTrue();
                expect.nat(next.storefront.revision).equal(0);
            },
        );
        test(
            "a shop with no theme stays without one",
            func() {
                let next = Migration.migration({
                    storefront = { var theme = null };
                });
                expect.bool(next.storefront.theme == null).isTrue();
            },
        );
    },
);
