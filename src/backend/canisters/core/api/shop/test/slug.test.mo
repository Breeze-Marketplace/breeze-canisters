import { expect; suite; test } "mo:test";
import Array "mo:core/Array";
import Principal "mo:core/Principal";

import Slug "../slug";

func valid(slug : Text) : Bool = Slug.isValid(slug);

suite(
    "Slug.validate",
    func() {
        test(
            "accepts lowercase letters, digits and single hyphens",
            func() {
                expect.bool(valid("blue-heron-books")).isTrue();
                expect.bool(valid("abc")).isTrue();
                expect.bool(valid("shop-2")).isTrue();
                expect.bool(valid("24-7-deli")).isTrue();
            },
        );
        test(
            "refuses slugs that are too short or too long",
            func() {
                expect.bool(valid("ab")).isFalse();
                expect.bool(valid("")).isFalse();
                expect.bool(valid("a234567890123456789012345678901234567890")).isTrue(); // 40
                expect.bool(valid("a2345678901234567890123456789012345678901")).isFalse(); // 41
            },
        );
        test(
            "refuses other characters, edge hyphens and double hyphens",
            func() {
                expect.bool(valid("Blue-Heron")).isFalse();
                expect.bool(valid("blue heron")).isFalse();
                expect.bool(valid("blue_heron")).isFalse();
                expect.bool(valid("café-bar")).isFalse();
                expect.bool(valid("a/b?c")).isFalse();
                expect.bool(valid("-blue")).isFalse();
                expect.bool(valid("blue-")).isFalse();
                expect.bool(valid("blue--heron")).isFalse();
            },
        );
        test(
            "refuses route words",
            func() {
                for (word in ["new", "admin", "cart", "checkout", "orders", "products"].values()) {
                    expect.bool(valid(word)).isFalse();
                };
                expect.bool(valid("new-shop")).isTrue();
            },
        );
        test(
            "refuses anything that parses as a principal",
            func() {
                for (
                    id in [
                        "rdmx6-jaaaa-aaaaa-aaadq-cai",
                        "ryjl3-tyaaa-aaaaa-aaaba-cai",
                        "aaaaa-aa",
                        "2vxsx-fae",
                    ].values()
                ) {
                    expect.bool(Slug.isPrincipalText(id)).isTrue();
                    expect.bool(valid(id)).isFalse();
                };
                let user = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
                expect.bool(valid(user.toText())).isFalse();
            },
        );
        test(
            "accepts words shaped like principal groups that aren't principals",
            func() {
                expect.bool(Slug.isPrincipalText("hello-world")).isFalse();
                expect.bool(Slug.isPrincipalText("great-books")).isFalse();
                expect.bool(Slug.isPrincipalText("rdmx6-jaaaa-aaaaa-aaadq-caa")).isFalse(); // bad checksum
                expect.bool(valid("hello-world")).isTrue();
            },
        );
    },
);

suite(
    "Slug.fromName",
    func() {
        test(
            "lowercases and turns other characters into single hyphens",
            func() {
                expect.text(Slug.fromName("Blue Heron Books")).equal("blue-heron-books");
                expect.text(Slug.fromName("  Tom's  Café & Bar!! ")).equal("tom-s-caf-bar");
                expect.text(Slug.fromName("A/B?C#D")).equal("a-b-c-d");
            },
        );
        test(
            "cuts long names to 40 characters without a trailing hyphen",
            func() {
                let slug = Slug.fromName("The Very Long Name Of A Shop That Sells Many Things");
                expect.bool(slug.size() <= Slug.MAX_LENGTH).isTrue();
                expect.bool(valid(slug)).isTrue();
                expect.text(slug).equal("the-very-long-name-of-a-shop-that-sells");
            },
        );
        test(
            "pads names that would be too short, reserved or a principal",
            func() {
                expect.text(Slug.fromName("Al")).equal("al-shop");
                expect.text(Slug.fromName("Cart")).equal("cart-shop");
                expect.text(Slug.fromName("aaaaa-aa")).equal("aaaaa-aa-shop");
                expect.text(Slug.fromName("日本")).equal("my-shop");
                expect.text(Slug.fromName("")).equal("my-shop");
            },
        );
    },
);

suite(
    "Slug.unique",
    func() {
        test(
            "adds the first free numeric suffix",
            func() {
                let taken = ["books", "books-2"];
                let slug = Slug.unique("books", func s = Array.find<Text>(taken, func t = t == s) == null);
                expect.text(slug).equal("books-3");
                expect.text(Slug.unique("books-3", func _ = true)).equal("books-3");
            },
        );
        test(
            "keeps a suffixed slug within 40 characters",
            func() {
                let base = "a234567890123456789012345678901234567890";
                let slug = Slug.unique(base, func s = s != base);
                expect.text(slug).equal("a2345678901234567890123456789012345678-2");
                expect.bool(valid(slug)).isTrue();
            },
        );
    },
);
