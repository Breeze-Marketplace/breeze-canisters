import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Time "mo:base/Time";

import { type Result } "mo:core/Result";
import Hmac "mo:hmac";
import Base64 "mo:base64";

import DeliveryToken "../../../lib/DeliveryToken";

import {
    type Order;
    type OrderStatus;
    type Product;
    type ProductId;
    type VariantId;
} "../types";

module {
    /// Wire format version byte in the token message (must match Media verifier).
    public let TOKEN_VERSION : Nat8 = 1;

    /// Random nonce length in the message (bytes).
    public let NONCE_SIZE : Nat = 16;

    /// HMAC-SHA256 tag length appended as suffix to the message.
    public let TAG_SIZE : Nat = 32;

    /// Default delivery ticket lifetime when the caller does not override TTL.
    public let DEFAULT_TTL_SECONDS : Nat = 3600;

    public type MintInput = {
        mediaKey : Text;
        secretKey : Blob;
        ttlSeconds : Nat;
        nonce : Blob;
    };

    public type MintResult = {
        token : Text;
        expiresAt : Nat64;
    };

    public type EntitlementError = {
        #NotFound : Text;
        #Unauthorized : Text;
        #NotDigitalProduct : Text;
        #OrderNotPaid : Text;
        #InvalidLineIndex : Text;
        #InvalidInput : Text;
        #MediaNotConfigured : Text;
    };

    public func digitalAssetMapKey(productId : ProductId, variantId : VariantId) : Text {
        Nat32.toText(productId) # ":" # Nat32.toText(variantId);
    };

    /// Default private object key when the merchant has not set an explicit media path.
    public func defaultMediaKey(productId : ProductId, variantId : VariantId) : Text {
        "/digital/" # Nat32.toText(productId) # "/" # Nat32.toText(variantId);
    };

    public func resolveMediaKey(
        storedKey : ?Text,
        productId : ProductId,
        variantId : VariantId,
    ) : Text {
        switch (storedKey) {
            // Keys stored before BRE-140 may lack the leading `/` the vault's asset paths have.
            case (?mediaKey) DeliveryToken.normalizeAssetPath(mediaKey);
            case null defaultMediaKey(productId, variantId);
        };
    };

    /// Builds `message # HMAC-SHA256(key, message)` and returns a base64url token.
    public func mintDeliveryToken(input : MintInput) : MintResult {
        let nowSeconds = nat64FromTimeSeconds(Time.now());
        let expiresAt = nowSeconds + Nat64.fromNat(input.ttlSeconds);
        let message = buildMessage({
            version = TOKEN_VERSION;
            expiresAt = expiresAt;
            mediaKey = input.mediaKey;
            nonce = input.nonce;
        });
        let tag = Hmac.generate(
            Blob.toArray(input.secretKey),
            message.vals(),
            #sha256,
        );
        let tokenBytes = Blob.fromArray(Array.append(message, Blob.toArray(tag)));
        {
            token = encodeTokenBase64Url(tokenBytes);
            expiresAt = expiresAt;
        };
    };

    private func encodeTokenBase64Url(tokenBytes : Blob) : Text {
        Base64.Base64(#v("2"), ?true).encode(#bytes(Blob.toArray(tokenBytes)));
    };

    public func checkEntitlement(
        caller : Principal,
        order : Order,
        lineIndex : Nat,
        product : Product,
        mediaCanisterId : ?Principal,
    ) : Result<{ productId : ProductId; variantId : VariantId }, EntitlementError> {
        switch (mediaCanisterId) {
            case null {
                return #err(#MediaNotConfigured("Media canister is not configured for this shop"));
            };
            case (?_) {};
        };

        if (not Principal.equal(caller, order.buyer)) {
            return #err(#Unauthorized("Only the order buyer can request digital delivery"));
        };

        if (not isOrderPaidForDigitalDelivery(order.status)) {
            return #err(#OrderNotPaid("Order must be paid before requesting digital delivery"));
        };

        if (product.productType != #Digital) {
            return #err(#NotDigitalProduct("Product is not a digital product"));
        };

        if (lineIndex >= order.items.size()) {
            return #err(#InvalidLineIndex("Line index is out of range for this order"));
        };

        let line = order.items[lineIndex];
        // Orders refuse empty lines now, but an older order may hold one that wasn't paid for.
        if (line.quantity == 0) {
            return #err(#InvalidLineIndex("This order line has no units, so nothing was bought on it"));
        };
        if (line.productId != product.id) {
            return #err(#InvalidLineIndex("Line item does not match the given product"));
        };

        #ok({ productId = line.productId; variantId = line.variantId });
    };

    public func isOrderPaidForDigitalDelivery(status : OrderStatus) : Bool {
        switch (status) {
            case (#paid) true;
            case (#processing) true;
            case (#partiallyFulfilled) true;
            case (#fulfilled) true;
            case (_) false;
        };
    };

    public type MessageFields = {
        version : Nat8;
        expiresAt : Nat64;
        mediaKey : Text;
        nonce : Blob;
    };

    /// Canonical binary message: `version(1) | exp_unix(8 BE) | key_len(4 BE) | key | nonce(16)`.
    public func buildMessage(fields : MessageFields) : [Nat8] {
        let keyBytes = Blob.toArray(Text.encodeUtf8(fields.mediaKey));
        let nonceBytes = Blob.toArray(fields.nonce);
        assert (nonceBytes.size() == NONCE_SIZE);
        let keyLen = Nat32.fromNat(keyBytes.size());
        Array.append(
            Array.append(
                [fields.version],
                nat64ToBeBytes(fields.expiresAt),
            ),
            Array.append(nat32ToBeBytes(keyLen), Array.append(keyBytes, nonceBytes)),
        );
    };

    private func nat64FromTimeSeconds(time : Int) : Nat64 {
        let seconds = if (time < 0) { 0 } else { Int.abs(time / 1_000_000_000) };
        Nat64.fromNat(seconds);
    };

    private func nat64ToBeBytes(n : Nat64) : [Nat8] {
        func byte(shift : Nat64) : Nat8 {
            Nat8.fromNat(Nat64.toNat((n >> shift) % 256));
        };
        [byte(56), byte(48), byte(40), byte(32), byte(24), byte(16), byte(8), byte(0)];
    };

    private func nat32ToBeBytes(n : Nat32) : [Nat8] {
        let v = Nat32.toNat(n);
        [
            Nat8.fromNat(v / 16777216 % 256),
            Nat8.fromNat(v / 65536 % 256),
            Nat8.fromNat(v / 256 % 256),
            Nat8.fromNat(v % 256),
        ];
    };
};
