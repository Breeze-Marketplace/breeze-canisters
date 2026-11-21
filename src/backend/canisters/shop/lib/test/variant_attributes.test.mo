import { suite; test } "mo:test";
import Array "mo:core/Array";
import Text "mo:core/Text";

import VariantAttributes "../variant_attributes";

func isOk(r : { #ok; #err : Text }) : Bool {
    switch (r) { case (#ok) true; case (#err(_)) false };
};

func tee(color : Text, size : Text) : {
    name : Text;
    attributes : [{ key : Text; value : Text }];
} {
    {
        name = color # " / " # size;
        attributes = [{ key = "Color"; value = color }, { key = "Size"; value = size }];
    };
};

func repeat(n : Nat) : Text = Text.join(Array.repeat("a", n).values(), "");

suite(
    "VariantAttributes.validateVariant",
    func() {
        test(
            "accepts up to MAX_KEYS attributes and rejects more",
            func() {
                let attrs = Array.tabulate<{ key : Text; value : Text }>(
                    VariantAttributes.MAX_KEYS,
                    func(i) = { key = "k" # debug_show i; value = "v" },
                );
                assert isOk(VariantAttributes.validateVariant("v", attrs));
                let tooMany = Array.concat(attrs, [{ key = "extra"; value = "v" }]);
                assert not isOk(VariantAttributes.validateVariant("v", tooMany));
            },
        );
        test(
            "rejects empty or blank keys and values",
            func() {
                assert not isOk(VariantAttributes.validateVariant("v", [{ key = ""; value = "Black" }]));
                assert not isOk(VariantAttributes.validateVariant("v", [{ key = "  "; value = "Black" }]));
                assert not isOk(VariantAttributes.validateVariant("v", [{ key = "Color"; value = "" }]));
            },
        );
        test(
            "bounds key and value lengths",
            func() {
                let maxKey = repeat(VariantAttributes.MAX_KEY_LENGTH);
                let maxValue = repeat(VariantAttributes.MAX_VALUE_LENGTH);
                assert isOk(VariantAttributes.validateVariant("v", [{ key = maxKey; value = maxValue }]));
                assert not isOk(VariantAttributes.validateVariant("v", [{ key = maxKey # "a"; value = "x" }]));
                assert not isOk(VariantAttributes.validateVariant("v", [{ key = "k"; value = maxValue # "a" }]));
            },
        );
        test(
            "rejects a repeated key",
            func() {
                let attrs = [{ key = "Color"; value = "Black" }, { key = "Color"; value = "White" }];
                assert not isOk(VariantAttributes.validateVariant("v", attrs));
            },
        );
    },
);

suite(
    "VariantAttributes.validateProduct",
    func() {
        test(
            "accepts no variants, and variants with no attributes",
            func() {
                assert isOk(VariantAttributes.validateProduct([]));
                assert isOk(VariantAttributes.validateProduct([{ name = "a"; attributes = [] }, { name = "b"; attributes = [] }]));
            },
        );
        test(
            "accepts the same keys in any order",
            func() {
                let reordered = {
                    name = "White / S";
                    attributes = [{ key = "Size"; value = "S" }, { key = "Color"; value = "White" }];
                };
                assert isOk(VariantAttributes.validateProduct([tee("Black", "M"), tee("Black", "L"), reordered]));
            },
        );
        test(
            "rejects attributes on only some variants",
            func() {
                assert not isOk(VariantAttributes.validateProduct([tee("Black", "M"), { name = "plain"; attributes = [] }]));
                assert not isOk(VariantAttributes.validateProduct([{ name = "plain"; attributes = [] }, tee("Black", "M")]));
            },
        );
        test(
            "rejects variants with different keys",
            func() {
                let colorOnly = {
                    name = "Black";
                    attributes = [{ key = "Color"; value = "Black" }];
                };
                assert not isOk(VariantAttributes.validateProduct([tee("Black", "M"), colorOnly]));
                let otherKey = {
                    name = "Black / Cotton";
                    attributes = [{ key = "Color"; value = "Black" }, { key = "Fabric"; value = "Cotton" }];
                };
                assert not isOk(VariantAttributes.validateProduct([tee("Black", "M"), otherKey]));
            },
        );
        test(
            "rejects two variants with the same values",
            func() {
                assert not isOk(VariantAttributes.validateProduct([tee("Black", "M"), tee("White", "M"), tee("Black", "M")]));
            },
        );
        test(
            "rejects an invalid variant",
            func() {
                assert not isOk(VariantAttributes.validateProduct([tee("Black", "M"), tee("", "L")]));
            },
        );
    },
);

suite(
    "VariantAttributes.validateConfig",
    func() {
        test(
            "accepts an empty config and a Color / Size config",
            func() {
                assert isOk(VariantAttributes.validateConfig([]));
                assert isOk(VariantAttributes.validateConfig([("Color", ["Black", "White"]), ("Size", ["S", "M", "L", "XL", "XXL"])]));
            },
        );
        test(
            "rejects a repeated key or value",
            func() {
                assert not isOk(VariantAttributes.validateConfig([("Color", ["Black"]), ("Color", ["White"])]));
                assert not isOk(VariantAttributes.validateConfig([("Color", ["Black", "Black"])]));
            },
        );
        test(
            "bounds the number of keys and values",
            func() {
                let keys = Array.tabulate<(Text, [Text])>(VariantAttributes.MAX_KEYS + 1, func(i) = ("k" # debug_show i, ["v"]));
                assert not isOk(VariantAttributes.validateConfig(keys));
                let values = Array.tabulate<Text>(VariantAttributes.MAX_VALUES_PER_KEY + 1, func(i) = "v" # debug_show i);
                assert not isOk(VariantAttributes.validateConfig([("Size", values)]));
            },
        );
        test(
            "rejects empty and overlong names and values",
            func() {
                assert not isOk(VariantAttributes.validateConfig([("", ["Black"])]));
                assert not isOk(VariantAttributes.validateConfig([("Color", [""])]));
                assert not isOk(VariantAttributes.validateConfig([(repeat(VariantAttributes.MAX_KEY_LENGTH + 1), ["x"])]));
                assert not isOk(VariantAttributes.validateConfig([("Color", [repeat(VariantAttributes.MAX_VALUE_LENGTH + 1)])]));
            },
        );
    },
);
