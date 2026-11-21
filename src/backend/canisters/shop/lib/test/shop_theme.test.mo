import { expect } "mo:test";
import { suite; test } "mo:test";

import Array "mo:core/Array";
import Float "mo:core/Float";
import Principal "mo:core/Principal";

import ShopThemes "../shop_theme";
import ShopPermissions "../permissions";
import Fixtures "fixtures";
import { type ShopTheme; type ThemeColor } "../shop_theme";

let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let designer = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let catalogManager = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
let stranger = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");

func color(red : Nat8, green : Nat8, blue : Nat8) : ThemeColor = {
    red;
    green;
    blue;
};

let lime = color(194, 248, 61); // the marketplace's own primary
let blue = color(54, 101, 228);
let paleLime = color(220, 255, 120);
let paleYellow = color(255, 250, 200);
let darkBlue = color(30, 58, 138);

/// Close to the marketplace's own look: lime on the dark scheme, with a paler accent (see below).
let edgeTheme : ShopTheme = {
    primary = lime;
    onPrimary = #dark;
    accent = paleLime;
    onAccent = #dark;
    fonts = #archivoGrotesk;
    shape = #sharp;
    colorScheme = #dark;
    hero = #banner;
};

func pairings(theme : ShopTheme) : [Text] {
    ShopThemes.contrastFailures(theme).map(func(f : ShopThemes.ContrastFailure) : Text = f.pairing);
};

func has(list : [Text], item : Text) : Bool {
    list.find(func(t : Text) : Bool = t == item) != null;
};

func newStorefront() : { var theme : ?ShopTheme } = { var theme = null };

