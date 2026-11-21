import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Text "mo:core/Text";

/// Shop slugs (BRE-71): the readable part of a shop's URL, `/shop/<slug>`. Lowercase `a-z`, `0-9`
/// and single hyphens, `MIN_LENGTH` to `MAX_LENGTH` characters, no leading or trailing hyphen. A
/// slug is never a route word (`RESERVED`) or the text of a principal, so the frontend can tell a
/// slug from a canister ID.
module {
    public let MIN_LENGTH = 3;
    public let MAX_LENGTH = 40;

    /// Words the frontend's routes use, or might, next to `/shop/<slug>`.
    public let RESERVED : [Text] = [
        "about",
        "account",
        "admin",
        "api",
        "cart",
        "checkout",
        "control",
        "costs",
        "dashboard",
        "edit",
        "funds",
        "help",
        "inventory",
        "invoice",
        "legal",
        "login",
        "logout",
        "media",
        "new",
        "orders",
        "policies",
        "products",
        "search",
        "sell",
        "settings",
        "shop",
        "shops",
        "support",
        "wallet",
    ];

    public func isReserved(slug : Text) : Bool {
        Array.find<Text>(RESERVED, func w = w == slug) != null;
    };

    func isSlugChar(c : Char) : Bool {
        (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
    };

    /// True if `text` is the textual form of a principal: base32 of a CRC-32 and the principal's
    /// bytes, in hyphen-separated groups of five. Checked by decoding it and encoding it again.
    public func isPrincipalText(text : Text) : Bool {
        let bytes = List.empty<Nat8>();
        var buffer : Nat32 = 0;
        var bits : Nat32 = 0;
        for (c in text.chars()) {
            if (c != '-') {
                let n = Char.toNat32(c);
                let value : Nat32 = if (c >= 'a' and c <= 'z') { n - 97 } else if (c >= '2' and c <= '7') {
                    n - 50 + 26;
                } else { return false };
                buffer := ((buffer << 5) | value) & 0xFFFF;
                bits += 5;
                if (bits >= 8) {
                    bits -= 8;
                    bytes.add(Nat8.fromNat32((buffer >> bits) & 0xFF));
                };
            };
        };
        // A principal is at most 29 bytes, after the 4-byte checksum.
        if (bytes.size() < 4 or bytes.size() > 33) { return false };
        let body = Array.sliceToArray(bytes.toArray(), 4, bytes.size());
        Principal.fromBlob(Blob.fromArray(body)).toText() == text;
    };

    /// Checks `slug` against the rules above. The error is a message for the merchant.
    public func validate(slug : Text) : Result<(), Text> {
        let size = slug.size();
        if (size < MIN_LENGTH or size > MAX_LENGTH) {
            return #err("A shop URL must be " # Nat.toText(MIN_LENGTH) # " to " # Nat.toText(MAX_LENGTH) # " characters long");
        };
        var previousHyphen = true; // so a leading hyphen is refused
        for (c in slug.chars()) {
            if (c == '-') {
                if (previousHyphen) {
                    return #err("A shop URL can't start with a hyphen or have two in a row");
                };
                previousHyphen := true;
            } else if (isSlugChar(c)) {
                previousHyphen := false;
            } else {
                return #err("A shop URL can only have lowercase letters, digits and hyphens");
            };
        };
        if (previousHyphen) {
            return #err("A shop URL can't end with a hyphen");
        };
        if (isReserved(slug)) {
            return #err("\"" # slug # "\" is reserved");
        };
        if (isPrincipalText(slug)) {
            return #err("A shop URL can't look like a canister ID");
        };
        #ok;
    };

    public func isValid(slug : Text) : Bool {
        switch (validate(slug)) { case (#ok) true; case (#err(_)) false };
    };

    /// The first `n` characters of `text`, without a trailing hyphen.
    func take(text : Text, n : Nat) : Text {
        var out = "";
        var count = 0;
        label chars for (c in text.chars()) {
            if (count >= n) break chars;
            out #= Char.toText(c);
            count += 1;
        };
        Text.trimEnd(out, #char '-');
    };

    /// A slug made from a shop name: lowercased, every run of other characters turned into one
    /// hyphen, cut to `MAX_LENGTH`. Padded with `-shop` when that leaves it too short, reserved or a
    /// principal. Always valid, but not necessarily free: see `unique`.
    public func fromName(name : Text) : Text {
        var out = "";
        var size = 0;
        var previousHyphen = true;
        label chars for (c in Text.toLower(name).chars()) {
            if (size >= MAX_LENGTH) break chars;
            if (isSlugChar(c)) {
                out #= Char.toText(c);
                size += 1;
                previousHyphen := false;
            } else if (not previousHyphen) {
                out #= "-";
                size += 1;
                previousHyphen := true;
            };
        };
        let base = Text.trimEnd(out, #char '-');
        if (base == "") { return "my-shop" };
        if (isValid(base)) { return base };
        let padded = take(base, MAX_LENGTH - 5) # "-shop";
        if (isValid(padded)) { padded } else { "my-shop" };
    };

    /// `base` with `-n` on the end, cut so it fits in `MAX_LENGTH`.
    public func withSuffix(base : Text, n : Nat) : Text {
        let suffix = "-" # Nat.toText(n);
        take(base, MAX_LENGTH - suffix.size()) # suffix;
    };

    /// `base`, or the first of `base-2`, `base-3`, … that is valid and `available`. `base` must be
    /// valid (from `fromName`). Ends: only finitely many slugs are taken.
    public func unique(base : Text, available : Text -> Bool) : Text {
        if (isValid(base) and available(base)) { return base };
        var n = 2;
        loop {
            let candidate = withSuffix(base, n);
            if (isValid(candidate) and available(candidate)) {
                return candidate;
            };
            n += 1;
        };
    };
};
