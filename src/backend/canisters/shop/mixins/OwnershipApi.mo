import { type Result } "mo:core/Result";

import Error "mo:core/Error";
import Principal "mo:core/Principal";
import Time "mo:core/Time";

import Logger "../../../lib/Logger";
import AuthService "../lib/auth";
import Marketplaces "../lib/marketplaces";

/// Ownership and Marketplace access (see `lib/auth`). Team roles and permissions are in the shared
/// `Team` mixin. Recognized marketplaces are in `lib/marketplaces`.
mixin (authService : AuthService.AuthService, recognizedMarketplaces : Marketplaces.Store, logger : Logger.BoundLogger) {

    /// Hands shop ownership to `principal`; the caller stops being Owner. Only the Owner may call.
    public shared ({ caller }) func setOwner(principal : Principal) : async Result<(), { #Unauthorized : Text }> {
        let result = AuthService.setOwner(authService, caller, principal);
        if (result == #ok) {
            logger.info("Set shop owner to " # Principal.toText(principal) # " (by " # Principal.toText(caller) # ")");
        };
        result;
    };

    /// Lets `principal` (core) subscribe to the shop's events and see a private location. Owner only.
    public shared ({ caller }) func grantMarketplaceAccess(principal : Principal) : async Result<(), { #Unauthorized : Text }> {
        let result = AuthService.grantMarketplace(authService, caller, principal);
        if (result == #ok) {
            logger.info("Granted Marketplace access to " # Principal.toText(principal) # " (by " # Principal.toText(caller) # ")");
        };
        result;
    };

    /// Recognizes the marketplace whose core (backend) canister is `backendCanisterId`: asks it for
    /// its frontend canister and name, records them, and grants it Marketplace access. Owner only.
    /// Recognizing it again refreshes the details.
    public shared ({ caller }) func recognizeMarketplace(backendCanisterId : Principal) : async Result<Marketplaces.RecognizedMarketplace, Marketplaces.RecognizeError> {
        if (not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop's Owner can recognize a marketplace"));
        };
        if (backendCanisterId.isAnonymous()) {
            return #err(#Unauthorized("The anonymous principal isn't a marketplace"));
        };
        let marketplace = actor (backendCanisterId.toText()) : actor {
            getMarketplaceInfo : query () -> async Marketplaces.MarketplaceInfo;
        };
        let info = try {
            await (with timeout = Marketplaces.CALL_TIMEOUT_SECONDS) marketplace.getMarketplaceInfo();
        } catch (e) {
            return #err(#MarketplaceUnreachable("Couldn't read the marketplace's details: " # Error.message(e)));
        };
        // Ownership may have been handed over while waiting.
        if (not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop's Owner can recognize a marketplace"));
        };
        switch (Marketplaces.record(recognizedMarketplaces, backendCanisterId, info, caller, Time.now())) {
            case (#err(e)) #err(e);
            case (#ok(entry)) {
                ignore AuthService.grantMarketplace(authService, caller, backendCanisterId);
                logger.info("Recognized marketplace \"" # entry.name # "\" (" # backendCanisterId.toText() # ") (by " # caller.toText() # ")");
                #ok(entry);
            };
        };
    };

    /// The marketplaces the Owner recognized. Public: a shop's marketplaces are no secret.
    public query func getRecognizedMarketplaces() : async [Marketplaces.RecognizedMarketplace] {
        Marketplaces.list(recognizedMarketplaces);
    };

    /// Takes Marketplace access from `principal`, and forgets it as a recognized marketplace. Owner only.
    public shared ({ caller }) func revokeMarketplaceAccess(principal : Principal) : async Result<(), { #Unauthorized : Text }> {
        let result = AuthService.revokeMarketplace(authService, caller, principal);
        if (result == #ok) {
            Marketplaces.forget(recognizedMarketplaces, principal);
            logger.info("Revoked Marketplace access from " # Principal.toText(principal) # " (by " # Principal.toText(caller) # ")");
        };
        result;
    };
};
