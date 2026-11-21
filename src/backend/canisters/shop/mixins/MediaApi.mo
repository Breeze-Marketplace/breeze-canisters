import Array "mo:base/Array";
import Nat32 "mo:base/Nat32";
import { type Result } "mo:core/Result";
import Error "mo:core/Error";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Map "mo:map/Map";

import {
    type Management;
} "../../../interfaces/management";

import DeliveryToken "../../../lib/DeliveryToken";

import Logger "../../../lib/Logger";
import AdminAccess "../lib/admin_access";
import AuthService "../lib/auth";
import ShopPermissions "../lib/permissions";
import DigitalDelivery "../lib/digital_delivery";
import Music "../lib/music";
import ReleaseDelivery "../lib/release_delivery";

import {
    type Order;
    type ProductVariant;
    type ProductId;
    type VariantId;
    type OrderId;
    type Product;
    type DigitalDeliveryResponse;
    type MediaSettings;
} "../types";

/// The media (vault) canister link, the HMAC secret shared with it, private media keys for digital
/// variants, and minting delivery tickets for paid digital line items and the releases they sell.
mixin (
    media : MediaSettings,
    digitalAssetKeys : Map.Map<Text, Text>,
    products : Map.Map<ProductId, Product>,
    productVariants : Map.Map<VariantId, ProductVariant>,
    orders : Map.Map<OrderId, Order>,
    music : Music.Library,
    authService : AuthService.AuthService,
    shopId : Principal,
    logger : Logger.BoundLogger,
    recordDigitalDelivery : (OrderId, Nat) -> async* (),
) {
    private transient let icManagement : actor { raw_rand : () -> async Blob } = actor "aaaaa-aa";

    private func mediaCanister() : ?(
        actor {
            setShopCanisterId : (id : Principal) -> async ();
            setHmacSecretKey : (key : Blob) -> async ();
        }
    ) {
        switch (media.mediaCanisterId) {
            case null null;
            case (?id) ?(actor (Principal.toText(id)));
        };
    };

    /// Sets the media canister (asset) canister principal used for shop uploads and URLs. Owner only.
    public shared ({ caller }) func setMediaCanisterId(canisterId : Principal) : async Result<(), { #Unauthorized : Text }> {
        if (not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the canister owner can set the media canister ID"));
        };
        media.mediaCanisterId := ?canisterId;
        logger.info("Set media canister to " # Principal.toText(canisterId));
        switch (mediaCanister()) {
            case null {};
            case (?canister) {
                await canister.setShopCanisterId(shopId);
                await canister.setHmacSecretKey(media.hmacSecretKey);
            };
        };
        #ok;
    };

    /// Pushes the current HMAC secret to the media canister. The owner can point `mediaCanisterId`
    /// at any canister, so the call is bounded: a callee that never replies can't block upgrades.
    private func syncHmacSecretToMedia() : async () {
        switch (mediaCanister()) {
            case null {};
            case (?canister) {
                await (with timeout = 30) canister.setHmacSecretKey(media.hmacSecretKey);
            };
        };
    };

    /// Set while a new HMAC secret is being generated, so overlapping calls don't each draw one.
    private transient var generatingHmacSecret = false;

    /// Replaces the HMAC secret with 32 fresh bytes from `raw_rand`, bumps its version and pushes it
    /// to the media canister. Tickets signed with the old key stop working. Runs on install and on
    /// every upgrade that finds no usable key (see `main.mo`), so new shops never sign with a
    /// constant (BRE-55). No caller check: it is private, reached only from the shop itself.
    private func generateHmacSecretKey() : async () {
        if (generatingHmacSecret) return;
        generatingHmacSecret := true;
        try {
            let key = await icManagement.raw_rand();
            if (not DeliveryToken.isUsableKey(key)) return;
            media.hmacSecretKey := key;
            media.hmacSecretKeyVersion +%= 1;
            logger.info("Generated HMAC secret key version " # debug_show (media.hmacSecretKeyVersion));
            await syncHmacSecretToMedia();
        } finally {
            generatingHmacSecret := false;
        };
    };

    /// Replaces the HMAC secret that signs delivery tickets with a fresh random one and pushes it to
    /// the media canister. Outstanding tickets stop working. Owner only.
    public shared ({ caller }) func rotateHmacSecretKey() : async Result<(), { #Unauthorized : Text; #Failed : Text }> {
        if (not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the canister owner can rotate the HMAC secret key"));
        };
        if (generatingHmacSecret) {
            return #err(#Failed("A new HMAC secret key is already being generated"));
        };
        let before = media.hmacSecretKey;
        try {
            await generateHmacSecretKey();
        } catch (e) {
            return #err(#Failed("Failed to rotate the HMAC secret key: " # Error.message(e)));
        };
        if (media.hmacSecretKey == before) {
            return #err(#Failed("Failed to rotate the HMAC secret key"));
        };
        #ok;
    };

    private func randomDeliveryNonce() : async Blob {
        let blob = await icManagement.raw_rand();
        let bytes = Blob.toArray(blob);
        let size = if (bytes.size() < DigitalDelivery.NONCE_SIZE) {
            bytes.size();
        } else {
            DigitalDelivery.NONCE_SIZE;
        };
        Blob.fromArray(
            Array.tabulate<Nat8>(
                DigitalDelivery.NONCE_SIZE,
                func(i : Nat) : Nat8 {
                    if (i < size) { bytes[i] } else { 0 };
                },
            )
        );
    };

    /// Sets the HMAC secret used to mint delivery tickets, and a version number recorded with it;
    /// propagates the key to the media canister when configured. Owner only. Prefer
    /// `rotateHmacSecretKey`, which draws the key from `raw_rand`.
    public shared ({ caller }) func setHmacSecretKey(
        version : Nat8,
        key : Blob,
    ) : async Result<(), { #Unauthorized : Text; #InputError : Text }> {
        if (not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the canister owner can set the HMAC secret key"));
        };
        if (not DeliveryToken.isUsableKey(key)) {
            return #err(#InputError("HMAC secret key must be at least " # debug_show (DeliveryToken.MIN_KEY_LEN) # " bytes"));
        };
        media.hmacSecretKeyVersion := version;
        media.hmacSecretKey := key;
        logger.info("Set HMAC secret key version " # debug_show (version));
        await syncHmacSecretToMedia();
        #ok;
    };

    /// Stores the private media object key for a digital product variant. Owner or Admin.
    public shared ({ caller }) func setDigitalAssetKey(
        productId : ProductId,
        variantId : VariantId,
        mediaKey : Text,
    ) : async Result<(), { #InputError : Text; #Unauthorized : Text }> {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.digitalAssetsEdit)) {
            return #err(#Unauthorized("Insufficient role to set digital asset key"));
        };
        if (mediaKey == "") {
            return #err(#InputError("Media key must not be empty"));
        };
        switch (Map.get(products, Map.n32hash, productId)) {
            case null {
                return #err(#InputError("Product not found"));
            };
            case (?product) {
                if (product.productType != #Digital) {
                    return #err(#InputError("Digital asset keys can only be set on digital products"));
                };
            };
        };
        switch (Map.get(productVariants, Map.n32hash, variantId)) {
            case null {
                return #err(#InputError("Variant not found"));
            };
            case (?variant) {
                if (variant.productId != productId) {
                    return #err(#InputError("Variant does not belong to the given product"));
                };
            };
        };
        let mapKey = DigitalDelivery.digitalAssetMapKey(productId, variantId);
        let _ = Map.put(digitalAssetKeys, Map.thash, mapKey, DeliveryToken.normalizeAssetPath(mediaKey));
        logger.info("Set digital asset key for product " # debug_show (productId) # ", variant " # debug_show (variantId));
        #ok;
    };

    /// Owner or Admin: the configured private media key for a variant, or `null` if the default path
    /// convention applies. Other callers always get `null` (BRE-105).
    public query ({ caller }) func getDigitalAssetKey(
        productId : ProductId,
        variantId : VariantId,
    ) : async ?Text {
        if (not AdminAccess.canViewDigitalAssets(authService, caller)) {
            return null;
        };
        Map.get(digitalAssetKeys, Map.thash, DigitalDelivery.digitalAssetMapKey(productId, variantId));
    };

    /// Returns the configured media canister principal, if set, to any signed-in caller. It isn't secret:
    /// buyers build `requestDigitalDelivery`'s download link from it and public assets are served from it.
    /// Private files stay behind the HMAC ticket the vault checks. Core reads it for `linkShopVault`.
    public query ({ caller }) func getMediaCanisterId() : async ?Principal {
        if (Principal.isAnonymous(caller)) {
            return null;
        };
        return media.mediaCanisterId;
    };

    /// Mints a short-lived HMAC delivery ticket for a paid digital line item. Caller must be the order buyer.
    /// The first ticket for a line records it as delivered, which can fulfil the order (BRE-133).
    /// The download link is `<vault URL><mediaKey>?token=<token>`, built by the client: the shop
    /// doesn't know which network's gateway serves its vault (BRE-140).
    public shared ({ caller }) func requestDigitalDelivery(
        orderId : OrderId,
        lineIndex : Nat,
        ttlSeconds : ?Nat,
    ) : async Result<DigitalDeliveryResponse, DigitalDelivery.EntitlementError> {
        let order = switch (Map.get(orders, Map.n32hash, orderId)) {
            case (?o) o;
            case null {
                return #err(#NotFound("Order with ID " # Nat32.toText(orderId) # " not found"));
            };
        };

        if (lineIndex >= order.items.size()) {
            return #err(#InvalidLineIndex("Line index is out of range for this order"));
        };

        let line = order.items[lineIndex];
        let product = switch (Map.get(products, Map.n32hash, line.productId)) {
            case (?p) p;
            case null {
                return #err(#NotFound("Product not found for line item"));
            };
        };

        let { productId; variantId } = switch (
            DigitalDelivery.checkEntitlement(caller, order, lineIndex, product, media.mediaCanisterId)
        ) {
            case (#err(e)) { return #err(e) };
            case (#ok(ids)) ids;
        };

        let storedKey = Map.get(
            digitalAssetKeys,
            Map.thash,
            DigitalDelivery.digitalAssetMapKey(productId, variantId),
        );
        let mediaKey = DigitalDelivery.resolveMediaKey(storedKey, productId, variantId);
        let ttl = switch (ttlSeconds) {
            case null DigitalDelivery.DEFAULT_TTL_SECONDS;
            case (?seconds) {
                if (seconds == 0) {
                    return #err(#InvalidInput("TTL must be greater than zero"));
                };
                seconds;
            };
        };

        // Fail closed until the shop has a real key (BRE-55): a shop upgraded from the placeholder
        // key gets one from `generateHmacSecretKey`, which a failed first attempt retries here.
        if (not DeliveryToken.isUsableKey(media.hmacSecretKey)) {
            ignore generateHmacSecretKey();
            return #err(#MediaNotConfigured("This shop's delivery key isn't ready yet; try again shortly"));
        };

        let minted = DigitalDelivery.mintDeliveryToken({
            mediaKey = mediaKey;
            secretKey = media.hmacSecretKey;
            ttlSeconds = ttl;
            nonce = await randomDeliveryNonce();
        });

        logger.info("Issued delivery ticket for order " # Nat32.toText(orderId) # ", line " # debug_show (lineIndex) # " (expires in " # debug_show (ttl) # "s)");
        await* recordDigitalDelivery(orderId, lineIndex);
        #ok({
            token = minted.token;
            expiresAt = minted.expiresAt;
            mediaKey = mediaKey;
        });
    };
    /// Whether line `lineIndex` of order `orderId` is of a digital product.
    private func isDigitalLine(orderId : OrderId, lineIndex : Nat) : Bool {
        let ?order = Map.get(orders, Map.n32hash, orderId) else return false;
        if (lineIndex >= order.items.size()) return false;
        switch (Map.get(products, Map.n32hash, order.items[lineIndex].productId)) {
            case (?product) product.productType == #Digital;
            case null false;
        };
    };

    /// The release line `lineIndex` of order `orderId` sells, if `caller` bought it and it's paid.
    private func releaseBought(caller : Principal, orderId : OrderId, lineIndex : Nat) : Result<Music.ReleaseId, ReleaseDelivery.ReleaseDeliveryError> {
        let ?order = Map.get(orders, Map.n32hash, orderId) else return #err(#NotFound("Order with ID " # Nat32.toText(orderId) # " not found"));
        ReleaseDelivery.releaseFor(
            caller,
            order,
            lineIndex,
            func(variantId : VariantId) : ?Music.Deliverable {
                switch (Map.get(productVariants, Map.n32hash, variantId)) {
                    case (?variant) variant.deliverable;
                    case null null;
                };
            },
        );
    };

    /// Tickets for every file of the release order line `lineIndex` sells, in `format`, in track
    /// order (BRE-185). Only the order's buyer, once it is paid. The files are read from the release
    /// as it is now, so tracks added and files replaced since the sale are included; a track with no
    /// file in `format` is left out (`#FormatUnavailable` when none has one). Each link is
    /// `<vault URL><mediaKey>?token=<token>`, built by the client, and works until `expiresAt`. The
    /// first call for a line records it as delivered, as `requestDigitalDelivery` does. Signing is
    /// bounded by the release's track cap (`ReleaseDelivery.MAX_FILES`) and costs one `raw_rand`.
    public shared ({ caller }) func requestReleaseDelivery(
        orderId : OrderId,
        lineIndex : Nat,
        format : Music.AudioFormat,
        ttlSeconds : ?Nat,
    ) : async Result<ReleaseDelivery.ReleaseDeliveryResponse, ReleaseDelivery.ReleaseDeliveryError> {
        if (media.mediaCanisterId == null) {
            return #err(#MediaNotConfigured("Media canister is not configured for this shop"));
        };
        let releaseId = switch (releaseBought(caller, orderId, lineIndex)) {
            case (#err(e)) return #err(e);
            case (#ok(id)) id;
        };
        let ttl = switch (ttlSeconds) {
            case null DigitalDelivery.DEFAULT_TTL_SECONDS;
            case (?0) return #err(#InvalidInput("TTL must be greater than zero"));
            case (?seconds) seconds;
        };
        if (not DeliveryToken.isUsableKey(media.hmacSecretKey)) {
            ignore generateHmacSecretKey();
            return #err(#MediaNotConfigured("This shop's delivery key isn't ready yet; try again shortly"));
        };
        // Check the files before drawing randomness, so a format the release lacks costs nothing.
        switch (ReleaseDelivery.filesOf(music, releaseId, format)) {
            case (#err(e)) return #err(e);
            case (#ok(_)) {};
        };

        let seed = await icManagement.raw_rand();

        // Check again after the await: the order may have been refunded, or the release edited.
        switch (releaseBought(caller, orderId, lineIndex)) {
            case (#ok(id)) if (id != releaseId) return #err(#NotARelease("This order line's release changed; try again"));
            case (#err(e)) return #err(e);
        };
        let files = switch (ReleaseDelivery.filesOf(music, releaseId, format)) {
            case (#err(e)) return #err(e);
            case (#ok(f)) f;
        };
        var expiresAt : Nat64 = 0;
        let downloads = Array.tabulate<ReleaseDelivery.ReleaseDownload>(
            files.size(),
            func(i : Nat) : ReleaseDelivery.ReleaseDownload {
                let (trackId, file) = files[i];
                let minted = DigitalDelivery.mintDeliveryToken({
                    mediaKey = file.mediaKey;
                    secretKey = media.hmacSecretKey;
                    ttlSeconds = ttl;
                    nonce = ReleaseDelivery.fileNonce(seed, i);
                });
                expiresAt := minted.expiresAt;
                {
                    trackId;
                    format = file.format;
                    bytes = file.bytes;
                    mediaKey = file.mediaKey;
                    token = minted.token;
                };
            },
        );

        logger.info("Issued " # debug_show (downloads.size()) # " " # ReleaseDelivery.describe(format) # " tickets for release " # Nat32.toText(releaseId) # ", order " # Nat32.toText(orderId) # ", line " # debug_show (lineIndex));
        // A record that comes with its download still has to ship: only a digital line is delivered
        // by downloading it.
        if (isDigitalLine(orderId, lineIndex)) await* recordDigitalDelivery(orderId, lineIndex);
        #ok({ releaseId; format; expiresAt; files = downloads });
    };
};
