import Char "mo:core/Char";
import Nat32 "mo:core/Nat32";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

import DeliveryToken "../../../lib/DeliveryToken";
import Delivery "Delivery";
import Writers "Writers";

/// Which assets are private, who may read them, and how a delivery ticket rides along a streamed
/// download. A key is private when it is under `/private/`; every other key is public.
module {
    public let privatePrefix = "/private/";

    public func isPrivate(key : Text) : Bool = DeliveryToken.normalizeAssetPath(key).startsWith(#text privatePrefix);

    /// Writers read everything; anyone else reads public keys only.
    public func canRead(writers : Writers.Writers, caller : Principal, key : Text) : Bool = not isPrivate(key) or Writers.isWriter(writers, caller);

    /// Traps with the message `mo:assets` uses, which the frontend recognizes.
    public func requireReadable(writers : Writers.Writers, caller : Principal, key : Text) {
        if (not canRead(writers, caller, key)) {
            Runtime.trap("not authorized");
        };
    };

    /// `mo:assets` percent-decodes the URL path before looking up the key, so `/%70rivate/x` serves
    /// `/private/x`. Privacy must be decided on the same decoded path. Mirrors `mo:assets`' decoder:
    /// `%%` is `%`, `%XY` is the character with code 0xXY, and anything else after `%` is an error.
    public func decodePath(encoded : Text) : ?Text {
        var decoded = "";
        let chars = encoded.chars();
        loop {
            switch (chars.next()) {
                case null return ?decoded;
                case (?'%') {
                    switch (chars.next()) {
                        case null return null;
                        case (?'%') decoded #= "%";
                        case (?first) {
                            let ?second = chars.next() else return null;
                            let (?hi, ?lo) = (hexNibble(first), hexNibble(second)) else return null;
                            decoded #= Char.fromNat32(hi << 4 | lo).toText();
                        };
                    };
                };
                case (?c) decoded #= c.toText();
            };
        };
    };

    func hexNibble(c : Char) : ?Nat32 {
        let n = c.toNat32();
        if (n >= 0x30 and n <= 0x39) return ?(n - 0x30);
        if (n >= 0x61 and n <= 0x66) return ?(n - 0x61 + 10);
        if (n >= 0x41 and n <= 0x46) return ?(n - 0x41 + 10);
        null;
    };

    /// The HTTP gateway hands a streaming token back to the callback unchanged, and the callback is a
    /// public query anyone can call with any token. So a private download's token carries its ticket
    /// in the key, and the callback checks it again for every chunk.
    public func keyWithTicket(key : Text, ticket : Text) : Text = key # "?token=" # ticket;

    /// The key and the ticket carried by `keyWithTicket`, if any.
    public func splitTicketKey(tokenKey : Text) : (Text, ?Text) {
        (DeliveryToken.extractRequestPath(tokenKey), Delivery.queryToken(tokenKey));
    };
};
