import Iter "mo:core/Iter";
import Map "mo:core/Map";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Time "mo:core/Time";

import DeliveryToken "../../../lib/DeliveryToken";

/// Checks delivery tickets for `/private/` assets and remembers used nonces so a ticket works once.
module {
    public type Result = {
        #ok : DeliveryToken.ParsedMessage;
        #err : DeliveryToken.ValidationError;
    };

    /// The `token` query parameter of `url`, if any (the last one wins).
    public func queryToken(url : Text) : ?Text {
        var tokenValue : ?Text = null;
        for (segment in url.split(#char '?')) {
            for (part in segment.split(#char '&')) {
                if (part.startsWith(#text "token=")) {
                    tokenValue := ?part.trimStart(#text "token=");
                };
            };
        };
        tokenValue;
    };

    func nowSeconds() : Nat64 {
        Nat64.fromIntWrap(Time.now() / 1_000_000_000);
    };

    /// Nonces are kept in memory only (build this as a `transient let`), so an upgrade forgets them;
    /// tickets are short-lived.
    public class Gate(hmacSecretKey : () -> ?Blob) {
        let usedNonces = Map.empty<Text, Nat64>();

        func pruneExpired(now : Nat64) {
            let expired = usedNonces.entries().filter(func((_, expUnix)) = DeliveryToken.isExpired(expUnix, now)).map(func((key, _)) = key).toArray();
            for (key in expired.values()) {
                usedNonces.remove(key);
            };
        };

        /// Validates `token` for a later chunk of a download it already opened: signature, path and
        /// expiry, but not the nonce, which opening the download may have consumed. A used ticket
        /// still can't start a download, since every start checks the nonce.
        public func validateContinuation(token : Text, requestPath : Text) : Result {
            DeliveryToken.validate(token, requestPath, hmacSecretKey(), nowSeconds());
        };

        /// Validates `token` for `requestPath`. When `consumeNonce`, the ticket can't be used again.
        public func validate(token : Text, requestPath : Text, consumeNonce : Bool) : Result {
            let now = nowSeconds();
            pruneExpired(now);

            switch (DeliveryToken.validate(token, requestPath, hmacSecretKey(), now)) {
                case (#err(e)) { #err(e) };
                case (#ok(parsed)) {
                    let key = DeliveryToken.nonceKey(parsed.nonce);
                    if (usedNonces.containsKey(key)) {
                        return #err(#NonceReplay);
                    };
                    if (consumeNonce) {
                        usedNonces.add(key, parsed.expUnix);
                    };
                    #ok(parsed);
                };
            };
        };
    };
};
