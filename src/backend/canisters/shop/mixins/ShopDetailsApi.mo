import { type Result } "mo:core/Result";

import Logger "../../../lib/Logger";
import PubSubService "../lib/pubsub";
import AuthService "../lib/auth";
import ShopPermissions "../lib/permissions";

import {
    type Address;
    type ShopLocation;
    type ShopProfile;
    type PresentationSettings;
} "../types";

/// The shop's public profile: reading it (location filtered by role) and updating it.
mixin (profile : ShopProfile, presentation : PresentationSettings, authService : AuthService.AuthService, pubSubService : PubSubService.PubSubService, logger : Logger.BoundLogger) {
    private func physicalLocationForViewer(caller : Principal) : ?ShopLocation {
        let canViewLocation = AuthService.isMarketplace(authService, caller) or AuthService.hasPermission(authService, caller, ShopPermissions.settingsEdit);

        if (profile.showPhysicalLocation or canViewLocation) {
            profile.physicalLocation;
        } else {
            null;
        };
    };

    /// Storefront-facing name, description, media URLs, and location visibility filtered by caller role.
    public shared query ({ caller }) func getShopDetails() : async {
        name : Text;
        description : Text;
        logoUrl : ?Text;
        bannerImageUrl : ?Text;
        physicalLocation : ?ShopLocation;
        showPhysicalLocation : Bool;
    } {
        return {
            name = profile.name;
            description = profile.description;
            logoUrl = profile.logoUrl;
            bannerImageUrl = profile.bannerImageUrl;
            physicalLocation = physicalLocationForViewer(caller);
            showPhysicalLocation = profile.showPhysicalLocation;
        };
    };

    /// Patches shop metadata, optional physical location, and public location flag; notifies shop-details subscribers. Owner or Admin.
    public shared ({ caller }) func updateShopDetails(
        input : {
            name : ?Text;
            description : ?Text;
            logoUrl : ?Text;
            bannerImageUrl : ?Text;
            physicalLocation : ?{
                #PostalCode : Text;
                #FullAddress : ?Address;
            };
            showPhysicalLocation : ?Bool;
        }
    ) : async Result<(), { #Unauthorized : Text }> {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.settingsEdit)) {
            return #err(#Unauthorized("Insufficient role to update store details"));
        };
        switch (input.name) {
            case null {};
            case (?newName) {
                profile.name := newName;
            };
        };
        switch (input.description) {
            case null {};
            case (?newDescription) {
                profile.description := newDescription;
            };
        };
        switch (input.logoUrl) {
            case null {};
            case (?newLogoUrl) {
                profile.logoUrl := ?newLogoUrl;
            };
        };
        switch (input.bannerImageUrl) {
            case null {};
            case (?newBannerImageUrl) {
                profile.bannerImageUrl := ?newBannerImageUrl;
            };
        };
        switch (input.physicalLocation) {
            case null {};
            case (?loc) {
                switch (loc) {
                    case (#PostalCode t) {
                        if (t == "") {
                            profile.physicalLocation := null;
                        } else {
                            profile.physicalLocation := ?#PostalCode(t);
                        };
                    };
                    case (#FullAddress t) {
                        switch (t) {
                            case null {
                                profile.physicalLocation := null;
                            };
                            case (?addr) {
                                profile.physicalLocation := ?#FullAddress(addr);
                            };
                        };
                    };
                };
            };
        };
        switch (input.showPhysicalLocation) {
            case null {};
            case (?b) {
                profile.showPhysicalLocation := b;
            };
        };
        // The location itself stays out of the log: it can be private (showPhysicalLocation false).
        logger.info("Updated shop details (name \"" # profile.name # "\", location public: " # debug_show (profile.showPhysicalLocation) # ")");

        try {
            ignore pubSubService.notifyShopDetailsUpdated(PubSubService.shopDetailsEventData(profile, presentation.mode));
        } catch (e) {
            pubSubService.logUnsent("ShopDetailsUpdated", e);
        };

        #ok;
    };
};
