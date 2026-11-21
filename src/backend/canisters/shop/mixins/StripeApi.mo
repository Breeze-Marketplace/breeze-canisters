import { type Result } "mo:core/Result";
import Text "mo:core/Text";

import Logger "../../../lib/Logger";
import Management "../../../interfaces/management";
import AuthService "../lib/auth";
import ShopPermissions "../lib/permissions";
import Checkout "../lib/stripe/Checkout";
import Stripe "../lib/stripe/lib";
import { type StripeSettings } "../types";

/// The Owner's Stripe restricted key, which turns on card payments (BRE-123). The key is write-only:
/// no method returns it, only its mode and last four characters. Checkout and payment checks are in
/// `OrdersApi`, which also defines `stripeTransform`, passed in here.
mixin (
    stripe : StripeSettings,
    authService : AuthService.AuthService,
    stripeTransformFunction : Management.TransformFunction,
    logger : Logger.BoundLogger,
) {
    public type StripeKeyStatus = { mode : Checkout.Mode; keyHint : Text };

    /// True while `setStripeKey` is checking a key with Stripe.
    transient var stripeKeyCheckRunning = false;

    /// Owner only. Checks `key` is a restricted key (`rk_…`) that can read Checkout Sessions, by
    /// listing one session, then stores it, replacing any earlier key. Secret keys are refused:
    /// shop state is readable by node operators, so the key is restricted to limit what a leak
    /// could do. Give the restricted key write access to Checkout Sessions and nothing else.
    public shared ({ caller }) func setStripeKey(key : Text) : async Result<StripeKeyStatus, { #Unauthorized : Text; #InvalidKey : Text; #Busy : Text }> {
        if (not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop Owner can set the Stripe key"));
        };
        let trimmed = key.trim(#char ' ');
        let mode = switch (Checkout.validateKey(trimmed)) {
            case (#ok(m)) m;
            case (#err(message)) return #err(#InvalidKey(message));
        };
        if (stripeKeyCheckRunning) return #err(#Busy("A Stripe key is already being checked"));
        stripeKeyCheckRunning := true;
        let reply = try {
            await* Stripe.checkKey(trimmed, stripeTransformFunction);
        } finally {
            stripeKeyCheckRunning := false;
        };
        switch (reply) {
            case (#list) {};
            case (#error({ message })) return #err(#InvalidKey("Stripe didn't accept the key: " # message));
            case (#session(_)) return #err(#InvalidKey("Unexpected reply from Stripe"));
        };
        stripe.restrictedKey := ?trimmed;
        logger.info("Stripe " # (if (mode == #live) "live" else "test") # " key ending " # Checkout.keyHint(trimmed) # " set; card payments are on");
        #ok({ mode; keyHint = Checkout.keyHint(trimmed) });
    };

    /// Owner only. Forgets the Stripe key and turns card payments off. Orders already sent to
    /// Stripe Checkout can't be confirmed afterwards, and expire unpaid.
    public shared ({ caller }) func removeStripeKey() : async Result<(), { #Unauthorized : Text }> {
        if (not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop Owner can remove the Stripe key"));
        };
        stripe.restrictedKey := null;
        logger.info("Stripe key removed; card payments are off");
        #ok(());
    };

    /// Owner or Admin: the mode and last four characters of the Stripe key, or null when none is
    /// set. Null for everyone else.
    public query ({ caller }) func getStripeKeyStatus() : async ?StripeKeyStatus {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.fundsView)) return null;
        let ?key = stripe.restrictedKey else return null;
        switch (Checkout.validateKey(key)) {
            case (#ok(mode)) ?{ mode; keyHint = Checkout.keyHint(key) };
            case (#err(_)) null;
        };
    };

    /// Whether buyers can pay by card (in USD, through Stripe Checkout). Anyone may ask.
    public query func acceptsCardPayments() : async Bool {
        stripe.restrictedKey != null;
    };
};
