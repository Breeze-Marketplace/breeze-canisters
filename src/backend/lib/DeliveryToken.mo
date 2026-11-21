import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Nat32 "mo:base/Nat32";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Debug "mo:base/Debug";

import HMAC "mo:hmac";
import Base64Lib "mo:base64";
import Hex "./Hex";

/// Self-contained HMAC delivery tickets for buyer-gated digital assets.
/// Layout (version 1): version(1) | exp_unix_be(8) | key_len_be(4) | media_key | nonce(16)
/// Wire form: base64url(message || tag) where tag = HMAC-SHA256(key, message).
module {
    func base64Url() : Base64Lib.Base64 {
        let v2 = Base64Lib.V2;
        Base64Lib.Base64(#v v2, ?true);
    };

    public let VERSION : Nat8 = 1;
    public let NONCE_LEN : Nat = 16;
    public let TAG_LEN : Nat = 32;
    public let MIN_MESSAGE_LEN : Nat = 29;

    /// Shortest HMAC key a shop or vault will sign or check tickets with. Shorter keys, including the
    /// 4-byte placeholder early shops were installed with (BRE-55), make delivery fail closed.
    public let MIN_KEY_LEN : Nat = 16;

    /// Whether `key` is long enough to sign or check delivery tickets with.
    public func isUsableKey(key : Blob) : Bool {
        key.size() >= MIN_KEY_LEN;
    };

    public type ParsedMessage = {
        version : Nat8;
        expUnix : Nat64;
        mediaKey : Text;
        nonce : Blob;
    };

    public type ValidationError = {
        #InvalidEncoding;
        #TokenTooShort;
        #UnsupportedVersion;
        #InvalidMessage;
        #InvalidTag;
        #Expired;
        #PathMismatch;
        #NonceReplay;
        #MissingKey;
    };

    public func normalizeAssetPath(path : Text) : Text {
        if (path.size() == 0) {
            return "/";
        };
        if (Text.startsWith(path, #text "/")) {
            return path;
        };
        "/" # path;
    };

    public func extractRequestPath(url : Text) : Text {
        switch (Text.split(url, #char '?').next()) {
            case (null) { "/" };
            case (?path) {
                if (path.size() == 0) { "/" } else { path };
            };
        };
    };

    public func decodeBase64Url(encoded : Text) : Result.Result<[Nat8], ValidationError> {
        if (encoded.size() == 0) {
            return #err(#InvalidEncoding);
        };
        let codec = base64Url();
        if (not codec.isValid(encoded)) {
            return #err(#InvalidEncoding);
        };
        #ok(codec.decode(encoded));
    };

    func readU64BE(bytes : [Nat8], offset : Nat) : Nat64 {
        var value : Nat64 = 0;
        for (i in Iter.range(0, 7)) {
            value := (value << 8) | Nat64.fromNat(Nat8.toNat(bytes[offset + i]));
        };
        value;
    };

    func readU32BE(bytes : [Nat8], offset : Nat) : Nat {
        var value : Nat32 = 0;
        for (i in Iter.range(0, 3)) {
            value := (value << 8) | Nat32.fromNat(Nat8.toNat(bytes[offset + i]));
        };
        Nat32.toNat(value);
    };

    func constantTimeEqual(a : [Nat8], b : [Nat8]) : Bool {
        if (a.size() != b.size()) {
            return false;
        };
        var diff : Nat8 = 0;
        for (i in a.keys()) {
            diff |= a[i] ^ b[i];
        };
        diff == 0;
    };

    public func parseMessage(bytes : [Nat8]) : Result.Result<ParsedMessage, ValidationError> {
        if (bytes.size() < MIN_MESSAGE_LEN) {
            return #err(#TokenTooShort);
        };

        let version = bytes[0];
        if (version != VERSION) {
            return #err(#UnsupportedVersion);
        };

        let expUnix = readU64BE(bytes, 1);
        let keyLen = readU32BE(bytes, 9);
        let messageEnd = 13 + keyLen + NONCE_LEN;
        if (bytes.size() != messageEnd) {
            return #err(#InvalidMessage);
        };

        let keyBytes = Array.tabulate<Nat8>(keyLen, func(i : Nat) : Nat8 { bytes[13 + i] });
        let mediaKey = switch (Text.decodeUtf8(Blob.fromArray(keyBytes))) {
            case (null) {
                return #err(#InvalidMessage);
            };
            case (?key) { normalizeAssetPath(key) };
        };

        let nonce = Blob.fromArray(Array.tabulate<Nat8>(NONCE_LEN, func(i : Nat) : Nat8 { bytes[13 + keyLen + i] }));

        #ok({
            version = version;
            expUnix = expUnix;
            mediaKey = mediaKey;
            nonce = nonce;
        });
    };

    public func computeTag(secretKey : Blob, message : [Nat8]) : Blob {
        HMAC.generate(Blob.toArray(secretKey), message.vals(), #sha256);
    };

    public func nonceKey(nonce : Blob) : Text {
        Hex.encode(Blob.toArray(nonce));
    };

    public func validate(
        tokenText : Text,
        requestPath : Text,
        secretKey : ?Blob,
        nowSeconds : Nat64,
    ) : Result.Result<ParsedMessage, ValidationError> {
        switch (secretKey) {
            case (null) {
                return #err(#MissingKey);
            };
            case (?key) {
                if (not isUsableKey(key)) {
                    return #err(#MissingKey);
                };
                let tokenBytes = switch (decodeBase64Url(tokenText)) {
                    case (#err(e)) {
                        return #err(e);
                    };
                    case (#ok(bytes)) { bytes };
                };

                if (tokenBytes.size() <= TAG_LEN) {
                    return #err(#TokenTooShort);
                };

                let messageSize = tokenBytes.size() - TAG_LEN;
                let message = Array.tabulate<Nat8>(messageSize, func(i : Nat) : Nat8 { tokenBytes[i] });
                let tag = Array.tabulate<Nat8>(TAG_LEN, func(i : Nat) : Nat8 { tokenBytes[messageSize + i] });

                let expectedTag = Blob.toArray(computeTag(key, message));
                if (not constantTimeEqual(tag, expectedTag)) {
                    return #err(#InvalidTag);
                };

                let parsed = switch (parseMessage(message)) {
                    case (#err(e)) {
                        return #err(e);
                    };
                    case (#ok(msg)) { msg };
                };

                if (parsed.expUnix < nowSeconds) {
                    return #err(#Expired);
                };

                let normalizedRequestPath = normalizeAssetPath(requestPath);
                if (parsed.mediaKey != normalizedRequestPath) {
                    return #err(#PathMismatch);
                };

                #ok(parsed);
            };
        };
    };

    public func isExpired(expUnix : Nat64, nowSeconds : Nat64) : Bool {
        expUnix < nowSeconds;
    };
};
