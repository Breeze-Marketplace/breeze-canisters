import Array "mo:core/Array";
import Float "mo:core/Float";
import Int "mo:core/Int";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import AuthService "auth";
import ShopPermissions "permissions";

/// Storefront themes (BRE-171): who may set one, and the WCAG AA contrast check every theme must
/// pass. Checkout uses the theme too, so an unreadable theme is rejected rather than warned about.
///
/// The check covers every pairing of a themed color the storefront draws, in the theme's color
/// scheme (buyers have no scheme toggle), in each state the frontend renders: normal, hover and
/// disabled. The palettes below mirror the frontend's design tokens (`src/frontend/src/lib/shopTheme.ts`
/// keeps a copy and a test that the two agree).
module {
    /// An sRGB color, 8 bits per channel.
    public type ThemeColor = { red : Nat8; green : Nat8; blue : Nat8 };

    /// Which of the color scheme's two text colors sits on a themed color: its near-black or near-white.
    public type TextTone = { #dark; #light };

    /// The storefront's brand settings (BRE-171), applied to the shop's storefront, product, cart,
    /// checkout and invoice pages as design tokens only. Every value is a variant or a byte, so there is
    /// nothing to sanitize. `contrastFailures` rejects a theme whose colors don't meet WCAG AA.
    public type ShopTheme = {
        primary : ThemeColor;
        /// Text on primary buttons.
        onPrimary : TextTone;
        accent : ThemeColor;
        /// Text on accent highlights (menu focus, hovered ghost buttons).
        onAccent : TextTone;
        /// Display/body fonts, from the fonts the marketplace frontend already loads.
        fonts : {
            #archivoGrotesk; // Archivo Black headings, Space Grotesk body (the marketplace default)
            #grotesk; // Space Grotesk throughout
            #monoGrotesk; // JetBrains Mono headings, Space Grotesk body
            #mono; // JetBrains Mono throughout
        };
        /// Corner radius and button shadow.
        shape : {
            #sharp; // square corners, hard offset shadow (the marketplace default)
            #rounded; // rounded corners, hard offset shadow
            #soft; // rounder corners, faint shadow
        };
        /// The storefront's color scheme. Buyers have no toggle, so this is the only one they see.
        colorScheme : { #dark; #light };
        /// How the shop home page shows its banner and details.
        hero : { #banner; #split; #minimal };
    };

    /// The fields of a theme the contrast check reads; `ShopTheme` and the layout's `StorefrontTheme`
    /// (`storefront_layout.mo`) both have them.
    public type ThemeColors = {
        primary : ThemeColor;
        onPrimary : TextTone;
        accent : ThemeColor;
        onAccent : TextTone;
        colorScheme : { #dark; #light };
    };

    /// WCAG AA minimum for normal-size text.
    public let MIN_TEXT_CONTRAST = 4.5;
    /// WCAG AA minimum for UI components such as the focus outline.
    public let MIN_NON_TEXT_CONTRAST = 3.0;

    /// The fixed colors of a color scheme, as the storefront draws them (sRGB of the CSS tokens).
    public type Palette = {
        background : ThemeColor;
        card : ThemeColor;
        muted : ThemeColor;
        mutedForeground : ThemeColor;
        foreground : ThemeColor;
        destructive : ThemeColor;
        /// What `TextTone` `#dark` and `#light` mean in this scheme.
        darkText : ThemeColor;
        lightText : ThemeColor;
    };

    /// The marketplace's edge theme (`.theme-edge` in `src/frontend/src/index.css`).
    public let darkPalette : Palette = {
        background = { red = 7; green = 7; blue = 7 };
        card = { red = 15; green = 15; blue = 15 };
        muted = { red = 27; green = 27; blue = 27 };
        mutedForeground = { red = 158; green = 158; blue = 158 };
        foreground = { red = 245; green = 245; blue = 245 };
        destructive = { red = 255; green = 78; blue = 67 };
        darkText = { red = 7; green = 7; blue = 7 };
        lightText = { red = 245; green = 245; blue = 245 };
    };

    /// The light scheme a theme can pick (`LIGHT_TOKENS` in `src/frontend/src/lib/shopTheme.ts`).
    public let lightPalette : Palette = {
        background = { red = 250; green = 250; blue = 250 };
        card = { red = 243; green = 243; blue = 243 };
        muted = { red = 232; green = 232; blue = 232 };
        mutedForeground = { red = 85; green = 85; blue = 85 };
        foreground = { red = 11; green = 11; blue = 11 };
        destructive = { red = 194; green = 24; blue = 29 };
        darkText = { red = 11; green = 11; blue = 11 };
        lightText = { red = 250; green = 250; blue = 250 };
    };

    public func paletteOf(theme : ThemeColors) : Palette {
        switch (theme.colorScheme) {
            case (#dark) darkPalette;
            case (#light) lightPalette;
        };
    };

    /// A pairing below its minimum, named as the admin preview names it.
    public type ContrastFailure = {
        pairing : Text;
        ratio : Float;
        minimum : Float;
    };

    public type UpdateThemeError = {
        #Unauthorized : Text;
        #ContrastTooLow : [ContrastFailure];
    };

    func channel(c : Nat8) : Float {
        let s = Float.fromInt(Nat8.toNat(c)) / 255.0;
        if (s <= 0.04045) s / 12.92 else Float.pow((s + 0.055) / 1.055, 2.4);
    };

    /// WCAG relative luminance.
    public func luminance(c : ThemeColor) : Float {
        0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue);
    };

    /// WCAG contrast ratio, from 1 to 21.
    public func contrast(a : ThemeColor, b : ThemeColor) : Float {
        let la = luminance(a);
        let lb = luminance(b);
        (Float.max(la, lb) + 0.05) / (Float.min(la, lb) + 0.05);
    };

    /// `top` at `alpha` opacity over `bottom`, as the browser composites `bg-primary/90`.
    public func blend(top : ThemeColor, bottom : ThemeColor, alpha : Float) : ThemeColor {
        func mix(t : Nat8, b : Nat8) : Nat8 {
            let v = alpha * Float.fromInt(Nat8.toNat(t)) + (1.0 - alpha) * Float.fromInt(Nat8.toNat(b));
            Nat8.fromNat(Int.abs(Float.toInt(Float.nearest(Float.min(255.0, Float.max(0.0, v))))));
        };
        {
            red = mix(top.red, bottom.red);
            green = mix(top.green, bottom.green);
            blue = mix(top.blue, bottom.blue);
        };
    };

    func tone(palette : Palette, t : TextTone) : ThemeColor {
        switch (t) {
            case (#dark) palette.darkText;
            case (#light) palette.lightText;
        };
    };

    /// Every pairing below its minimum; empty when the theme is readable everywhere.
    public func contrastFailures(theme : ThemeColors) : [ContrastFailure] {
        let p = paletteOf(theme);
        let onPrimary = tone(p, theme.onPrimary);
        let onAccent = tone(p, theme.onAccent);
        let text = MIN_TEXT_CONTRAST;
        var checks : [(Text, ThemeColor, ThemeColor, Float)] = [
            ("Text on the page", p.foreground, p.background, text),
            ("Text on cards", p.foreground, p.card, text),
            ("Secondary text on the page", p.mutedForeground, p.background, text),
            ("Secondary text on cards", p.mutedForeground, p.card, text),
            ("Disabled button text", p.mutedForeground, p.muted, text),
            ("Primary text and prices on the page", theme.primary, p.background, text),
            ("Primary text and prices on cards", theme.primary, p.card, text),
            ("Primary button text", onPrimary, theme.primary, text),
            // Buttons darken to `bg-primary/90` on hover, over the page or a card.
            ("Primary button text on hover", onPrimary, blend(theme.primary, p.background, 0.9), text),
            ("Primary button text on hover, on cards", onPrimary, blend(theme.primary, p.card, 0.9), text),
            ("Accent text", onAccent, theme.accent, text),
            ("Error text on the page", p.destructive, p.background, text),
            ("Error text on cards", p.destructive, p.card, text),
            ("Focus outline", theme.primary, p.background, MIN_NON_TEXT_CONTRAST),
        ];
        // Ghost buttons and menu items hover at half-strength accent in the dark scheme (`dark:hover:bg-accent/50`).
        if (theme.colorScheme == #dark) {
            checks := Array.concat(
                checks,
                [
                    ("Accent text on hover", onAccent, blend(theme.accent, p.background, 0.5), text),
                    ("Accent text on hover, on cards", onAccent, blend(theme.accent, p.card, 0.5), text),
                ],
            );
        };
        Array.filterMap<(Text, ThemeColor, ThemeColor, Float), ContrastFailure>(
            checks,
            func((pairing, fg, bg, minimum)) {
                let ratio = contrast(fg, bg);
                if (ratio < minimum) ?{ pairing; ratio; minimum } else null;
            },
        );
    };

    /// Sets (or with null, clears) the theme. Needs `Storefront.Edit` (the Owner holds it) and a
    /// signed-in caller; a theme with any contrast failure is rejected and nothing changes.
    public func update(storefront : { var theme : ?ShopTheme }, authService : AuthService.AuthService, caller : Principal, theme : ?ShopTheme) : Result<(), UpdateThemeError> {
        if (Principal.isAnonymous(caller) or not AuthService.hasPermission(authService, caller, ShopPermissions.storefrontEdit)) {
            return #err(#Unauthorized("Changing the storefront theme needs the Storefront.Edit permission"));
        };
        switch (theme) {
            case null {};
            case (?t) {
                let failures = contrastFailures(t);
                if (failures.size() > 0) return #err(#ContrastTooLow(failures));
            };
        };
        storefront.theme := theme;
        #ok;
    };
};
