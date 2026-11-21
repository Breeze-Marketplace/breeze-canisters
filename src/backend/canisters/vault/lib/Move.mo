import Char "mo:core/Char";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";
import Assets "mo:assets";

/// Moves an asset to another key without copying its content: `mo:assets` keeps an asset's content
/// apart from its key, so the same asset is filed under the new key and dropped from the old one.
module {
    public let maxKeyLength = 1_024;

    public type Error = {
        #notFound;
        #exists;
        #invalidKey;
    };

    public func errorMessage(error : Error) : Text = switch error {
        case (#notFound) "asset not found";
        case (#exists) "an asset already has that key";
        case (#invalidKey) "invalid asset key";
    };

    /// A character a library key may hold: printable ASCII other than `?` and `#`, which end a URL's
    /// path, and `%`, which starts an escape. `mo:assets` decodes escapes byte by byte, so anything
    /// beyond ASCII wouldn't survive the trip through a URL.
    public func isUrlSafeChar(c : Char) : Bool {
        let n = c.toNat32();
        n >= 0x20 and n <= 0x7E and c != '?' and c != '#' and c != '%';
    };

    /// A key HTTP can serve and look up again: it starts with `/` and holds only `isUrlSafeChar`s.
    public func isServableKey(key : Text) : Bool {
        if (not key.startsWith(#text "/") or key.size() <= 1 or key.size() > maxKeyLength) return false;
        for (c in key.chars()) {
            if (not isUrlSafeChar(c)) return false;
        };
        true;
    };

    public func moveAsset(assets : Assets.Assets, from : Text, to : Text) : {
        #ok;
        #err : Error;
    } {
        if (not isServableKey(to)) return #err(#invalidKey);
        let ?asset = assets.assets.get(from) else return #err(#notFound);
        if (from == to) return #ok;
        switch (assets.assets.get(to)) {
            case (?_) return #err(#exists);
            case null {};
        };
        assets.assets.put(to, asset);
        assets.assets.delete(from);
        #ok;
    };
};
