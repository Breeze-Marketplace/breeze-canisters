import { expect } "mo:test";
import { suite; test } "mo:test";

import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat32 "mo:core/Nat32";

import Dashboard "../dashboard";
import OrderExpiry "../order_expiry";

let day = Dashboard.DAY_NANOS;
let now : Int = 100 * day;

func icp(amount : Nat64) : Dashboard.Money {
    {
        currency = { class_ = #Cryptocurrency; symbol = "ICP" };
        amount;
        metadata = { decimals = 8 };
    };
};
func usdc(amount : Nat64) : Dashboard.Money {
    {
        currency = { class_ = #Cryptocurrency; symbol = "USDC" };
        amount;
        metadata = { decimals = 6 };
    };
};

func product(id : Nat32, status : Dashboard.ProductStatus, imageUrls : [Text]) : Dashboard.ProductInput {
    { id; title = "Product " # id.toText(); status; variants = [{ imageUrls }] };
};

func order(
    id : Nat32,
    status : OrderExpiry.OrderStatus,
    paidAt : ?Int,
    total : Dashboard.Money,
    items : [(Nat32, Nat32)],
) : Dashboard.OrderInput {
    {
        id;
        status;
        createdAt = switch (paidAt) { case (?at) at; case null now };
        payment = ?{ paidAt };
        totals = { total };
        items = Array.map(items, func((productId, quantity) : (Nat32, Nat32)) : { productId : Nat32; title : Text; quantity : Nat32 } = { productId; title = "Product " # productId.toText(); quantity });
    };
};

func build(
    products : [Dashboard.ProductInput],
    inventory : [(Nat32, Dashboard.InventoryInput)],
    orders : [Dashboard.OrderInput],
) : Dashboard.Dashboard {
    let byId = Map.fromIter<Nat32, Dashboard.ProductInput>(
        Array.map<Dashboard.ProductInput, (Nat32, Dashboard.ProductInput)>(products, func(p) = (p.id, p)).values(),
        Nat32.compare,
    );
    Dashboard.build({
        now;
        products = products.values();
        inventory = inventory.values();
        orders = orders.values();
        productById = func(id) = Map.get(byId, Nat32.compare, id);
        // Variant IDs are 100 + n, named "Variant n".
        variantById = func(id) = ?{
            id;
            name = "Variant " # (id - 100).toText();
            sku = "SKU-" # id.toText();
        };
    });
};

func entry(productId : Nat32, stock : Nat32, reserved : Nat32, lowStockThreshold : Nat32) : Dashboard.InventoryInput {
    { productId; stock; reserved; lowStockThreshold };
};

suite(
    "Dashboard order states",
    func() {
        test(
            "paid orders not yet fulfilled are to fulfill",
            func() {
                for (status in ([#paid, #processing, #partiallyFulfilled] : [OrderExpiry.OrderStatus]).values()) {
                    expect.bool(Dashboard.isToFulfill(status)).isTrue();
                    expect.bool(Dashboard.isSold(status)).isTrue();
                };
            },
        );
        test(
            "fulfilled orders are sold but not to fulfill",
            func() {
                expect.bool(Dashboard.isToFulfill(#fulfilled)).isFalse();
                expect.bool(Dashboard.isSold(#fulfilled)).isTrue();
            },
        );
        test(
            "unpaid, cancelled and refunded orders are not sold",
            func() {
                for (status in ([#created, #awaitingPayment, #canceled, #refunded] : [OrderExpiry.OrderStatus]).values()) {
                    expect.bool(Dashboard.isToFulfill(status)).isFalse();
                    expect.bool(Dashboard.isSold(status)).isFalse();
                };
            },
        );
    },
);

suite(
    "Dashboard.build products",
    func() {
        test(
            "counts products by status, and those without images other than archived",
            func() {
                let d = build(
                    [
                        product(1, #Active, ["a.png"]),
                        product(2, #Active, []),
                        product(3, #Draft, []),
                        product(4, #Inactive, ["c.png"]),
                        product(5, #Archived, []),
                    ],
                    [],
                    [],
                );
                expect.nat32(d.products.active).equal(2);
                expect.nat32(d.products.draft).equal(1);
                expect.nat32(d.products.inactive).equal(1);
                expect.nat32(d.products.archived).equal(1);
                expect.nat32(d.products.withoutImages).equal(2);
            },
        );
    },
);

suite(
    "Dashboard.build stock",
    func() {
        test(
            "lists one alert per variant, sold out first, then by least available",
            func() {
                let d = build(
                    [product(1, #Active, ["a.png"]), product(2, #Active, ["b.png"])],
                    [
                        (101, entry(1, 4, 0, 5)),
                        (102, entry(1, 0, 0, 5)),
                        (103, entry(1, 2, 1, 5)),
                        (104, entry(2, 10, 0, 5)),
                    ],
                    [],
                );
                expect.nat32(d.stock.outOfStock).equal(1);
                expect.nat32(d.stock.lowStock).equal(2);
                let ids = Array.map(d.stock.alerts, func(a : Dashboard.StockAlert) : Nat32 = a.variant.id);
                expect.array<Nat32>(ids, Nat32.toText, Nat32.equal).equal([102, 103, 101]);
                expect.text(d.stock.alerts[1].variant.name).equal("Variant 3");
                expect.nat32(d.stock.alerts[1].available).equal(1);
            },
        );
        test(
            "skips archived and missing products",
            func() {
                let d = build(
                    [product(1, #Archived, [])],
                    [(101, entry(1, 0, 0, 5)), (102, entry(9, 0, 0, 5))],
                    [],
                );
                expect.nat32(d.stock.outOfStock).equal(0);
                expect.nat(d.stock.alerts.size()).equal(0);
            },
        );
        test(
            "caps the alerts but counts them all",
            func() {
                let inventory = Array.tabulate<(Nat32, Dashboard.InventoryInput)>(
                    Dashboard.MAX_STOCK_ALERTS + 5,
                    func(i) = (101 + Nat32.fromNat(i), entry(1, 0, 0, 5)),
                );
                let d = build([product(1, #Active, [])], inventory, []);
                expect.nat(d.stock.alerts.size()).equal(Dashboard.MAX_STOCK_ALERTS);
                expect.nat32(d.stock.outOfStock).equal(Nat32.fromNat(Dashboard.MAX_STOCK_ALERTS + 5));
            },
        );
        test(
            "reports no available stock when more is reserved than held",
            func() {
                let d = build([product(1, #Active, [])], [(101, entry(1, 1, 3, 5))], []);
                expect.nat32(d.stock.alerts[0].available).equal(0);
            },
        );
    },
);

suite(
    "Dashboard.build orders and sales",
    func() {
        let orders = [
            order(1, #fulfilled, ?(now - 40 * day), icp(100), [(1, 1)]),
            order(2, #paid, ?(now - 20 * day), icp(200), [(1, 2)]),
            order(3, #processing, ?(now - 3 * day), usdc(5_000_000), [(2, 1)]),
            order(4, #fulfilled, ?(now - day / 2), icp(300), [(2, 4), (1, 1)]),
            order(5, #awaitingPayment, null, icp(999), [(1, 1)]),
            order(6, #canceled, null, icp(999), [(1, 9)]),
            order(7, #refunded, ?(now - day / 4), icp(999), [(1, 9)]),
        ];
        let d = build([], [], orders);

        test(
            "counts orders awaiting payment and to fulfill, with the oldest to fulfill",
            func() {
                expect.nat32(d.orders.awaitingPayment).equal(1);
                expect.nat32(d.orders.toFulfill).equal(2);
                expect.bool(d.orders.oldestToFulfillAt == ?(now - 20 * day)).isTrue();
            },
        );
        test(
            "sums revenue per window and currency, ignoring unpaid, cancelled and refunded orders",
            func() {
                expect.nat32(d.sales.last24h.orders).equal(1);
                expect.bool(d.sales.last24h.revenue == [icp(300)]).isTrue();
                expect.nat32(d.sales.last7d.orders).equal(2);
                expect.bool(d.sales.last7d.revenue == [icp(300), usdc(5_000_000)]).isTrue();
                expect.nat32(d.sales.last30d.orders).equal(3);
                expect.bool(d.sales.last30d.revenue == [icp(500), usdc(5_000_000)]).isTrue();
            },
        );
        test(
            "lists the latest sold orders newest first, with their unit counts",
            func() {
                let ids = Array.map(d.recentOrders, func(o : Dashboard.OrderSummary) : Nat32 = o.id);
                expect.array<Nat32>(ids, Nat32.toText, Nat32.equal).equal([4, 3, 2, 1]);
                expect.nat32(d.recentOrders[0].itemCount).equal(5);
            },
        );
        test(
            "ranks products by units sold in the last 30 days",
            func() {
                let top = Array.map<Dashboard.TopProduct, (Nat32, Nat32)>(d.topProducts, func(p) = (p.productId, p.unitsSold));
                expect.bool(top == [(2, 5), (1, 3)]).isTrue();
            },
        );
    },
);
