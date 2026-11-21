import { type Result } "mo:core/Result";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Set "mo:core/Set";
import Text "mo:core/Text";

/// Limits and checks for variant attributes (e.g. Color = Black) and a product's attribute config,
/// which the product page groups into one option picker per key.
module VariantAttributes {
    // Same as `types.mo`'s, which tests can't import (it imports `canister:xrc`).
    type ProductAttribute = { key : Text; value : Text };
    type ProductAttributeConfig = [(key : Text, values : [Text])];

    public let MAX_KEYS = 5;
    public let MAX_KEY_LENGTH = 32;
    public let MAX_VALUE_LENGTH = 64;
    public let MAX_VALUES_PER_KEY = 50;

    func checkText(what : Text, text : Text, maxLength : Nat) : Result<(), Text> {
        if (Text.trim(text, #char ' ') == "") return #err(what # " must not be empty");
        if (text.size() > maxLength) {
            return #err(what # " \"" # text # "\" is longer than " # Nat.toText(maxLength) # " characters");
        };
        #ok;
    };

    func sortedKeys(attributes : [ProductAttribute]) : [Text] {
        Array.sort(Array.map<ProductAttribute, Text>(attributes, func(a) = a.key), Text.compare);
    };

    /// One variant's attributes: at most `MAX_KEYS`, non-empty bounded keys and values, no repeated key.
    public func validateVariant(variantName : Text, attributes : [ProductAttribute]) : Result<(), Text> {
        if (attributes.size() > MAX_KEYS) {
            return #err("Variant \"" # variantName # "\" has more than " # Nat.toText(MAX_KEYS) # " attributes");
        };
        let keys = Set.empty<Text>();
        for (attribute in attributes.values()) {
            switch (checkText("Attribute name", attribute.key, MAX_KEY_LENGTH)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            switch (checkText("Value of " # attribute.key, attribute.value, MAX_VALUE_LENGTH)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            if (Set.contains(keys, Text.compare, attribute.key)) {
                return #err("Variant \"" # variantName # "\" repeats attribute " # attribute.key);
            };
            Set.add(keys, Text.compare, attribute.key);
        };
        #ok;
    };

    /// All of a product's variants: each valid, the same attribute names on every variant (or none on
    /// any), and no two variants with the same values, so a buyer's picks name exactly one variant.
    public func validateProduct(variants : [{ name : Text; attributes : [ProductAttribute] }]) : Result<(), Text> {
        if (variants.size() == 0) return #ok;
        for (variant in variants.values()) {
            switch (validateVariant(variant.name, variant.attributes)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
        };
        let first = variants[0];
        let expectedKeys = sortedKeys(first.attributes);
        if (expectedKeys.size() == 0) {
            for (variant in variants.values()) {
                if (variant.attributes.size() > 0) {
                    return #err("Variant \"" # variant.name # "\" has attributes but \"" # first.name # "\" has none; give every variant the same attributes");
                };
            };
            return #ok;
        };
        let combinations = Set.empty<Text>();
        for (variant in variants.values()) {
            if (sortedKeys(variant.attributes) != expectedKeys) {
                return #err("Variant \"" # variant.name # "\" must have the attributes " # Text.join(expectedKeys.values(), ", "));
            };
            let sorted = Array.sort<ProductAttribute>(variant.attributes, func(a, b) = Text.compare(a.key, b.key));
            let combination = Text.join(Array.map<ProductAttribute, Text>(sorted, func(a) = a.value).values(), "\u{1F}");
            if (Set.contains(combinations, Text.compare, combination)) {
                return #err("Two variants have the same attribute values as \"" # variant.name # "\"");
            };
            Set.add(combinations, Text.compare, combination);
        };
        #ok;
    };

    /// A product's attribute config (key order and value order for the product page): at most
    /// `MAX_KEYS` distinct keys, each with at most `MAX_VALUES_PER_KEY` distinct values, all bounded.
    public func validateConfig(config : ProductAttributeConfig) : Result<(), Text> {
        if (config.size() > MAX_KEYS) return #err("At most " # Nat.toText(MAX_KEYS) # " attributes");
        let keys = Set.empty<Text>();
        for ((key, values) in config.values()) {
            switch (checkText("Attribute name", key, MAX_KEY_LENGTH)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            if (Set.contains(keys, Text.compare, key)) return #err("Attribute " # key # " is listed twice");
            Set.add(keys, Text.compare, key);
            if (values.size() > MAX_VALUES_PER_KEY) {
                return #err("Attribute " # key # " has more than " # Nat.toText(MAX_VALUES_PER_KEY) # " values");
            };
            let seen = Set.empty<Text>();
            for (value in values.values()) {
                switch (checkText("Value of " # key, value, MAX_VALUE_LENGTH)) {
                    case (#err(e)) return #err(e);
                    case (#ok) {};
                };
                if (Set.contains(seen, Text.compare, value)) return #err("Attribute " # key # " lists " # value # " twice");
                Set.add(seen, Text.compare, value);
            };
        };
        #ok;
    };
};
