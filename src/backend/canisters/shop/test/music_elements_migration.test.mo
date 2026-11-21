import { expect; suite; test } "mo:test";

import Principal "mo:core/Principal";

import Migration "../migrations/20261120_151925_MusicElements";

let designer = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");

let theme = {
    primary = { red = 194 : Nat8; green = 248 : Nat8; blue = 61 : Nat8 };
    onPrimary = #dark;
    accent = { red = 220 : Nat8; green = 255 : Nat8; blue = 120 : Nat8 };
    onAccent = #dark;
    fonts = #grotesk;
    shape = #rounded;
    colorScheme = #light;
};

let layout = {
    theme = ?{ theme with density = #regular; buttonStyle = #solid };
    home = [{
        id = 1;
        background = #muted;
        padding = #medium;
        width = #contained;
        verticalAlign = #start;
        columns = [{
            span = 12;
            // One element: an array literal with two element kinds has no common type here.
            elements = [{
                id = 3;
                element = #products({
                    title = ?"All products";
                    source = #picked([4, 5] : [Nat32]);
                    sort = #manual;
                    limit = 2;
                    perRow = 2;
                    showCategoryFilter = false;
                });
            }];
        }];
    }];
    updatedAt = 1_700_000_000_000_000_000;
    updatedBy = designer;
};

suite(
    "MusicElements migration (BRE-198)",
    func() {
        test(
            "keeps the theme, draft, published layout and revision as they were",
            func() {
                let next = Migration.migration({
                    storefront = {
                        var theme = ?{ theme with hero = #split };
                        var draft = ?layout;
                        var published = ?{ layout with home = [] };
                        var revision = 7;
                    };
                });
                expect.bool(next.storefront.theme == ?{ theme with hero = #split }).isTrue();
                expect.bool(next.storefront.draft == ?layout).isTrue();
                expect.bool(next.storefront.published == ?{ layout with home = [] }).isTrue();
                expect.nat(next.storefront.revision).equal(7);
            },
        );
        test(
            "a shop that never saved a layout still has none",
            func() {
                let next = Migration.migration({
                    storefront = {
                        var theme = null;
                        var draft = null;
                        var published = null;
                        var revision = 0;
                    };
                });
                expect.bool(next.storefront.draft == null).isTrue();
                expect.bool(next.storefront.published == null).isTrue();
                expect.nat(next.storefront.revision).equal(0);
            },
        );
    },
);