func errorOf(r : { #ok; #err : ShopThemes.UpdateThemeError }) : Text {
    switch (r) {
        case (#ok) "ok";
        case (#err(#Unauthorized(_))) "Unauthorized";
        case (#err(#ContrastTooLow(_))) "ContrastTooLow";
    };
};

suite(
    "contrast",
    func() {
        test(
            "matches WCAG's reference values",
            func() {
                expect.bool(Float.abs(ShopThemes.contrast(color(0, 0, 0), color(255, 255, 255)) - 21.0) <= 0.001).isTrue();
                expect.bool(Float.abs(ShopThemes.contrast(color(255, 255, 255), color(255, 255, 255)) - 1.0) <= 0.001).isTrue();
                // #767676 on white is the classic just-passing grey (4.54:1).
                expect.bool(Float.abs(ShopThemes.contrast(color(118, 118, 118), color(255, 255, 255)) - 4.54) <= 0.01).isTrue();
            },
        );
        test(
            "blend composites like the browser",
            func() {
                let mixed = ShopThemes.blend(color(255, 255, 255), color(0, 0, 0), 0.5);
                expect.nat8(mixed.red).equal(128);
                let same = ShopThemes.blend(lime, color(7, 7, 7), 1.0);
                expect.bool(same == lime).isTrue();
            },
        );
        test(
            "the fixed palettes pass on their own",
            func() {
                for (palette in [ShopThemes.darkPalette, ShopThemes.lightPalette].values()) {
                    expect.bool(ShopThemes.contrast(palette.foreground, palette.background) >= 4.5).isTrue();
                    expect.bool(ShopThemes.contrast(palette.mutedForeground, palette.muted) >= 4.5).isTrue();
                    expect.bool(ShopThemes.contrast(palette.destructive, palette.card) >= 4.5).isTrue();
                };
            },
        );
    },
);

suite(
    "contrastFailures",
    func() {
        test(
            "lime with a pale lime accent passes",
            func() {
                expect.nat(pairings(edgeTheme).size()).equal(0);
            },
        );
        test(
            "the marketplace's own lime accent falls just short on the half-strength hover",
            func() {
                // Dark text on lime at 50% over the page is 4.46:1, so a shop can't copy that accent as-is.
                let failures = ShopThemes.contrastFailures({
                    edgeTheme with accent = lime
                });
                expect.nat(failures.size()).equal(1);
                expect.text(failures[0].pairing).equal("Accent text on hover");
                expect.bool(failures[0].ratio > 4.4).isTrue();
            },
        );
        test(
            "a dark blue on the light scheme passes with light text on it",
            func() {
                let theme = {
                    edgeTheme with primary = darkBlue;
                    onPrimary = #light;
                    accent = darkBlue;
                    onAccent = #light;
                    colorScheme = #light;
                };
                expect.nat(pairings(theme).size()).equal(0);
            },
        );
        test(
            "a pale primary on the light scheme fails as text on the page and on cards",
            func() {
                let failures = pairings({
                    edgeTheme with primary = paleYellow;
                    colorScheme = #light;
                    accent = darkBlue;
                    onAccent = #light;
                });
                expect.bool(has(failures, "Primary text and prices on the page")).isTrue();
                expect.bool(has(failures, "Primary text and prices on cards")).isTrue();
                expect.bool(has(failures, "Focus outline")).isTrue();
                expect.bool(has(failures, "Accent text")).isFalse();
            },
        );
        test(
            "the wrong text tone on a button fails, in normal and hover state",
            func() {
                let failures = pairings({ edgeTheme with onPrimary = #light });
                expect.bool(has(failures, "Primary button text")).isTrue();
                expect.bool(has(failures, "Primary button text on hover")).isTrue();
                expect.bool(has(failures, "Primary text and prices on the page")).isFalse();
            },
        );
        test(
            "a mid blue is too dark as text on the dark scheme",
            func() {
                let failures = pairings({
                    edgeTheme with primary = blue;
                    onPrimary = #light;
                });
                expect.bool(has(failures, "Primary text and prices on the page")).isTrue();
            },
        );
        test(
            "the dark scheme checks accent text on the half-strength hover",
            func() {
                // Light text passes on full-strength accent but not once it's blended into the dark page.
                let accent = color(150, 150, 150);
                let onFull = ShopThemes.contrast(ShopThemes.darkPalette.darkText, accent);
                expect.bool(onFull >= 4.5).isTrue();
                let failures = pairings({
                    edgeTheme with accent;
                    onAccent = #dark;
                });
                expect.bool(has(failures, "Accent text")).isFalse();
                expect.bool(has(failures, "Accent text on hover")).isTrue();
            },
        );
        test(
            "reports the ratio and the minimum",
            func() {
                let failures = ShopThemes.contrastFailures({
                    edgeTheme with onPrimary = #light
                });
                for (f in failures.values()) {
                    expect.bool(f.ratio < f.minimum).isTrue();
                };
            },
        );
    },
);

suite(
    "update",
    func() {
        test(
            "the Owner can set and clear a theme",
            func() {
                let auth = Fixtures.newAuthService(owner);
                let storefront = newStorefront();
                expect.text(errorOf(ShopThemes.update(storefront, auth, owner, ?edgeTheme))).equal("ok");
                expect.bool(storefront.theme == ?edgeTheme).isTrue();
                expect.text(errorOf(ShopThemes.update(storefront, auth, owner, null))).equal("ok");
                expect.bool(storefront.theme == null).isTrue();
            },
        );
        test(
            "a member with Storefront.Edit can set it; other permissions can't",
            func() {
                let auth = Fixtures.newAuthService(owner);
                Fixtures.grantRole(auth, designer, "Designer", [ShopPermissions.storefrontEdit]);
                Fixtures.grantRole(auth, catalogManager, "Catalog", [ShopPermissions.productsEdit, ShopPermissions.settingsEdit]);
                let storefront = newStorefront();
                expect.text(errorOf(ShopThemes.update(storefront, auth, designer, ?edgeTheme))).equal("ok");
                expect.text(errorOf(ShopThemes.update(storefront, auth, catalogManager, null))).equal("Unauthorized");
                expect.text(errorOf(ShopThemes.update(storefront, auth, stranger, null))).equal("Unauthorized");
                expect.bool(storefront.theme == ?edgeTheme).isTrue();
            },
        );
        test(
            "the anonymous principal is rejected",
            func() {
                let auth = Fixtures.newAuthService(owner);
                let storefront = newStorefront();
                expect.text(errorOf(ShopThemes.update(storefront, auth, Principal.anonymous(), ?edgeTheme))).equal("Unauthorized");
                expect.bool(storefront.theme == null).isTrue();
            },
        );
        test(
            "an unreadable theme is rejected and the old one stays",
            func() {
                let auth = Fixtures.newAuthService(owner);
                let storefront = newStorefront();
                ignore ShopThemes.update(storefront, auth, owner, ?edgeTheme);
                let result = ShopThemes.update(storefront, auth, owner, ?{ edgeTheme with onPrimary = #light });
                expect.text(errorOf(result)).equal("ContrastTooLow");
                expect.bool(storefront.theme == ?edgeTheme).isTrue();
            },
        );
    },
);
