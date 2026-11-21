import { type Result } "mo:core/Result";

import Logger "../../../lib/Logger";
import AuthService "../lib/auth";
import ShopPresentation "../lib/presentation";
import PubSubService "../lib/pubsub";

import {
    type MediaSettings;
    type PresentationSettings;
    type ShopProfile;
} "../types";

/// Whether the shop shows as a storefront or an artist page, and the artist profile (BRE-197): read by
/// every buyer, edited by staff with `Storefront.Edit`.
mixin (presentation : PresentationSettings, profile : ShopProfile, media : MediaSettings, authService : AuthService.AuthService, pubSubService : PubSubService.PubSubService, logger : Logger.BoundLogger) {
    /// The presentation, artist preset and artist profile, each optional so an older client gets null
    /// for a value it can't decode. No caller check: it's how the public shop page looks.
    public query func getShopPresentation() : async ShopPresentation.PresentationView {
        ShopPresentation.view(presentation, media.mediaCanisterId);
    };

    /// Shows the shop as a storefront or an artist page, and sets the artist preset unless it's null.
    /// Needs `Storefront.Edit` and a signed-in caller. Tells subscribers (core) when the presentation
    /// changed, with a `ShopDetailsUpdated` event.
    public shared ({ caller }) func setShopPresentation(mode : ShopPresentation.Presentation, artistPreset : ?ShopPresentation.ArtistPreset) : async Result<(), ShopPresentation.SetPresentationError> {
        switch (ShopPresentation.setPresentation(presentation, authService, caller, mode, artistPreset)) {
            case (#err(e)) return #err(e);
            case (#ok(changed)) {
                logger.info("Set the shop's presentation to " # debug_show (mode) # " (artist preset " # debug_show (presentation.artistPreset) # ")");
                if (changed) {
                    try {
                        ignore pubSubService.notifyShopDetailsUpdated(PubSubService.shopDetailsEventData(profile, presentation.mode));
                    } catch (e) {
                        pubSubService.logUnsent("ShopDetailsUpdated", e);
                    };
                };
                #ok;
            };
        };
    };

    /// Replaces the artist profile, or with null removes it. Needs `Storefront.Edit` and a signed-in
    /// caller. Every length and count is checked before anything is stored (`#Invalid` lists each
    /// problem).
    public shared ({ caller }) func setArtistProfile(artistProfile : ?ShopPresentation.ArtistProfile) : async Result<(), ShopPresentation.SetArtistProfileError> {
        let result = ShopPresentation.setArtistProfile(presentation, authService, caller, artistProfile);
        switch (result, artistProfile) {
            case (#ok, ?p) logger.info("Set the artist profile (" # debug_show (p.links.size()) # " links)");
            case (#ok, null) logger.info("Removed the artist profile");
            case (#err(_), _) {};
        };
        result;
    };
};
