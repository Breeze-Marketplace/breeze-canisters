import { type Result } "mo:core/Result";

import Logger "../../../lib/Logger";
import AuthService "../lib/auth";
import ShopThemes "../lib/shop_theme";
import Layouts "../lib/storefront_layout";

import {
    type MediaSettings;
    type ShopTheme;
    type StorefrontSettings;
} "../types";

/// The storefront's look (BRE-171) and home page layout (BRE-172): read by every buyer, edited by staff
/// with `Storefront.Edit`.
mixin (storefront : StorefrontSettings, media : MediaSettings, authService : AuthService.AuthService, logger : Logger.BoundLogger) {
    /// The storefront theme, or null when the shop hasn't set one. No caller check: the theme is how
    /// the public storefront looks, so anyone may read it.
    public query func getShopTheme() : async ?ShopTheme {
        storefront.theme;
    };

    /// Sets the storefront theme, or with null goes back to the marketplace's look. Needs
    /// `Storefront.Edit` and a signed-in caller. Rejects (`#ContrastTooLow`, naming each pairing) a theme
    /// whose colors don't meet WCAG AA everywhere the storefront and checkout use them.
    public shared ({ caller }) func updateShopTheme(theme : ?ShopTheme) : async Result<(), ShopThemes.UpdateThemeError> {
        let result = ShopThemes.update(storefront, authService, caller, theme);
        switch (result, theme) {
            case (#ok, ?t) logger.info("Set the storefront theme (" # debug_show (t.colorScheme) # " scheme, " # debug_show (t.fonts) # " fonts)");
            case (#ok, null) logger.info("Cleared the storefront theme");
            case (#err(_), _) {};
        };
        result;
    };

    /// The element types (and their settings versions, with `"section"`'s) this shop accepts. The
    /// editor offers only these. No caller check: it describes the wasm, not the shop's data.
    public query func storefrontElementTypes() : async [Layouts.ElementType] {
        Layouts.elementTypes;
    };

    /// The published home page layout, or null when the shop hasn't published one (the storefront then
    /// shows its default layout). No caller check: it's what the public storefront shows, and holds only
    /// design content. Sections and elements are optional so a client that can't decode a newer one
    /// skips it.
    public query func getStorefront() : async ?Layouts.PublishedLayoutView {
        Layouts.publishedView(storefront, media.mediaCanisterId);
    };

    /// The draft layout and its revision, for the editor. Needs `Storefront.Edit`, so unpublished pages
    /// stay private.
    public shared query ({ caller }) func getStorefrontEditor() : async Result<Layouts.EditorState, { #Unauthorized : Text }> {
        if (not Layouts.canReadDraft(authService, caller)) {
            return #err(#Unauthorized("Viewing the storefront draft needs the Storefront.Edit permission"));
        };
        #ok(Layouts.editorState(storefront));
    };

    /// Saves the draft layout and returns the new revision. Needs `Storefront.Edit`, a signed-in caller
    /// and the revision the editor last saw (`#RevisionConflict` otherwise). Every limit is checked and
    /// the theme must pass WCAG AA before anything is stored.
    public shared ({ caller }) func saveStorefrontDraft(layout : Layouts.LayoutInput, expectedRevision : Nat) : async Result<Nat, Layouts.SaveDraftError> {
        let result = Layouts.saveDraft(storefront, authService, caller, layout, expectedRevision);
        switch (result) {
            case (#ok(revision)) logger.info("Saved the storefront draft (revision " # debug_show (revision) # ", " # debug_show (layout.home.size()) # " sections)");
            case (#err(_)) {};
        };
        result;
    };

    /// Publishes the draft: buyers see it from now on. Needs `Storefront.Edit`, a signed-in caller and the
    /// current revision.
    public shared ({ caller }) func publishStorefront(expectedRevision : Nat) : async Result<(), Layouts.PublishError> {
        let result = Layouts.publish(storefront, authService, caller, expectedRevision);
        switch (result) {
            case (#ok) logger.info("Published the storefront (revision " # debug_show (expectedRevision) # ")");
            case (#err(_)) {};
        };
        result;
    };

    /// Throws away unpublished changes: the draft goes back to the published layout. Needs
    /// `Storefront.Edit`, a signed-in caller and the current revision. Returns the new revision.
    public shared ({ caller }) func discardStorefrontDraft(expectedRevision : Nat) : async Result<Nat, Layouts.PublishError> {
        let result = Layouts.discardDraft(storefront, authService, caller, expectedRevision);
        switch (result) {
            case (#ok(_)) logger.info("Discarded the storefront draft");
            case (#err(_)) {};
        };
        result;
    };
};
