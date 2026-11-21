import Array "mo:core/Array";
import Int "mo:core/Int";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Order "mo:core/Order";
import Text "mo:core/Text";
import Types "mo:core/Types";

import OrderExpiry "order_expiry";

/// The shop admin dashboard (BRE-146): what needs the merchant's attention and how the shop is
/// selling. Takes structural product, inventory and order fields rather than `../types` (which
/// imports `canister:xrc`), so it runs under `mops test`.
module Dashboard {
    public let DAY_NANOS : Int = 86_400_000_000_000;

    /// Most stock alerts returned; `stock.outOfStock` and `stock.lowStock` still count them all.
    public let MAX_STOCK_ALERTS : Nat = 20;
    public let RECENT_ORDERS : Nat = 5;
    public let TOP_PRODUCTS : Nat = 5;

    /// Same shape as `Money` in `../types`.
    public type Money = {
        currency : {
            class_ : { #Cryptocurrency; #FiatCurrency };
            symbol : Text;
        };
        amount : Nat64;
        metadata : { decimals : Nat32 };
    };

    public type ProductStatus = { #Draft; #Active; #Inactive; #Archived };

    public type ProductInput = {
        id : Nat32;
        title : Text;
        status : ProductStatus;
        variants : [{ imageUrls : [Text] }];
    };

    public type VariantInput = { id : Nat32; name : Text; sku : Text };

    public type InventoryInput = {
        productId : Nat32;
        stock : Nat32;
        reserved : Nat32;
        lowStockThreshold : Nat32;
    };

    public type OrderInput = {
        id : Nat32;
        status : OrderExpiry.OrderStatus;
        createdAt : Int;
        payment : ?{ paidAt : ?Int };
        totals : { total : Money };
        items : [{ productId : Nat32; title : Text; quantity : Nat32 }];
    };

    public type StockAlert = {
        product : { id : Nat32; title : Text };
        variant : { id : Nat32; name : Text; sku : Text };
        stock : Nat32;
        available : Nat32;
        lowStockThreshold : Nat32;
        status : { #OutOfStock; #LowStock };
    };

    /// Orders sold in a window and their revenue, one `Money` per currency (ICP, USDC and card USD
    /// are kept apart).
    public type Sales = { orders : Nat32; revenue : [Money] };

    public type OrderSummary = {
        id : Nat32;
        status : OrderExpiry.OrderStatus;
        createdAt : Int;
        total : Money;
        itemCount : Nat32;
    };

    public type TopProduct = {
        productId : Nat32;
        title : Text;
        unitsSold : Nat32;
    };

    public type Dashboard = {
        generatedAt : Int;
        /// `withoutImages` counts products, other than archived ones, none of whose variants has an image.
        products : {
            active : Nat32;
            draft : Nat32;
            inactive : Nat32;
            archived : Nat32;
            withoutImages : Nat32;
        };
        /// `toFulfill`: paid but not yet fulfilled. `oldestToFulfillAt` is when the longest-waiting one was paid.
        orders : {
            awaitingPayment : Nat32;
            toFulfill : Nat32;
            oldestToFulfillAt : ?Int;
        };
        sales : { last24h : Sales; last7d : Sales; last30d : Sales };
        /// Archived products' variants are left out. Sold out first, then by least available.
        stock : { outOfStock : Nat32; lowStock : Nat32; alerts : [StockAlert] };
        /// The latest sold orders, newest first. Unpaid and cancelled orders are left out: anyone
        /// signed in can create them, so they would crowd out real sales.
        recentOrders : [OrderSummary];
        /// By units sold in the last 30 days.
        topProducts : [TopProduct];
    };

    /// Paid and still waiting for the merchant to ship or deliver.
    public func isToFulfill(status : OrderExpiry.OrderStatus) : Bool {
        switch (status) {
            case (#paid or #processing or #partiallyFulfilled) true;
            case (#created or #awaitingPayment or #fulfilled or #canceled or #refunded) false;
        };
    };

    /// A completed sale: paid, and not cancelled or refunded.
    public func isSold(status : OrderExpiry.OrderStatus) : Bool {
        isToFulfill(status) or status == #fulfilled;
    };

    /// Out of stock at 0, low below the threshold: the same rule as `getInventory`.
    public func stockStatus(entry : InventoryInput) : ?{
        #OutOfStock;
        #LowStock;
    } {
        if (entry.stock == 0) ?#OutOfStock else if (entry.stock < entry.lowStockThreshold) ?#LowStock else null;
    };

    /// When the order counts as sold: its payment time, or its creation time if the payment has none.
    func soldAt(order : OrderInput) : Int {
        switch (order.payment) {
            case (?{ paidAt = ?paidAt }) paidAt;
            case _ order.createdAt;
        };
    };

    type SalesAccumulator = {
        since : Int;
        var orders : Nat32;
        revenue : Map.Map<Text, Money>;
    };

    func newSales(since : Int) : SalesAccumulator {
        { since; var orders = 0; revenue = Map.empty() };
    };

    func addSale(acc : SalesAccumulator, at : Int, total : Money) {
        if (at < acc.since) return;
        acc.orders += 1;
        // Keyed by symbol and decimals, so amounts are only added in the same units.
        let key = total.currency.symbol # ":" # total.metadata.decimals.toText();
        let sum = switch (Map.get(acc.revenue, Text.compare, key)) {
            case (?money) ({ money with amount = money.amount + total.amount });
            case null total;
        };
        Map.add(acc.revenue, Text.compare, key, sum);
    };

    func salesOf(acc : SalesAccumulator) : Sales {
        {
            orders = acc.orders;
            revenue = Array.fromIter(Map.values(acc.revenue));
        };
    };

    func compareAlerts(a : StockAlert, b : StockAlert) : Order.Order {
        switch (a.status, b.status) {
            case (#OutOfStock, #LowStock) #less;
            case (#LowStock, #OutOfStock) #greater;
            case _ {
                switch (Nat32.compare(a.available, b.available)) {
                    case (#equal) Nat32.compare(a.variant.id, b.variant.id);
                    case other other;
                };
            };
        };
    };

    func take<T>(items : [T], n : Nat) : [T] {
        if (items.size() <= n) items else Array.sliceToArray(items, 0, n);
    };

    public func build(
        input : {
            now : Int;
            products : Types.Iter<ProductInput>;
            inventory : Types.Iter<(Nat32, InventoryInput)>;
            orders : Types.Iter<OrderInput>;
            productById : Nat32 -> ?ProductInput;
            variantById : Nat32 -> ?VariantInput;
        }
    ) : Dashboard {
        let { now } = input;

        var active : Nat32 = 0;
        var draft : Nat32 = 0;
        var inactive : Nat32 = 0;
        var archived : Nat32 = 0;
        var withoutImages : Nat32 = 0;
        for (product in input.products) {
            switch (product.status) {
                case (#Active) active += 1;
                case (#Draft) draft += 1;
                case (#Inactive) inactive += 1;
                case (#Archived) archived += 1;
            };
            let hasImage = Array.any(product.variants, func(v : { imageUrls : [Text] }) : Bool = v.imageUrls.size() > 0);
            if (product.status != #Archived and not hasImage) withoutImages += 1;
        };

        var outOfStock : Nat32 = 0;
        var lowStock : Nat32 = 0;
        let alerts = List.empty<StockAlert>();
        label entries for ((variantId, entry) in input.inventory) {
            let ?status = stockStatus(entry) else continue entries;
            let ?product = input.productById(entry.productId) else continue entries;
            if (product.status == #Archived) continue entries;
            let ?variant = input.variantById(variantId) else continue entries;
            switch (status) {
                case (#OutOfStock) outOfStock += 1;
                case (#LowStock) lowStock += 1;
            };
            List.add(
                alerts,
                {
                    product = { id = product.id; title = product.title };
                    variant = {
                        id = variant.id;
                        name = variant.name;
                        sku = variant.sku;
                    };
                    stock = entry.stock;
                    available = if (entry.reserved >= entry.stock) 0 : Nat32 else entry.stock - entry.reserved;
                    lowStockThreshold = entry.lowStockThreshold;
                    status;
                },
            );
        };

        var awaitingPayment : Nat32 = 0;
        var toFulfill : Nat32 = 0;
        var oldestToFulfillAt : ?Int = null;
        let last24h = newSales(now - DAY_NANOS);
        let last7d = newSales(now - 7 * DAY_NANOS);
        let last30d = newSales(now - 30 * DAY_NANOS);
        let unitsByProduct = Map.empty<Nat32, TopProduct>();
        let sold = List.empty<OrderInput>();
        for (order in input.orders) {
            if (OrderExpiry.isAwaitingPayment(order.status)) awaitingPayment += 1;
            if (isToFulfill(order.status)) {
                toFulfill += 1;
                let at = soldAt(order);
                oldestToFulfillAt := switch (oldestToFulfillAt) {
                    case (?oldest) ?Int.min(oldest, at);
                    case null ?at;
                };
            };
            if (isSold(order.status)) {
                let at = soldAt(order);
                addSale(last24h, at, order.totals.total);
                addSale(last7d, at, order.totals.total);
                addSale(last30d, at, order.totals.total);
                if (at >= last30d.since) {
                    for (item in order.items.values()) {
                        let top = switch (Map.get(unitsByProduct, Nat32.compare, item.productId)) {
                            case (?top) ({
                                top with unitsSold = top.unitsSold + item.quantity
                            });
                            case null {
                                {
                                    productId = item.productId;
                                    title = item.title;
                                    unitsSold = item.quantity;
                                };
                            };
                        };
                        Map.add(unitsByProduct, Nat32.compare, item.productId, top);
                    };
                };
                List.add(sold, order);
            };
        };

        let newestSold = List.toArray(List.sort(sold, func(a : OrderInput, b : OrderInput) : Order.Order = Nat32.compare(b.id, a.id)));
        let recentOrders = Array.map(
            take(newestSold, RECENT_ORDERS),
            func(order : OrderInput) : OrderSummary {
                {
                    id = order.id;
                    status = order.status;
                    createdAt = order.createdAt;
                    total = order.totals.total;
                    itemCount = Array.foldLeft(order.items, 0 : Nat32, func(sum : Nat32, item : { quantity : Nat32 }) : Nat32 = sum + item.quantity);
                };
            },
        );

        let topProducts = Array.sort(
            Array.fromIter(Map.values(unitsByProduct)),
            func(a : TopProduct, b : TopProduct) : Order.Order {
                switch (Nat32.compare(b.unitsSold, a.unitsSold)) {
                    case (#equal) Nat32.compare(a.productId, b.productId);
                    case other other;
                };
            },
        );

        {
            generatedAt = now;
            products = { active; draft; inactive; archived; withoutImages };
            orders = { awaitingPayment; toFulfill; oldestToFulfillAt };
            sales = {
                last24h = salesOf(last24h);
                last7d = salesOf(last7d);
                last30d = salesOf(last30d);
            };
            stock = {
                outOfStock;
                lowStock;
                alerts = take(Array.sort(List.toArray(alerts), compareAlerts), MAX_STOCK_ALERTS);
            };
            recentOrders;
            topProducts = take(topProducts, TOP_PRODUCTS);
        };
    };
};
