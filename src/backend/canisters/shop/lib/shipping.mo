import { type Result } "mo:core/Result";
import Array "mo:core/Array";

import ShippingAddressRules "../../../lib/ShippingAddress";

/// Which orders need a shipping address (BRE-23). What a valid one looks like lives in the shared
/// `lib/ShippingAddress`, which core's saved addresses use too (BRE-209). Types are restated here
/// (structurally equal to `../types`) because that module imports `canister:xrc`, which `mops test`
/// can't resolve.
module {
    public type ProductType = { #Physical; #Digital; #Service };

    public type ShippingAddress = ShippingAddressRules.ShippingAddress;

    public let MAX_FIELD_LENGTH = ShippingAddressRules.MAX_FIELD_LENGTH;

    /// Only physical goods are shipped. Digital goods are delivered through the vault, services need no delivery.
    public func requiresShipping(productType : ProductType) : Bool {
        productType == #Physical;
    };

    /// True when any of the cart's product types is shipped.
    public func anyRequiresShipping(productTypes : [ProductType]) : Bool {
        Array.any(productTypes, requiresShipping);
    };

    public let validateAddress = ShippingAddressRules.validate;

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
