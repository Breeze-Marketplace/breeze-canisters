import { expect } "mo:test";
import { suite; test } "mo:test";

import Map "mo:map/Map";

import Stock "../stock";

func inventoryOf(rows : [(Nat32, Nat32, Nat32)]) : Stock.Inventory {
    let inventory = Map.new<Nat32, Stock.Entry>();
    let entry = func(variantId : Nat32, stock : Nat32, reserved : Nat32) : Stock.Entry = {
        productId = 1;
        variantId;
        stock;
        reserved;
        lowStockThreshold = 10;
    };
    for ((variantId, stock, reserved) in rows.vals()) {
        Map.set(inventory, Map.n32hash, variantId, entry(variantId, stock, reserved));
    };
    inventory;
};

func row(inventory : Stock.Inventory, variantId : Nat32) : (Nat32, Nat32) {
    let ?entry = Map.get(inventory, Map.n32hash, variantId) else return (999, 999);
    (entry.stock, entry.reserved);
};

func expectRow(inventory : Stock.Inventory, variantId : Nat32, stock : Nat32, reserved : Nat32) {
    let (s, r) = row(inventory, variantId);
    expect.nat32(s).equal(stock);
    expect.nat32(r).equal(reserved);
};

suite(
    "available",
    func() {
        test("is stock minus reserved", func() { expect.nat32(Stock.available(({ productId = 1; variantId = 1; stock = 5; reserved = 2; lowStockThreshold = 1 } : Stock.Entry))).equal(3) });
        test("is zero when reserved covers stock", func() { expect.nat32(Stock.available(({ productId = 1; variantId = 1; stock = 2; reserved = 3; lowStockThreshold = 1 } : Stock.Entry))).equal(0) });
    },
);

suite(
    "firstShortfall",
    func() {
        test(
            "is null when every variant has enough",
            func() {
                let inventory = inventoryOf([(1, 5, 2), (2, 1, 0)]);
                expect.bool(Stock.firstShortfall(inventory, [{ variantId = 1; quantity = 3 }, { variantId = 2; quantity = 1 }]) == null).isTrue();
            },
        );
        test(
            "counts units other orders reserved",
            func() {
                let inventory = inventoryOf([(1, 5, 4)]);
                expect.bool(Stock.firstShortfall(inventory, [{ variantId = 1; quantity = 2 }]) == ?{ variantId = 1 : Nat32; requested = 2; available = 1 }).isTrue();
            },
        );
        test(
            "adds up a variant's quantity across lines",
            func() {
                let inventory = inventoryOf([(1, 3, 0)]);
                expect.bool(Stock.firstShortfall(inventory, [{ variantId = 1; quantity = 2 }, { variantId = 1; quantity = 2 }]) == ?{ variantId = 1 : Nat32; requested = 4; available = 3 }).isTrue();
            },
        );
        test(
            "treats a variant with no inventory row as having none",
            func() {
                let inventory = inventoryOf([]);
                expect.bool(Stock.firstShortfall(inventory, [{ variantId = 7; quantity = 1 }]) == ?{ variantId = 7 : Nat32; requested = 1; available = 0 }).isTrue();
            },
        );
    },
);

suite(
    "change",
    func() {
        test("a new unpaid order reserves", func() { expect.bool(Stock.change(null, true, false) == #reserve).isTrue() });
        test("paying an unpaid order sells", func() { expect.bool(Stock.change(?true, false, false) == #sell).isTrue() });
        test("cancelling an unpaid order releases", func() { expect.bool(Stock.change(?true, false, true) == #release).isTrue() });
        test("staying unpaid changes nothing", func() { expect.bool(Stock.change(?true, true, false) == #none).isTrue() });
        test("fulfilling a paid order changes nothing", func() { expect.bool(Stock.change(?false, false, false) == #none).isTrue() });
    },
);

suite(
    "apply",
    func() {
        test(
            "reserve, then sell, takes the units out of stock",
            func() {
                let inventory = inventoryOf([(1, 5, 0)]);
                let lines = [{ variantId = 1 : Nat32; quantity = 2 : Nat32 }];
                Stock.apply(inventory, lines, #reserve);
                expectRow(inventory, 1, 5, 2);
                Stock.apply(inventory, lines, #sell);
                expectRow(inventory, 1, 3, 0);
            },
        );
        test(
            "reserve, then release, puts the units back",
            func() {
                let inventory = inventoryOf([(1, 5, 1)]);
                let lines = [{ variantId = 1 : Nat32; quantity = 2 : Nat32 }];
                Stock.apply(inventory, lines, #reserve);
                expectRow(inventory, 1, 5, 3);
                Stock.apply(inventory, lines, #release);
                expectRow(inventory, 1, 5, 1);
            },
        );
        test(
            "selling an order that reserved nothing saturates instead of trapping",
            func() {
                let inventory = inventoryOf([(1, 1, 0)]);
                Stock.apply(inventory, [{ variantId = 1 : Nat32; quantity = 3 : Nat32 }], #sell);
                expectRow(inventory, 1, 0, 0);
            },
        );
        test(
            "skips a deleted variant",
            func() {
                let inventory = inventoryOf([(1, 5, 0)]);
                Stock.apply(inventory, [{ variantId = 9 : Nat32; quantity = 1 : Nat32 }, { variantId = 1 : Nat32; quantity = 1 : Nat32 }], #reserve);
                expectRow(inventory, 1, 5, 1);
                expect.bool(Map.has(inventory, Map.n32hash, 9 : Nat32)).isFalse();
            },
        );
    },
);

suite(
    "stocked",
    func() {
        let releaseVariant : Nat32 = 9;
        let unlimited = func(variantId : Nat32) : Bool = variantId == releaseVariant;
        test(
            "a release-only order holds no stock and is never short",
            func() {
                let inventory = inventoryOf([]);
                let lines = Stock.stocked([{ variantId = releaseVariant; quantity = 1 }], unlimited);
                expect.nat(lines.size()).equal(0);
                expect.bool(Stock.firstShortfall(inventory, lines) == null).isTrue();
                Stock.apply(inventory, lines, #reserve);
                Stock.apply(inventory, lines, #sell);
                expectRow(inventory, releaseVariant, 999, 999);
            },
        );
        test(
            "keeps the other lines of a mixed order",
            func() {
                let inventory = inventoryOf([(1, 5, 0)]);
                let lines = Stock.stocked([{ variantId = releaseVariant; quantity = 1 }, { variantId = 1; quantity = 2 }], unlimited);
                expect.nat(lines.size()).equal(1);
                Stock.apply(inventory, lines, #reserve);
                expectRow(inventory, 1, 5, 2);
            },
        );
    },
);
