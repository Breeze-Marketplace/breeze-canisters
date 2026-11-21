import { type Result } "mo:core/Result";
import Array "mo:core/Array";
import Char "mo:core/Char";
import Text "mo:core/Text";

/// Which orders need a shipping address, and what a valid one looks like (BRE-23).
/// Types are restated here (structurally equal to `../types`) because that module imports `canister:xrc`,
/// which `mops test` can't resolve.
module {
    public type ProductType = { #Physical; #Digital; #Service };

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

    /// Longest accepted text for any address field, so buyers can't store unbounded text in an order.
    public let MAX_FIELD_LENGTH : Nat = 200;

    /// Only physical goods are shipped. Digital goods are delivered through the vault, services need no delivery.
    public func requiresShipping(productType : ProductType) : Bool {
        productType == #Physical;
    };

    /// True when any of the cart's product types is shipped.
    public func anyRequiresShipping(productTypes : [ProductType]) : Bool {
        Array.any(productTypes, requiresShipping);
    };

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
    public func validateAddress(address : ShippingAddress) : Result<(), Text> {
        let required = [("name", address.name), ("street address", address.line1), ("city", address.city)];
        for ((field, value) in required.vals()) {
            if (isBlank(value)) return #err("Shipping address needs a " # field);
        };
        if (not isCountryCode(address.country)) {
            return #err("Shipping address country must be a two-letter ISO 3166-1 code");
        };
        let optional = [address.line2, address.phone];
        let fields = [address.name, address.line1, address.city, address.region, address.postalCode];
        for (value in fields.vals()) {
            if (value.size() > MAX_FIELD_LENGTH) return #err("Shipping address fields are limited to 200 characters");
        };
        for (value in optional.vals()) {
            switch (value) {
                case (?v) if (v.size() > MAX_FIELD_LENGTH) return #err("Shipping address fields are limited to 200 characters");
                case null {};
            };
        };
        #ok;
    };

    /// The address to store on an order: required and checked when something is shipped, dropped otherwise, so a
    /// digital-only order keeps no buyer address it doesn't need.
    public func addressForOrder(needsShipping : Bool, address : ?ShippingAddress) : Result<?ShippingAddress, Text> {
        if (not needsShipping) return #ok(null);
        let ?a = address else return #err("A shipping address is required for physical items");
        switch (validateAddress(a)) {
            case (#ok) #ok(?a);
            case (#err(message)) #err(message);
        };
    };
};
