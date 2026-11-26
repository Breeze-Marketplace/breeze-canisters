import { expect; suite; test } "mo:test";

import Array "mo:core/Array";

import Music "../music";
import ReleaseSales "../release_sales";

type VariantId = ReleaseSales.VariantId;
type Variant = ReleaseSales.ReleaseVariant;

let soldRelease : Music.ReleaseId = 1;
let unsoldRelease : Music.ReleaseId = 2;

let soldReleaseVariant : Variant = {
    id = 10;
    deliverable = ?#release(soldRelease);
};
let unsoldReleaseVariant : Variant = {
    id = 11;
    deliverable = ?#release(unsoldRelease);
};
let plainVariant : Variant = { id = 12; deliverable = null };

func libraryWithSoldRelease() : Music.Library {
    let library = Music.emptyLibrary();
    Music.markSold(library, soldRelease);
    library;
};

func order(status : ReleaseSales.OrderStatus, variantIds : [VariantId]) : ReleaseSales.SaleRecord {
    {
        status;
        items = variantIds.map(func(variantId : VariantId) : { variantId : VariantId } = { variantId });
    };
};

func soldIds(orders : [ReleaseSales.SaleRecord], variants : [Variant]) : [VariantId] {
    ReleaseSales.soldReleaseVariants(libraryWithSoldRelease(), orders.values(), variants).map(func(v : Variant) : VariantId = v.id);
};

func expectIds(actual : [VariantId], expected : [VariantId]) {
    expect.text(debug_show (actual)).equal(debug_show (expected));
};

let allVariants = [soldReleaseVariant, unsoldReleaseVariant, plainVariant];

suite(
    "ReleaseSales.soldReleaseVariants",
    func() {
        test(
            "returns a variant selling a sold release that a paid, fulfilled or refunded order holds",
            func() {
                for (status in [#paid, #processing, #partiallyFulfilled, #fulfilled, #refunded].values()) {
                    expectIds(soldIds([order(status, [soldReleaseVariant.id])], allVariants), [soldReleaseVariant.id]);
                };
            },
        );
        test(
            "ignores orders that were never paid",
            func() {
                let unpaidOrders = [
                    order(#created, [soldReleaseVariant.id]),
                    order(#awaitingPayment, [soldReleaseVariant.id]),
                    order(#canceled, [soldReleaseVariant.id]),
                ];
                expectIds(soldIds(unpaidOrders, allVariants), []);
            },
        );
        test(
            "returns only the variants a paid order holds, once each",
            func() {
                let otherSoldVariant : Variant = {
                    id = 13;
                    deliverable = ?#release(soldRelease);
                };
                let orders = [order(#paid, [soldReleaseVariant.id, plainVariant.id]), order(#fulfilled, [soldReleaseVariant.id])];
                expectIds(soldIds(orders, [soldReleaseVariant, otherSoldVariant, plainVariant]), [soldReleaseVariant.id]);
            },
        );
        test(
            "never returns a variant without a release, even if it sold",
            func() {
                expectIds(soldIds([order(#paid, [plainVariant.id])], [plainVariant]), []);
            },
        );
        test(
            "doesn't read the orders when no variant sells a sold release",
            func() {
                var ordersRead = 0;
                let countingOrders = {
                    next = func() : ?ReleaseSales.SaleRecord {
                        ordersRead += 1;
                        null;
                    };
                };
                let sold = ReleaseSales.soldReleaseVariants(libraryWithSoldRelease(), countingOrders, [unsoldReleaseVariant, plainVariant]);
                expect.nat(sold.size()).equal(0);
                expect.nat(ordersRead).equal(0);
            },
        );
        test(
            "keeps the caller's variant type",
            func() {
                let productVariant = {
                    id = soldReleaseVariant.id;
                    deliverable = soldReleaseVariant.deliverable;
                    sku = "EP-DIGITAL";
                };
                let sold = ReleaseSales.soldReleaseVariants(libraryWithSoldRelease(), [order(#paid, [productVariant.id])].values(), [productVariant]);
                expect.text(sold[0].sku).equal("EP-DIGITAL");
            },
        );
    },
);

func heldBy(unpaidVariantIds : [VariantId]) : VariantId -> Bool {
    func(variantId : VariantId) : Bool = unpaidVariantIds.any(func(unpaidId : VariantId) : Bool = unpaidId == variantId);
};

func holdOf(orders : [ReleaseSales.SaleRecord], unpaidVariantIds : [VariantId], variants : [Variant]) : Text {
    switch (ReleaseSales.heldReleaseVariant(libraryWithSoldRelease(), orders.values(), heldBy(unpaidVariantIds), variants)) {
        case (?(variant, hold)) debug_show (variant.id, hold);
        case null "none";
    };
};

suite(
    "ReleaseSales.heldReleaseVariant",
    func() {
        test(
            "holds a release variant an unpaid order holds, even if its release never sold",
            func() {
                expect.text(holdOf([], [unsoldReleaseVariant.id], allVariants)).equal(debug_show (unsoldReleaseVariant.id, #awaitingPayment));
            },
        );
        test(
            "holds a sold release variant",
            func() {
                expect.text(holdOf([order(#paid, [soldReleaseVariant.id])], [], allVariants)).equal(debug_show (soldReleaseVariant.id, #sold));
            },
        );
        test(
            "doesn't hold a plain variant an unpaid order holds",
            func() {
                expect.text(holdOf([], [plainVariant.id], allVariants)).equal("none");
            },
        );
        test(
            "holds nothing when no buyer needs a release variant",
            func() {
                expect.text(holdOf([order(#canceled, [soldReleaseVariant.id])], [], allVariants)).equal("none");
            },
        );
    },
);

suite(
    "ReleaseSales.hasSold",
    func() {
        test(
            "is true only for a variant a paid order holds",
            func() {
                let orders = [order(#canceled, [plainVariant.id]), order(#refunded, [soldReleaseVariant.id])];
                expect.bool(ReleaseSales.hasSold(orders.values(), soldReleaseVariant.id)).isTrue();
                expect.bool(ReleaseSales.hasSold(orders.values(), plainVariant.id)).isFalse();
            },
        );
    },
);
