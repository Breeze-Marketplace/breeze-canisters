import { type Result } "mo:core/Result";
import Char "mo:core/Char";
import Text "mo:core/Text";

/// What a valid shipping address looks like (BRE-23). Shared by the shop, which stores one on each
/// order, and core, which keeps each user's saved addresses (BRE-209), so both accept the same ones.
module {
    public type ShippingAddress = {
        name : Text;
        phone : ?Text;
        line1 : Text;
        line2 : ?Text;
        city : Text;
        region : Text;
        postalCode : Text;
        country : Text;
    };

    /// Longest accepted text for any address field, so callers can't store unbounded text.
    public let MAX_FIELD_LENGTH : Nat = 200;

    /// ISO 3166-1 alpha-2 code: two uppercase ASCII letters, e.g. "US", "DE", "JP".
    public func isCountryCode(country : Text) : Bool {
        if (country.size() != 2) return false;
        for (c in country.chars()) {
            if (c < 'A' or c > 'Z') return false;
        };
        true;
    };

    func isBlank(text : Text) : Bool {
        Text.trim(text, #predicate(Char.isWhitespace)) == "";
    };

    /// Checks a shipping address. Name, street, city and country are required; region and postal code are
    /// optional, since many countries have neither. Every field is capped at `MAX_FIELD_LENGTH` characters.
    public func validate(address : ShippingAddress) : Result<(), Text> {
        let required = [("name", address.name), ("street address", address.line1), ("city", address.city)];
        for ((field, value) in required.values()) {
            if (isBlank(value)) return #err("Shipping address needs a " # field);
        };
        if (not isCountryCode(address.country)) {
            return #err("Shipping address country must be a two-letter ISO 3166-1 code");
        };
        let optional = [address.line2, address.phone];
        let fields = [address.name, address.line1, address.city, address.region, address.postalCode];
        for (value in fields.values()) {
            if (value.size() > MAX_FIELD_LENGTH) return #err("Shipping address fields are limited to 200 characters");
        };
        for (value in optional.values()) {
            switch (value) {
                case (?v) if (v.size() > MAX_FIELD_LENGTH) return #err("Shipping address fields are limited to 200 characters");
                case null {};
            };
        };
        #ok;
    };
};
