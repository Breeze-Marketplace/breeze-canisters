import { suite; test; expect } "mo:test";

import VariantSkus "../variant_skus";

// Product 1 has variants 10 ("A") and 11 ("B"); product 2 has variant 20 ("C").
func lookup(sku : Text) : ?VariantSkus.StoredVariant {
    switch (sku) {
        case "A" ?{ id = 10 : Nat32; productId = 1 : Nat32 };
        case "B" ?{ id = 11 : Nat32; productId = 1 : Nat32 };
        case "C" ?{ id = 20 : Nat32; productId = 2 : Nat32 };
        case _ null;
    };
};

func plan(skus : [Text]) : VariantSkus.UpdatePlan {
    switch (VariantSkus.planUpdate(1, [10, 11], skus, lookup)) {
        case (#ok(p)) p;
        case (#err(e)) { assert false; loop {} };
    };
};

func isErr<T>(r : { #ok : T; #err : Text }) : Bool {
    switch (r) { case (#err(_)) true; case (#ok(_)) false };
};

suite(
    "VariantSkus.checkNoDuplicates",
    func() {
        test(
            "accepts distinct SKUs and an empty list",
            func() {
                assert not isErr(VariantSkus.checkNoDuplicates(["A", "B", "a"]));
                assert not isErr(VariantSkus.checkNoDuplicates([]));
            },
        );
        test(
            "rejects an SKU listed twice",
            func() {
                assert isErr(VariantSkus.checkNoDuplicates(["A", "B", "A"]));
            },
        );
    },
);

suite(
    "VariantSkus.planUpdate",
    func() {
        test(
            "keeps the product's own variants for their SKUs",
            func() {
                let p = plan(["B", "A"]);
                assert p.variantIds == [?11, ?10];
                assert p.removed == [];
            },
        );
        test(
            "new SKUs get new variants and left-out variants are removed",
            func() {
                let p = plan(["A", "NEW"]);
                assert p.variantIds == [?10, null];
                assert p.removed == [11];
            },
        );
        test(
            "a renamed SKU removes the old variant and adds a new one",
            func() {
                let p = plan(["A", "B2"]);
                assert p.variantIds == [?10, null];
                assert p.removed == [11];
            },
        );
        test(
            "an empty variant list removes every variant",
            func() {
                let p = plan([]);
                expect.nat(p.variantIds.size()).equal(0);
                assert p.removed == [10, 11];
            },
        );
        test(
            "rejects another product's SKU instead of taking its variant over",
            func() {
                assert isErr(VariantSkus.planUpdate(1, [10, 11], ["A", "C"], lookup));
            },
        );
        test(
            "rejects an SKU listed twice",
            func() {
                assert isErr(VariantSkus.planUpdate(1, [10, 11], ["A", "A"], lookup));
                assert isErr(VariantSkus.planUpdate(1, [10, 11], ["NEW", "NEW"], lookup));
            },
        );
        test(
            "reuses an indexed variant of this product missing from its variant list",
            func() {
                switch (VariantSkus.planUpdate(1, [10], ["A", "B"], lookup)) {
                    case (#ok(p)) {
                        assert p.variantIds == [?10, ?11];
                        assert p.removed == [];
                    };
                    case (#err(_)) assert false;
                };
            },
        );
    },
);
