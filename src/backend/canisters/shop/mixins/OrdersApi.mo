import Array "mo:base/Array";
import Nat32 "mo:base/Nat32";
import Error "mo:core/Error";
import Timer "mo:core/Timer";
import { type Result } "mo:core/Result";
import List "mo:core/List";
import Time "mo:base/Time";
import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Int "mo:base/Int";
import Blob "mo:base/Blob";
import Map "mo:map/Map";
import Set "mo:core/Set";
import Iter "mo:core/Iter";

import XRC "canister:xrc";

import Ledger "canister:icp_ledger";

import Decimals "../../../lib/Decimals";
import Hex "../../../lib/Hex";
import Subaccount "../../../lib/Subaccount";
import TimeUtil "../../../lib/Time";
import ExchangeRates "../../../lib/ExchangeRates";

import Wallet "../../../lib/Wallet";
import Logger "../../../lib/Logger";
import Pagination "../../../lib/Pagination";

import OrderService "../lib/orders";
import PubSubService "../lib/pubsub";
import AuthService "../lib/auth";
import ShopPermissions "../lib/permissions";
import OrderAccess "../lib/order_access";
import OrderEvents "../lib/order_events";
import OrderExpiry "../lib/order_expiry";
import PaymentCheck "../lib/payment_check";
import PaymentCurrency "../lib/payment_currency";
import Shipping "../lib/shipping";
import Stock "../lib/stock";
import ProductService "../lib/products";
import Checkout "../lib/stripe/Checkout";
import Stripe "../lib/stripe/lib";
import Management "../../../interfaces/management";

import {
    type Order;
    type OrderStatus;
    type PaymentRef;
    type StripeSettings;
    type Product;
    type ProductType;
    type ProductVariant;
    type Money;
    type Currency;
    type ProductId;
    type VariantId;
    type OrderId;
    type ShippingAddress;
    type OrderRefund;
    type RefundDestination;
    type RefundError;
    type InventoryEntry;
} "../types";

/// Orders: creation and pricing, ICP and ckUSDC payment accounts and checks, fulfilment, cancellation, expiry and
/// late-payment timers (re-armed below on every install and upgrade), refunds, and order queries.
mixin (
    orders : Map.Map<OrderId, Order>,
    awaitingPaymentOrderIds : OrderExpiry.AwaitingPaymentIds,
    orderEvents : OrderEvents.Log,
    wallet : Wallet.Wallet,
    productVariants : Map.Map<VariantId, ProductVariant>,
    products : Map.Map<ProductId, Product>,
    inventory : Map.Map<VariantId, InventoryEntry>,
    authService : AuthService.AuthService,
    orderService : OrderService.OrderService,
    pubSubService : PubSubService.PubSubService,
    exchangeRates : ExchangeRates.State,
    stripe : StripeSettings,
    getNextOrderId : () -> OrderId,
    // Records the releases a paid order sells (BRE-182), on every write.
    onOrderStored : Order -> (),
    shopId : Principal,
    logger : Logger.BoundLogger,
) {
    /// "<amount> <symbol>" in the ledger's base units (e8s for ICP), for log lines.
    private func moneyText(amount : Nat, currency : Currency) : Text {
        Nat.toText(amount) # " " # currency.symbol;
    };

    /// Builds an order for `caller` from line items and `paymentCurrency`, resolving unit prices (USD→ICP via XRC,
    /// USD→USDC one to one, when the catalog has no price in that currency). USDC orders are paid in ckUSDC and
    /// stored with its 6 decimals. Registers a per-order ledger subaccount when the order is stored. Rejects the
    /// anonymous principal. `shippingAddress` is required, and checked, only when a line item is a `#Physical`
    /// product (any country, as an ISO 3166-1 alpha-2 code); a digital or service order stores no address (BRE-23).
    /// Rejects a buyer who already holds `OrderAccess.MAX_UNPAID_ORDERS_PER_BUYER` orders awaiting payment (BRE-111).
    public shared ({ caller }) func createOrder(
        input : {
            items : [{
                productId : ProductId;
                variantId : VariantId;
                title : Text;
                quantity : Nat32;
            }];
            paymentCurrency : Currency;
            shippingAddress : ?ShippingAddress;
        }
    ) : async Result<Order, { #InternalError : Text }> {
        if (not OrderAccess.canPlaceOrder(caller)) {
            return #err(#InternalError("Sign in to place an order"));
        };
        if (input.items.size() == 0) return #err(#InternalError("An order needs at least one item"));
        // A line with no units costs nothing but would still name a variant, and digital delivery
        // reads entitlement from the line (BRE-185).
        for (item in input.items.vals()) {
            if (item.quantity == 0) return #err(#InternalError("Every item needs a quantity of at least one"));
        };
        // Checked again after the exchange-rate `await` below; this early check spares that call.
        if (not hasRoomForUnpaidOrder(caller)) return #err(#InternalError(unpaidOrderLimitMessage()));
        // "ckUSDC" is another name for USDC: store every USDC order under the catalog's name for it.
        let paymentCurrency = if (PaymentCurrency.isUsdc(input.paymentCurrency)) PaymentCurrency.USDC else input.paymentCurrency;
        let paysByCard = PaymentCurrency.isCard(paymentCurrency);
        if (paysByCard and stripe.restrictedKey == null) {
            return #err(#InternalError("This shop doesn't take card payments"));
        };
        if (not paysByCard and PaymentCurrency.token(paymentCurrency) == null) {
            return #err(#InternalError("This shop doesn't take payment in " # paymentCurrency.symbol));
        };
        let itemsWithPrices = List.empty<{ productId : ProductId; variantId : VariantId; title : Text; quantity : Nat32; unitPrice : Money }>();
        let productTypes = List.empty<ProductType>();

        for (item in Array.vals(input.items)) {
            let variant = switch (Map.get(productVariants, Map.n32hash, item.variantId)) {
                case (?v) v;
                case null {
                    return #err(#InternalError("Variant not found for product ID " # Nat32.toText(item.productId) # " and variant ID " # Nat32.toText(item.variantId)));
                };
            };

            // The variant's own product decides shipping, not the caller's `productId`.
            let ?product = Map.get(products, Map.n32hash, variant.productId) else {
                return #err(#InternalError("Product not found for variant ID " # Nat32.toText(item.variantId)));
            };
            List.add(productTypes, product.productType);

            let priceInRequestedCurrency = Array.find<Money>(
                variant.price.catalog,
                func(catalogItem) : Bool {
                    return catalogItem.currency == paymentCurrency;
                },
            );

            let catalogOrConverted : Money = switch (priceInRequestedCurrency) {
                case (?p) p;
                case null {
                    let paymentToken = PaymentCurrency.token(paymentCurrency);
                    if (paymentToken == null) {
                        return #err(#InternalError("Unable to get price for product ID " # Nat32.toText(item.productId) # " and variant ID " # Nat32.toText(item.variantId) # " in currency " # debug_show (paymentCurrency)));
                    };
                    let ?priceInUSDCents = Array.find<Money>(
                        variant.price.catalog,
                        func(catalogItem) : Bool {
                            return catalogItem.currency == PaymentCurrency.USD;
                        },
                    ) else {
                        return #err(#InternalError("Unable to get price for product ID " # Nat32.toText(item.productId) # " and variant ID " # Nat32.toText(item.variantId) # " in currency " # paymentCurrency.symbol # " and no USD price found for conversion"));
                    };
                    if (paymentToken == ?"ckUSDC") {
                        PaymentCurrency.usdcFromUsd(priceInUSDCents);
                    } else {
                        // ICP: convert from USD at the XRC rate.
                        let exchangeRateResult = await* ExchangeRates.fetch(
                            exchangeRates,
                            XRC,
                            PaymentCurrency.USD,
                            PaymentCurrency.ICP,
                        );
                        let xrcResponse = switch (exchangeRateResult) {
                            case (#ok(entry)) entry.xrcResponse;
                            case (#err(#InsufficientCycles)) {
                                return #err(#InternalError("Insufficient cycles to fetch exchange rate for price conversion"));
                            };
                            case (#err(#XRCError(error))) {
                                return #err(#InternalError("Failed to fetch exchange rate for price conversion: " # debug_show (error)));
                            };
                        };
                        let exchangeRate = xrcResponse.rate;
                        let icpDecimals : Nat32 = 8;
                        let decimals = xrcResponse.metadata.decimals + priceInUSDCents.metadata.decimals;
                        let e8sAmount = priceInUSDCents.amount * exchangeRate;
                        // `rescale` rounds down; one more e8 means the buyer is never undercharged.
                        let e8sAmountAdjusted = Nat64.fromNat(Decimals.rescale(Nat64.toNat(e8sAmount), decimals, icpDecimals)) + 1;

                        {
                            currency = PaymentCurrency.ICP;
                            amount = e8sAmountAdjusted;
                            metadata = {
                                decimals = icpDecimals;
                            };
                        };
                    };
                };
            };
            // The order total adds unit prices as they are, so a USDC order brings every line to the
            // ckUSDC ledger's decimals, and a card order to cents (what Stripe charges), whichever
            // decimals its catalog line was stored with.
            let unitPrice = if (PaymentCurrency.isUsdc(paymentCurrency)) {
                PaymentCurrency.withDecimals(catalogOrConverted, PaymentCurrency.CKUSDC_DECIMALS);
            } else if (paysByCard) {
                PaymentCurrency.withDecimals(catalogOrConverted, PaymentCurrency.CARD_DECIMALS);
            } else catalogOrConverted;

            List.add<{ productId : ProductId; variantId : VariantId; title : Text; quantity : Nat32; unitPrice : Money }>(
                itemsWithPrices,
                {
                    productId = item.productId;
                    variantId = item.variantId;
                    title = item.title;
                    quantity = item.quantity;
                    unitPrice = unitPrice;
                },
            );
        };

        let shippingAddress = switch (Shipping.addressForOrder(Shipping.anyRequiresShipping(List.toArray(productTypes)), input.shippingAddress)) {
            case (#ok(a)) a;
            case (#err(message)) return #err(#InternalError(message));
        };

        // No `await` from here to `storeOrder`, so concurrent calls can't all pass these checks, and
        // the stock checked here is still there when `storeOrder` reserves it (BRE-167).
        if (not hasRoomForUnpaidOrder(caller)) return #err(#InternalError(unpaidOrderLimitMessage()));
        switch (Stock.firstShortfall(inventory, stockedLines(input.items))) {
            case (?short) return #err(#InternalError(shortfallMessage(short, input.items)));
            case null {};
        };

        let orderId = getNextOrderId();
        let result = OrderService.buildOrder(
            orderService,
            caller,
            {
                items = List.toArray(itemsWithPrices);
                paymentCurrency;
                orderId = orderId;
                shippingAddress;
            },
        );
        let order = switch (result) {
            case (#ok(o)) o;
            case (#err(#InternalError(message))) {
                return #err(#InternalError("Failed to build order: " # message));
            };
        };
        if (Map.has(orders, Map.n32hash, orderId)) {
            return #err(#InternalError("Order with ID " # Nat32.toText(orderId) # " already exists"));
        };
        storeOrder(order, #buyer, #created);
        let subaccount = Subaccount.fromNat32(orderId);
        let _ = Wallet.createAccount(
            wallet,
            ?{
                name = ?accountNameForOrder(orderId);
                subaccount = ?subaccount;
            },
        );
        scheduleOrderExpiry<system>(order);
        ensurePaymentWatcher<system>();
        logger.info(
            "Created order " # Nat32.toText(orderId) # ": " # debug_show (order.items.size()) # " line(s), total " # moneyText(Nat64.toNat(order.totals.total.amount), order.totals.total.currency)
        );
        await* publishOrderUpdated(order);
        #ok(order);
    };

    private func unpaidOrderLimitMessage() : Text = "You already have " # Nat.toText(OrderAccess.MAX_UNPAID_ORDERS_PER_BUYER) # " unpaid orders in this shop. Pay or cancel one, or wait for it to expire, before placing another.";

    /// True when `caller` may open another unpaid order (`OrderAccess.MAX_UNPAID_ORDERS_PER_BUYER`, BRE-111).
    /// Reads only the orders awaiting payment.
    private func hasRoomForUnpaidOrder(caller : Principal) : Bool {
        let unpaid = Iter.filterMap<OrderId, Order>(
            Set.values(awaitingPaymentOrderIds),
            func(id) = Map.get(orders, Map.n32hash, id),
        );
        OrderAccess.hasRoomForUnpaidOrder(caller, unpaid);
    };

    /// Stores `order`, appends the `kind` event caused `by` to its history (BRE-133) and keeps
    /// `awaitingPaymentOrderIds` in step with its status. Every write to `orders` goes through here,
    /// so the set always holds exactly the orders awaiting payment and every change is in the log.
    private func storeOrder(order : Order, by : OrderEvents.Initiator, kind : OrderEvents.OrderEventKind) {
        let previousHolds = switch (Map.get(orders, Map.n32hash, order.id)) {
            case (?previous) ?OrderExpiry.isAwaitingPayment(previous.status);
            case null null;
        };
        Stock.apply(inventory, stockedLines(order.items), Stock.change(previousHolds, OrderExpiry.isAwaitingPayment(order.status), order.status == #canceled));
        Map.set(orders, Map.n32hash, order.id, order);
        OrderExpiry.syncAwaitingPayment(awaitingPaymentOrderIds, order.id, order.status);
        ignore OrderEvents.append(orderEvents, order.id, order.updatedAt, by, kind);
        onOrderStored(order);
    };

    /// The lines of an order that hold stock: a digital release never runs out (BRE-185).
    private func stockedLines(lines : [Stock.Line]) : [Stock.Line] {
        Stock.stocked(
            lines,
            func(variantId : VariantId) : Bool {
                let ?variant = Map.get(productVariants, Map.n32hash, variantId) else return false;
                let ?product = Map.get(products, Map.n32hash, variant.productId) else return false;
                ProductService.sellsWithoutStock(product.productType, variant);
            },
        );
    };

    /// Whether an order awaiting payment holds variant `variantId`. Its stock was reserved, or not,
    /// by whether the variant sold without stock then (`stockedLines`), and paying or cancelling
    /// settles it the same way, so the catalog mustn't change that until the order settles (BRE-185).
    /// Reads only the orders awaiting payment.
    private func unpaidOrderHolds(variantId : VariantId) : Bool {
        for (id in Set.values(awaitingPaymentOrderIds)) {
            switch (Map.get(orders, Map.n32hash, id)) {
                case (?order) for (item in order.items.vals()) {
                    if (item.variantId == variantId) return true;
                };
                case null {};
            };
        };
        false;
    };

    /// Why an order can't be placed: which line's variant is short, and how many are left.
    private func shortfallMessage(short : { variantId : VariantId; requested : Nat; available : Nat }, items : [{ variantId : VariantId; title : Text }]) : Text {
        let title = switch (Array.find<{ variantId : VariantId; title : Text }>(items, func(i) = i.variantId == short.variantId)) {
            case (?item) item.title;
            case null "An item";
        };
        if (short.available == 0) title # " is out of stock" else "Only " # Nat.toText(short.available) # " of " # title # " left (ordered " # Nat.toText(short.requested) # ")";
    };

    /// Tells `OrderUpdated` subscribers about `order`, without waiting for them. The notification
    /// names the order's latest log event (BRE-203), which every write appends just before it, so a
    /// subscriber that sees a sequence number skipped catches up with `listOrderEvents`.
    private func publishOrderUpdated(order : Order) : async* () {
        let logEvent = switch (OrderEvents.latest(orderEvents, order.id)) {
            case (?e) ?{ seq = e.seq; at = e.at };
            case null null;
        };
        try { ignore pubSubService.notifyOrderUpdated(order, logEvent) } catch (e) {
            pubSubService.logUnsent("OrderUpdated", e);
        };
    };

    private func accountNameForOrder(orderId : OrderId) : Text {
        "Order " # Nat32.toText(orderId);
    };

    /// ICRC-1 account for paying order `orderId` on the ledger of `token`; errors if the order is
    /// missing, or isn't paid in `token` (any supported token when `token` is null).
    private func getOrderPaymentAccountInternal(orderId : OrderId, token : ?Text) : Result<{ account : Ledger.Account; token : Text }, { #NotFoundError : Text }> {
        let order = switch (Map.get(orders, Map.n32hash, orderId)) {
            case (?o) o;
            case null {
                return #err(#NotFoundError("Order with ID " # Nat32.toText(orderId) # " not found"));
            };
        };

        let ?orderToken = PaymentCurrency.token(order.totals.total.currency) else {
            return #err(#NotFoundError("Order with ID " # Nat32.toText(orderId) # " is not paid on a supported ledger"));
        };
        switch (token) {
            case (?expected) {
                if (orderToken != expected) {
                    return #err(#NotFoundError("Order with ID " # Nat32.toText(orderId) # " does not use " # expected # " as payment currency"));
                };
            };
            case null {};
        };

        #ok({ account = getOrderPaymentSubaccount(orderId); token = orderToken });
    };

    /// Hex-encoded ledger account identifier for paying order `orderId` in ICP; errors if the order is missing or not ICP.
    /// Only the ICP ledger takes these legacy account IDs; use `getOrderPaymentAccount` for ckUSDC.
    public query func getOrderPaymentAddressICP(orderId : OrderId) : async Result<Text, { #NotFoundError : Text }> {
        let addr = switch (getOrderPaymentAccountInternal(orderId, ?"ICP")) {
            case (#ok(a)) a.account;
            case (#err(e)) { return #err(e) };
        };
        let invoicePaymentAddress = Principal.toLedgerAccount(addr.owner, addr.subaccount);

        return #ok(Hex.encode(Blob.toArray(invoicePaymentAddress)));
    };

    /// ICRC-1 account (`owner` + `subaccount`) for paying order `orderId` in ICP, for use with `icrc1_transfer`;
    /// errors if the order is missing or not ICP. Same destination as `getOrderPaymentAddressICP`.
    public query func getOrderPaymentAccountICP(orderId : OrderId) : async Result<Ledger.Account, { #NotFoundError : Text }> {
        switch (getOrderPaymentAccountInternal(orderId, ?"ICP")) {
            case (#ok(a)) #ok(a.account);
            case (#err(e)) #err(e);
        };
    };

    /// ICRC-1 account (`owner` + `subaccount`) for paying order `orderId`, and the ledger token it is
    /// paid in ("ICP" or "ckUSDC"), for use with that ledger's `icrc1_transfer` (BRE-20). Errors if the
    /// order is missing or its currency has no ledger. The account is the same on both ledgers.
    public query func getOrderPaymentAccount(orderId : OrderId) : async Result<{ account : Ledger.Account; token : Text }, { #NotFoundError : Text }> {
        getOrderPaymentAccountInternal(orderId, null);
    };

    /// Reads the order's payment ledger (ICP or ckUSDC) once for its invoice account; if the balance
    /// covers the total, marks the order paid (BRE-20). Only the order's buyer, an Owner or an Admin may
    /// call it; anyone else is rejected before any ledger call. Each order's account is read at most once
    /// every few seconds (`PaymentCheck.COOLDOWN_NANOS`); a check inside that window reports the last
    /// read's balance without calling the ledger (BRE-70). The payment watcher marks funded orders paid
    /// on its own timer, so this only makes that happen sooner.
    /// A full payment is honored until the order is cancelled, even after `expiresAt`. An unpaid order past
    /// `expiresAt` is expired on the spot. Paid orders return `#ok` again; cancelled orders are rejected.
    public shared ({ caller }) func checkPayment(orderId : OrderId) : async Result<(), { #NotFoundError : Text; #Unauthorized : Text; #PaymentFailed : Text }> {
        await* checkOrderPayment<system>(caller, orderId);
    };

    /// Same as `checkPayment`, kept for callers built before ckUSDC orders: it checks an order paid in
    /// either token.
    public shared ({ caller }) func checkPaymentICP(orderId : OrderId) : async Result<(), { #NotFoundError : Text; #Unauthorized : Text; #PaymentFailed : Text }> {
        await* checkOrderPayment<system>(caller, orderId);
    };

    private func checkOrderPayment<system>(caller : Principal, orderId : OrderId) : async* Result<(), { #NotFoundError : Text; #Unauthorized : Text; #PaymentFailed : Text }> {
        let order = switch (Map.get(orders, Map.n32hash, orderId)) {
            case (?o) o;
            case null {
                return #err(#NotFoundError("Order with ID " # Nat32.toText(orderId) # " not found"));
            };
        };
        if (not OrderAccess.canViewOrder(authService, caller, order)) {
            return #err(#Unauthorized("Only the order's buyer, an Owner or an Admin can check its payment"));
        };
        if (PaymentCurrency.isCard(order.totals.total.currency)) {
            return await* checkCardPayment<system>(order);
        };
        switch (paymentCheckStatus(order)) {
            case (#ok) {};
            case (#alreadyPaid) { return #ok(()) };
            case (#err(message)) { return #err(#PaymentFailed(message)) };
        };
        // `paymentCheckStatus` accepts only orders with a ledger.
        let ?(ledger, ledgerDecimals) = paymentLedger(order) else {
            return #err(#PaymentFailed("Order with ID " # Nat32.toText(orderId) # " is not paid on a supported ledger"));
        };

        let startedAt = Time.now();
        switch (PaymentCheck.begin(paymentChecks, orderId, startedAt)) {
            case (#read) {};
            case (#recent(lastBalance)) {
                return #err(#PaymentFailed(recentPaymentCheckMessage(lastBalance, order)));
            };
        };
        let balance = try {
            await ledger.icrc1_balance_of(getOrderPaymentSubaccount(orderId));
        } catch (e) {
            return #err(#PaymentFailed("Couldn't read the payment account: " # Error.message(e)));
        };
        PaymentCheck.record(paymentChecks, orderId, startedAt, balance);

        // The order may have been paid, cancelled or expired while the ledger call was in flight.
        let current = switch (Map.get(orders, Map.n32hash, orderId)) {
            case (?o) o;
            case null {
                return #err(#NotFoundError("Order with ID " # Nat32.toText(orderId) # " not found"));
            };
        };
        switch (paymentCheckStatus(current)) {
            case (#ok) {};
            case (#alreadyPaid) {
                PaymentCheck.forget(paymentChecks, orderId);
                return #ok(());
            };
            case (#err(message)) {
                PaymentCheck.forget(paymentChecks, orderId);
                return #err(#PaymentFailed(message));
            };
        };

        if (OrderExpiry.isPaidInFull(balance, ledgerDecimals, current.totals.total)) {
            PaymentCheck.forget(paymentChecks, orderId);
            ignore await* markOrderPaid(current, balance, ledgerDecimals);
            return #ok(());
        };

        if (OrderExpiry.isExpired(current, Time.now())) {
            PaymentCheck.forget(paymentChecks, orderId);
            await expireOrder<system>(orderId);
            return #err(#PaymentFailed("Order expired before the full payment was received"));
        };

        #err(#PaymentFailed(underpaidMessage(balance, current)));
    };

    /// The ledger that takes payment for `order`, and its decimals; null for a currency with no ledger.
    private func paymentLedger(order : Order) : ?(Wallet.LedgerActor, Nat32) {
        let ?token = PaymentCurrency.token(order.totals.total.currency) else return null;
        switch (Wallet.ledgerForToken(token), OrderExpiry.ledgerDecimals(token)) {
            case (?ledger, ?decimals) ?(ledger, decimals);
            case _ null;
        };
    };

    /// Last ledger read of each order's payment account by `checkPayment`, for its per-order limit.
    transient let paymentChecks = PaymentCheck.empty();

    /// What `checkPayment` reports for a check inside the cooldown, from the last read's balance.
    private func recentPaymentCheckMessage(lastBalance : ?Nat, order : Order) : Text {
        let retry = " Checked moments ago: try again in a few seconds.";
        switch (lastBalance) {
            case null "This order's payment is being checked." # retry;
            case (?balance) underpaidMessage(balance, order) # "." # retry;
        };
    };

    /// Why a `balance` read from the payment account does not pay `order`.
    private func underpaidMessage(balance : Nat, order : Order) : Text {
        if (balance == 0) {
            return "Payment not received";
        };
        "Received payment (" # Nat.toText(balance) # ") is less than the order total (" # Nat64.toText(order.totals.total.amount) # ")";
    };

    /// Whether `checkPayment` should read the ledger for `order`.
    private func paymentCheckStatus(order : Order) : {
        #ok;
        #alreadyPaid;
        #err : Text;
    } {
        if (PaymentCurrency.token(order.totals.total.currency) == null) {
            return #err("Order with ID " # Nat32.toText(order.id) # " is not paid on a supported ledger");
        };
        switch (order.status) {
            case (#created or #awaitingPayment) #ok;
            case (#paid or #processing or #partiallyFulfilled or #fulfilled) #alreadyPaid;
            case (#canceled) #err("Order was canceled. Any payment sent to it can be returned with reclaimOrderPayment");
            case (#refunded) #err("Order was refunded");
        };
    };

    /// Records `balance` (in units with `ledgerDecimals`) as the payment for `order`, marks it paid and notifies subscribers.
    /// Runs in the caller's message (`async*`), so nothing can cancel the order between the caller's
    /// status check and the write (BRE-167).
    private func markOrderPaid(order : Order, balance : Nat, ledgerDecimals : Nat32) : async* Order {
        let paymentAddress = getOrderPaymentSubaccount(order.id);
        let updatedOrder = await* storePaidOrder(
            order,
            {
                amount = {
                    amount = Nat64.fromNat(balance);
                    currency = order.totals.total.currency;
                    metadata = { decimals = ledgerDecimals };
                };
                paidAt = ?Time.now();
                provider = #ICRC1;
                reference = Hex.encode(Blob.toArray(Principal.toLedgerAccount(paymentAddress.owner, paymentAddress.subaccount)));
                status = #captured;
            },
        );
        if (updatedOrder.status != #paid) return updatedOrder;
        logger.info(
            "Order " # Nat32.toText(order.id) # " paid: received " # moneyText(balance, order.totals.total.currency) # " for a total of " # moneyText(Nat64.toNat(order.totals.total.amount), order.totals.total.currency)
        );
        updatedOrder;
    };

    /// Stores `order` as paid by `payment` and notifies subscribers. Re-reads the order first and leaves
    /// it as it is unless it's still awaiting payment: a cancelled order has released its stock, so
    /// marking it paid would sell units another order may hold (BRE-167). Funds sent to a cancelled
    /// order go back to the buyer with `reclaimOrderPayment`.
    private func storePaidOrder(order : Order, payment : PaymentRef) : async* Order {
        let ?live = Map.get(orders, Map.n32hash, order.id) else return order;
        if (not OrderExpiry.isAwaitingPayment(live.status)) return live;
        let updatedOrder : Order = {
            live with
            payment = ?payment;
            status = #paid;
            updatedAt = Time.now();
        };
        storeOrder(updatedOrder, #automatic, #paid({ provider = payment.provider }));
        await* publishOrderUpdated(updatedOrder);
        updatedOrder;
    };

    /// Marks order `orderId` fulfilled: every line not yet delivered is recorded as sent by `method`
    /// (`#inPerson` when null), then the order becomes `#fulfilled`. Allowed from `#paid`, or from
    /// `#partiallyFulfilled` (some digital lines already downloaded). Needs `Orders.Fulfill`.
    public shared ({ caller }) func markOrderFulfilled(orderId : OrderId, method : ?OrderEvents.DeliveryMethod) : async Result<Order, { #NotFoundError : Text; #InvalidStatus : Text; #Unauthorized : Text }> {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.ordersFulfill)) {
            return #err(#Unauthorized("Insufficient role to mark order as fulfilled"));
        };

        let order = switch (Map.get(orders, Map.n32hash, orderId)) {
            case (?o) o;
            case null {
                return #err(#NotFoundError("Order with ID " # Nat32.toText(orderId) # " not found"));
            };
        };

        switch (order.status) {
            case (#paid or #partiallyFulfilled) {};
            case _ {
                return #err(#InvalidStatus("Only paid or partially fulfilled orders can be marked as fulfilled"));
            };
        };

        let now = Time.now();
        let lineMethod = switch (method) { case (?m) m; case null #inPerson };
        let delivered = OrderEvents.deliveredLines(orderEvents, orderId);
        for (lineIndex in order.items.keys()) {
            if (not Set.contains(delivered, Nat.compare, lineIndex)) {
                ignore OrderEvents.append(orderEvents, orderId, now, #merchant, #lineDelivered({ lineIndex; method = lineMethod }));
            };
        };
        let (carrier, trackingNumber) = switch (lineMethod) {
            case (#shipped(s)) (s.carrier, s.trackingNumber);
            case _ (null, null);
        };
        let updatedOrder : Order = {
            order with
            status = #fulfilled;
            fulfillment = ?{ date = now; carrier; trackingNumber };
            updatedAt = now;
        };
        storeOrder(
            updatedOrder,
            #merchant,
            #fulfilled({
                method = OrderEvents.commonMethod(OrderEvents.deliveryMethods(orderEvents, orderId));
            }),
        );
        logger.info("Order " # Nat32.toText(orderId) # " marked fulfilled");
        await* publishOrderUpdated(updatedOrder);

        return #ok(updatedOrder);
    };

    /// Records that the buyer received digital line `lineIndex` of order `orderId`, the first time
    /// only. Once every line is delivered the order becomes `#fulfilled`, and while only some are,
    /// `#partiallyFulfilled` (BRE-133). Called by `requestDigitalDelivery` after it issued a ticket;
    /// re-reads the order, since that call awaited.
    private func recordDigitalDelivery(orderId : OrderId, lineIndex : Nat) : async* () {
        let ?order = Map.get(orders, Map.n32hash, orderId) else return;
        let delivered = OrderEvents.deliveredLines(orderEvents, orderId);
        if (Set.contains(delivered, Nat.compare, lineIndex)) return;

        let now = Time.now();
        ignore OrderEvents.append(orderEvents, orderId, now, #buyer, #lineDelivered({ lineIndex; method = #digital }));
        Set.add(delivered, Nat.compare, lineIndex);

        switch (order.status) {
            case (#paid or #processing or #partiallyFulfilled) {};
            case _ return;
        };
        let ?status = OrderEvents.fulfilmentStatus(order.items.size(), delivered) else return;
        let (newStatus, kind) : (OrderStatus, OrderEvents.OrderEventKind) = switch (status) {
            case (#fulfilled) (#fulfilled, #fulfilled({ method = OrderEvents.commonMethod(OrderEvents.deliveryMethods(orderEvents, orderId)) }));
            case (#partiallyFulfilled) (#partiallyFulfilled, #partiallyFulfilled);
        };
        if (newStatus == order.status) return;
        let updatedOrder : Order = {
            order with
            status = newStatus;
            fulfillment = if (newStatus == #fulfilled) ?{
                date = now;
                carrier = null;
                trackingNumber = null;
            } else order.fulfillment;
            updatedAt = now;
        };
        storeOrder(updatedOrder, #automatic, kind);
        logger.info("Order " # Nat32.toText(orderId) # (if (newStatus == #fulfilled) " fulfilled: every line delivered" else " partially fulfilled: line " # Nat.toText(lineIndex) # " delivered"));
        await* publishOrderUpdated(updatedOrder);
    };

    /// Order `orderId`'s payment account: the shop's subaccount for the order, the same on every ledger.
    private func getOrderPaymentSubaccount(orderId : OrderId) : Ledger.Account {
        return {
            owner = shopId;
            subaccount = ?Subaccount.fromNat32(orderId);
        };
    };

    /// Cancels `orderId` when still unpaid (`#created` or `#awaitingPayment`); rejects terminal or paid states.
    /// Only the order's buyer, or someone with `Orders.Cancel`, may cancel it.
    public shared ({ caller }) func cancelOrder(orderId : OrderId) : async Result<Order, { #NotFoundError : Text; #InputError : Text; #Unauthorized : Text }> {
        let order = switch (Map.get(orders, Map.n32hash, orderId)) {
            case (?o) o;
            case null {
                return #err(#NotFoundError("Order with ID " # Nat32.toText(orderId) # " not found"));
            };
        };

        if (not OrderAccess.canCancelOrder(authService, caller, order)) {
            return #err(#Unauthorized("Only the order's buyer, or someone with Orders.Cancel, can cancel this order"));
        };

        switch (order.status) {
            case (#paid) {
                return #err(#InputError("Cannot cancel order that has been paid"));
            };
            case (#processing) {
                return #err(#InputError("Cannot cancel order that is processing"));
            };
            case (#fulfilled) {
                return #err(#InputError("Cannot cancel order that has been fulfilled"));
            };
            case (#partiallyFulfilled) {
                return #err(#InputError("Cannot cancel order that has been partially fulfilled"));
            };
            case (#canceled) {
                return #err(#InputError("Order is already canceled"));
            };
            case (#refunded) {
                return #err(#InputError("Cannot cancel order that has been refunded"));
            };
            case (#created) {};
            case (#awaitingPayment) {};
        };
        // The buyer can still pay on Stripe's page until the session expires, so the order stays
        // open until then and settles itself: paid, or cancelled when the session expires.
        if (stripeSessionId(order) != null) {
            return #err(#InputError("This order is being paid by card. If it isn't paid, it cancels itself when the checkout expires."));
        };

        let byBuyer = OrderAccess.isBuyer(caller, order);
        let updatedOrder = if (byBuyer) storeCanceledOrder(order, #buyer, #buyer) else storeCanceledOrder(order, #merchant, #merchant);
        logger.info("Order " # Nat32.toText(orderId) # " canceled by " # (if (byBuyer) "its buyer" else "the shop"));
        await* publishOrderUpdated(updatedOrder);
        return #ok(updatedOrder);
    };

    /// Marks `order` cancelled for `reason` and returns the stored record.
    private func storeCanceledOrder(order : Order, by : OrderEvents.Initiator, reason : OrderEvents.CancelReason) : Order {
        let now = Time.now();
        let updatedOrder : Order = {
            order with
            status = #canceled;
            canceledAt = ?now;
            updatedAt = now;
        };
        storeOrder(updatedOrder, by, #canceled({ reason = ?reason }));
        updatedOrder;
    };

    /// ----- Order expiry and late payments (BRE-19) ----- ///

    /// Orders whose invoice subaccount is being refunded right now, so two refunds never run at once.
    transient let refundsInProgress = Map.new<OrderId, ()>();

    /// Orders awaiting payment, by when the expiry sweep looks at them next (see
    /// `OrderExpiry.ExpiryQueue`). Rebuilt by `rearmOrderTimers` on every install and upgrade.
    transient let expiryQueue : OrderExpiry.ExpiryQueue = Set.empty();

    /// The sweep's timer and the time it fires, when one is set.
    transient var expiryTimer : ?{ id : Timer.TimerId; at : Int } = null;

    /// True while the sweep runs, so a timer firing meanwhile doesn't start a second one.
    transient var expirySweepRunning = false;

    /// Queues `order` for the expiry sweep at its `expiresAt`.
    private func scheduleOrderExpiry<system>(order : Order) {
        OrderExpiry.scheduleExpiry(expiryQueue, order.expiresAt, order.id);
        armExpirySweep<system>();
    };

    /// Has the expiry sweep look at `orderId` again in `RETRY_DELAY_SECONDS`.
    private func retryExpiry<system>(orderId : OrderId, reason : Text) {
        logger.warning(
            "Couldn't expire order " # Nat32.toText(orderId) # ", retrying in " # debug_show (OrderExpiry.RETRY_DELAY_SECONDS) # "s: " # reason
        );
        OrderExpiry.scheduleExpiry(expiryQueue, Time.now() + OrderExpiry.RETRY_DELAY_SECONDS * 1_000_000_000, orderId);
        armExpirySweep<system>();
    };

    /// Sets the sweep's one timer for the earliest queued order, unless it is already set for then
    /// or earlier. While a sweep runs, it does nothing: the sweep sets the timer when it finishes.
    private func armExpirySweep<system>() {
        if (expirySweepRunning) return;
        let ?at = OrderExpiry.nextExpiry(expiryQueue) else return;
        switch (expiryTimer) {
            case (?timer) {
                if (timer.at <= at) return;
                Timer.cancelTimer(timer.id);
            };
            case null {};
        };
        let id = Timer.setTimer<system>(
            #nanoseconds(TimeUtil.remainingUntil(at, Time.now())),
            func() : async () {
                expiryTimer := null;
                await sweepExpiredOrders<system>();
            },
        );
        expiryTimer := ?{ id; at };
    };

    /// Expires every queued order that is due, `EXPIRY_READS_IN_FLIGHT` at a time: their payment
    /// account reads go out together, then each order is settled in turn. One timer for the whole
    /// shop rather than one per order, so a burst of orders expiring together can't fan out a call
    /// per order (BRE-110).
    private func sweepExpiredOrders<system>() : async () {
        if (expirySweepRunning) return;
        expirySweepRunning := true;
        try {
            var sendFailed = false;
            label sweep while (not sendFailed) {
                let now = Time.now();
                let due = OrderExpiry.takeDue(expiryQueue, now, OrderExpiry.EXPIRY_READS_IN_FLIGHT);
                if (due.size() == 0) break sweep;
                let reads = List.empty<(OrderId, ?(Nat32, async Nat))>();
                let cardOrders = List.empty<OrderId>();
                for (orderId in due.values()) {
                    let ?order = Map.get(orders, Map.n32hash, orderId) else continue;
                    if (not OrderExpiry.isExpired(order, now)) {
                        // Paid or cancelled since it was queued, or (requeued early) not due yet.
                        if (OrderExpiry.isAwaitingPayment(order.status)) {
                            OrderExpiry.scheduleExpiry(expiryQueue, order.expiresAt, orderId);
                        };
                    } else if (PaymentCurrency.isCard(order.totals.total.currency)) {
                        List.add(cardOrders, orderId);
                    } else if (sendFailed) {
                        retryExpiry<system>(orderId, "an earlier read in the batch couldn't be sent");
                    } else {
                        switch (paymentLedger(order)) {
                            case (?(ledger, decimals)) {
                                try {
                                    List.add(reads, (orderId, ?(decimals, ledger.icrc1_balance_of(getOrderPaymentSubaccount(orderId)))));
                                } catch (e) {
                                    sendFailed := true;
                                    retryExpiry<system>(orderId, Error.message(e));
                                };
                            };
                            case null List.add(reads, (orderId, null));
                        };
                    };
                };
                for ((orderId, read) in List.values(reads)) {
                    try {
                        switch (read) {
                            case (?(decimals, call)) await* settleExpiredOrder(orderId, await call, decimals, #expired);
                            case null await* settleExpiredOrder(orderId, 0, 0, #expired);
                        };
                    } catch (e) {
                        retryExpiry<system>(orderId, Error.message(e));
                    };
                };
                for (orderId in List.values(cardOrders)) {
                    try { await* settleExpiredCardOrder<system>(orderId) } catch (e) {
                        retryExpiry<system>(orderId, Error.message(e));
                    };
                };
            };
        } catch (e) {
            logger.error("The expiry sweep stopped early: " # Error.message(e));
        } finally {
            expirySweepRunning := false;
        };
        // Not in `finally`, which can't set timers: after a trap, the payment watcher sets it.
        armExpirySweep<system>();
    };

    /// Cancels `orderId` if it is still unpaid after `expiresAt`. Reads the invoice subaccount first: a
    /// payment that covers the total is honored, and anything less is returned to the buyer. If the
    /// ledger can't be reached, the expiry sweep tries again later.
    private func expireOrder<system>(orderId : OrderId) : async () {
        let ?order = Map.get(orders, Map.n32hash, orderId) else return;
        if (not OrderExpiry.isExpired(order, Time.now())) {
            return;
        };
        if (PaymentCurrency.isCard(order.totals.total.currency)) {
            return await* settleExpiredCardOrder<system>(orderId);
        };
        switch (paymentLedger(order)) {
            case (?(ledger, decimals)) {
                let balance = try {
                    await ledger.icrc1_balance_of(getOrderPaymentSubaccount(orderId));
                } catch (e) {
                    retryExpiry<system>(orderId, Error.message(e));
                    return;
                };
                await* settleExpiredOrder(orderId, balance, decimals, #expired);
            };
            case null await* settleExpiredOrder(orderId, 0, 0, #expired);
        };
    };

    /// Settles an expired order whose invoice subaccount was just read to hold `balance` (in units
    /// with `decimals`): marks it paid if that covers the total, else cancels it and returns any
    /// partial payment to the buyer.
    private func settleExpiredOrder(orderId : OrderId, balance : Nat, decimals : Nat32, reason : OrderEvents.CancelReason) : async* () {
        // The order may have been paid or cancelled while the ledger call was in flight.
        let ?current = Map.get(orders, Map.n32hash, orderId) else return;
        if (not OrderExpiry.isAwaitingPayment(current.status)) {
            return;
        };

        // A full payment that arrived before this check is honored, even after the deadline.
        if (OrderExpiry.isPaidInFull(balance, decimals, current.totals.total)) {
            ignore await* markOrderPaid(current, balance, decimals);
            return;
        };

        let canceled = storeCanceledOrder(current, #automatic, reason);
        logger.info(
            "Order " # Nat32.toText(orderId) # " expired unpaid and was canceled" # (if (balance == 0) "" else " (partial payment " # moneyText(balance, current.totals.total.currency) # " goes back to the buyer)")
        );
        await* publishOrderUpdated(canceled);
        if (balance == 0) {
            untrackOrderAccount(canceled.id);
        } else {
            switch (OrderExpiry.reclaimDestination(canceled.buyer, canceled.buyer, false, null)) {
                case (#ok(destination)) {
                    // Best effort: on failure the buyer can still call reclaimOrderPayment.
                    ignore await refundOrderBalance(canceled.id, destination);
                };
                case (#err(_)) {};
            };
        };
    };

    /// Recurring timer that reads unpaid orders' payment accounts. Set while any order awaits payment.
    transient var paymentWatchTimer : ?Timer.TimerId = null;

    /// True while the watcher is reading accounts, so a slow pass and the next timer tick never overlap.
    transient var paymentWatchRunning = false;

    /// Last order the watcher read. The next time it fires, it continues after this one.
    transient var paymentWatchCursor : ?OrderId = null;

    /// Starts the payment watcher if it isn't running.
    private func ensurePaymentWatcher<system>() {
        if (paymentWatchTimer != null) {
            return;
        };
        paymentWatchTimer := ?Timer.recurringTimer<system>(
            #seconds(OrderExpiry.PAYMENT_WATCH_INTERVAL_SECONDS),
            func() : async () { await watchPendingPayments<system>() },
        );
        logger.info("Started the payment watcher (every " # debug_show (OrderExpiry.PAYMENT_WATCH_INTERVAL_SECONDS) # "s)");
    };

    /// Marks unpaid orders paid as soon as their payment account covers the total, without waiting for
    /// the buyer's browser to call `checkPayment` or for the expiry timer. Reads only orders in
    /// `awaitingPaymentOrderIds`, so a pass costs time proportional to open orders, not to the shop's
    /// whole order history (BRE-100). Each pass reads `OrderExpiry.watchBatchSize` accounts (at most
    /// `MAX_ORDERS_PER_WATCH`), round-robin, `OrderExpiry.WATCH_READS_IN_FLIGHT` at a time, and the
    /// watcher stops itself once no order awaits payment.
    private func watchPendingPayments<system>() : async () {
        // Backstop for a sweep that trapped before setting its next timer.
        armExpirySweep<system>();
        if (paymentWatchRunning) {
            return;
        };
        let now = Time.now();
        let batch = OrderExpiry.nextWatchBatch(
            awaitingPaymentOrderIds,
            paymentWatchCursor,
            OrderExpiry.watchBatchSize(Set.size(awaitingPaymentOrderIds)),
            func(orderId) {
                switch (Map.get(orders, Map.n32hash, orderId)) {
                    case (?order) OrderExpiry.isWatched(order, now);
                    case null false;
                };
            },
        );
        if (batch.size() == 0) {
            switch (paymentWatchTimer) {
                case (?timerId) Timer.cancelTimer(timerId);
                case null {};
            };
            paymentWatchTimer := null;
            paymentWatchCursor := null;
            logger.info("Stopped the payment watcher: no order awaits payment");
            return;
        };
        paymentWatchRunning := true;
        try {
            // A few balance reads at a time: every call in flight holds a prepayment of the shop's
            // cycles, and too many at once leave none for checkPayment, refunds or notifications
            // (BRE-109). The cursor moves past each order once it has been read, so a pass that
            // stops early (a read that can't be sent) resumes there next time.
            var start = 0;
            var sendFailed = false;
            while (start < batch.size() and not sendFailed) {
                let window = Array.subArray(batch, start, Nat.min(OrderExpiry.WATCH_READS_IN_FLIGHT, batch.size() - start));
                let reads = List.empty<(OrderId, ?(Nat32, async Nat))>();
                label send for (orderId in window.values()) {
                    let ledger = switch (Map.get(orders, Map.n32hash, orderId)) {
                        case (?order) paymentLedger(order);
                        case null null;
                    };
                    switch (ledger) {
                        case (?(ledger, decimals)) {
                            try {
                                List.add(reads, (orderId, ?(decimals, ledger.icrc1_balance_of(getOrderPaymentSubaccount(orderId)))));
                            } catch (_) {
                                // Couldn't send: this order and the rest wait for the next pass.
                                sendFailed := true;
                                break send;
                            };
                        };
                        case null List.add(reads, (orderId, null));
                    };
                };
                for ((orderId, read) in List.values(reads)) {
                    switch (read) {
                        case (?(decimals, call)) {
                            let balance : ?Nat = try { ?(await call) } catch (_) {
                                null;
                            };
                            switch (balance) {
                                case (?balance) await capturePaymentIfFunded(orderId, balance, decimals);
                                case null {};
                            };
                        };
                        case null {};
                    };
                    paymentWatchCursor := ?orderId;
                };
                start += window.size();
            };
        } finally {
            paymentWatchRunning := false;
        };
    };

    /// Marks order `orderId` paid if `balance` (just read from its payment account, in units with
    /// `decimals`) covers the total. Ledger errors are skipped by the caller: the watcher's next pass,
    /// a `checkPayment` or the expiry timer reads the account again.
    private func capturePaymentIfFunded(orderId : OrderId, balance : Nat, decimals : Nat32) : async () {
        // The order may have been paid, cancelled or expired while the ledger call was in flight.
        let ?current = Map.get(orders, Map.n32hash, orderId) else return;
        if (not OrderExpiry.isAwaitingPayment(current.status)) {
            return;
        };
        if (OrderExpiry.isPaidInFull(balance, decimals, current.totals.total)) {
            ignore await* markOrderPaid(current, balance, decimals);
        };
    };

    /// Queues every order awaiting payment for the expiry sweep and sets its timer, and restarts the
    /// payment watcher if any order awaits payment. Timers don't survive upgrades, so `main.mo` calls this on every install and upgrade. Reads
    /// only `awaitingPaymentOrderIds`, not every order (BRE-100). Returns how many orders it re-armed.
    private func rearmOrderTimers<system>() : Nat {
        var rearmed = 0;
        for (orderId in Set.values(awaitingPaymentOrderIds)) {
            switch (Map.get(orders, Map.n32hash, orderId)) {
                case (?order) {
                    OrderExpiry.scheduleExpiry(expiryQueue, order.expiresAt, orderId);
                    rearmed += 1;
                };
                case null {};
            };
        };
        if (rearmed > 0) {
            armExpirySweep<system>();
            ensurePaymentWatcher<system>();
        };
        rearmed;
    };

    /// Sends everything above the ledger fee in order `orderId`'s invoice subaccount, on each supported
    /// ledger, to `destination`. Returns one entry per transfer made.
    private func refundOrderBalance(orderId : OrderId, destination : Ledger.Account) : async Result<[OrderRefund], RefundError> {
        if (Map.has(refundsInProgress, Map.n32hash, orderId)) {
            return #err(#TransferError("A refund for this order is already in progress"));
        };
        Map.set(refundsInProgress, Map.n32hash, orderId, ());

        let source = getOrderPaymentSubaccount(orderId);
        let refunds = List.empty<OrderRefund>();
        try {
            for (token in ["ICP", "ckUSDC"].values()) {
                switch (Wallet.ledgerForToken(token)) {
                    case null {};
                    case (?ledger) {
                        let balance = await ledger.icrc1_balance_of(source);
                        if (balance > 0) {
                            let fee = await ledger.icrc1_fee();
                            switch (OrderExpiry.refundableAmount(balance, fee)) {
                                case null {};
                                case (?amount) {
                                    let result = await ledger.icrc1_transfer({
                                        from_subaccount = source.subaccount;
                                        to = destination;
                                        amount = amount;
                                        fee = ?fee;
                                        memo = null;
                                        // Lets the ledger reject a repeat of this exact transfer (BRE-70).
                                        created_at_time = ?Nat64.fromNat(Int.abs(Time.now()));
                                    });
                                    switch (result) {
                                        case (#Ok(blockIndex)) {
                                            logger.info(
                                                "Refunded " # Nat.toText(amount) # " " # token # " from order " # Nat32.toText(orderId) # "'s payment account (block " # Nat.toText(blockIndex) # ")"
                                            );
                                            List.add(refunds, { token; amount; blockIndex });
                                        };
                                        case (#Err(e)) {
                                            logger.warning("Refund of " # token # " from order " # Nat32.toText(orderId) # " failed: " # debug_show (e));
                                            return #err(#TransferError(token # " transfer failed: " # debug_show (e)));
                                        };
                                    };
                                };
                            };
                        };
                    };
                };
            };
        } catch (e) {
            return #err(#TransferError(Error.message(e)));
        } finally {
            Map.delete(refundsInProgress, Map.n32hash, orderId);
        };

        // Whatever is left is below the ledger fee, so nobody can move it: stop listing the account.
        untrackOrderAccount(orderId);
        if (List.isEmpty(refunds)) {
            return #err(#NothingToReclaim("No funds above the ledger fee in this order's payment account"));
        };
        #ok(List.toArray(refunds));
    };

    /// Drops a cancelled order's payment account from the shop wallet's tracked accounts once it is empty
    /// or refunded (BRE-31). Its funds are never the shop's, so `listWalletAccounts` stops showing it. A
    /// payment that arrives later can still be reclaimed: `reclaimOrderPayment` finds the account by order ID.
    private func untrackOrderAccount(orderId : OrderId) {
        Wallet.untrackAccount(wallet, ?Subaccount.fromNat32(orderId));
    };

    /// Returns funds sent to a cancelled order's payment account (a late or partial payment), minus the
    /// ledger fee, on every supported ledger. The buyer may name the destination account (default: the
    /// buyer's own account). An Owner or Admin may trigger it, but the funds always go to the buyer.
    public shared ({ caller }) func reclaimOrderPayment(
        orderId : OrderId,
        to : ?RefundDestination,
    ) : async Result<[OrderRefund], { #NotFoundError : Text; #Unauthorized : Text; #InvalidStatus : Text; #TransferError : Text; #NothingToReclaim : Text }> {
        let ?order = Map.get(orders, Map.n32hash, orderId) else {
            return #err(#NotFoundError("Order with ID " # Nat32.toText(orderId) # " not found"));
        };
        let destination = switch (
            OrderExpiry.reclaimDestination(caller, order.buyer, OrderAccess.canCancelAllOrders(authService, caller), to)
        ) {
            case (#ok(account)) account;
            case (#err(message)) { return #err(#Unauthorized(message)) };
        };
        if (order.status != #canceled) {
            return #err(#InvalidStatus("Only payments to canceled orders can be reclaimed"));
        };
        switch (await refundOrderBalance(orderId, destination)) {
            case (#ok(refunds)) #ok(refunds);
            case (#err(#TransferError(message))) #err(#TransferError(message));
            case (#err(#NothingToReclaim(message))) #err(#NothingToReclaim(message));
        };
    };

    /// ----- Card payments through Stripe Checkout (BRE-123) ----- ///

    /// Stripe calls this minute, across the shop (`Checkout.CALLS_PER_MINUTE`).
    transient let stripeCalls = Checkout.newBudget();

    /// Orders whose Checkout Session is being created, so two are never created for one order and
    /// the expiry sweep leaves the order alone meanwhile.
    transient let stripeCheckoutsInProgress = Set.empty<OrderId>();

    /// Each open card order's Stripe payment page, so asking again costs no Stripe call. Lost on
    /// upgrade; `createStripeCheckout` then reads it from Stripe once.
    transient let stripeCheckoutUrls = Map.new<OrderId, Text>();

    /// The outcall transform for Stripe replies (`Stripe.transform`): pure, so anyone may call it.
    public query func stripeTransform(args : Management.TransformArgs) : async Management.HttpRequestResult {
        Stripe.transform(args.response);
    };

    /// The Checkout Session paying `order`, once `createStripeCheckout` has made one.
    private func stripeSessionId(order : Order) : ?Text {
        switch (order.payment) {
            case (?payment) if (payment.provider == #Stripe) ?payment.reference else null;
            case null null;
        };
    };

    private func expectedSession(order : Order, sessionId : Text) : Checkout.Expected {
        {
            sessionId;
            orderId = order.id;
            shopId = Principal.toText(shopId);
            currency = "usd";
            amount = Nat64.toNat(order.totals.total.amount);
        };
    };

    /// The buyer of card order `orderId` gets a Stripe Checkout page to pay it on. The first call
    /// creates the session (expiring in about 31 minutes, when the order expires too) and records it
    /// on the order; later calls return the same page. `successUrl` and `cancelUrl` are where Stripe
    /// sends the buyer afterwards: `https://`, or `http://` to localhost for development. Stripe
    /// replaces `{CHECKOUT_SESSION_ID}` in them. Payment is confirmed by `checkPayment`, or by the
    /// expiry sweep when the session ends.
    public shared ({ caller }) func createStripeCheckout(
        orderId : OrderId,
        successUrl : Text,
        cancelUrl : Text,
    ) : async Result<{ url : Text }, { #NotFoundError : Text; #Unauthorized : Text; #InvalidStatus : Text; #InputError : Text; #Busy : Text; #PaymentFailed : Text }> {
        let ?order = Map.get(orders, Map.n32hash, orderId) else {
            return #err(#NotFoundError("Order with ID " # Nat32.toText(orderId) # " not found"));
        };
        if (not OrderAccess.isBuyer(caller, order)) {
            return #err(#Unauthorized("Only the order's buyer can pay it"));
        };
        if (not PaymentCurrency.isCard(order.totals.total.currency)) {
            return #err(#InvalidStatus("This order isn't paid by card"));
        };
        if (not OrderExpiry.isAwaitingPayment(order.status) or OrderExpiry.isExpired(order, Time.now())) {
            return #err(#InvalidStatus("This order no longer awaits payment"));
        };
        if (order.totals.total.metadata.decimals != PaymentCurrency.CARD_DECIMALS) {
            return #err(#InvalidStatus("This order's prices aren't in cents"));
        };
        if (not Checkout.isAllowedReturnUrl(successUrl) or not Checkout.isAllowedReturnUrl(cancelUrl)) {
            return #err(#InputError("Return URLs must be https:// (or http:// to localhost) and at most " # Nat.toText(Checkout.MAX_RETURN_URL) # " characters"));
        };
        let ?key = stripe.restrictedKey else {
            return #err(#InvalidStatus("This shop no longer takes card payments"));
        };
        if (Set.contains(stripeCheckoutsInProgress, Nat32.compare, orderId)) {
            return #err(#Busy("This order's checkout is being created"));
        };

        switch (stripeSessionId(order)) {
            case (?sessionId) {
                switch (Map.get(stripeCheckoutUrls, Map.n32hash, orderId)) {
                    case (?url) return #ok({ url });
                    case null {};
                };
                if (not Checkout.takeCall(stripeCalls, Time.now())) {
                    return #err(#Busy("Too many card payments right now. Try again in a minute."));
                };
                let reply = await* Stripe.retrieveSession(key, sessionId, stripeTransform);
                switch (reply) {
                    case (#session(session)) {
                        switch (Checkout.outcome(session, expectedSession(order, sessionId)), session.url) {
                            case (#open, ?url) {
                                Map.set(stripeCheckoutUrls, Map.n32hash, orderId, url);
                                return #ok({ url });
                            };
                            case (#paid, _) return #err(#InvalidStatus("This order is already paid. Check its payment to update it."));
                            case _ return #err(#InvalidStatus("This order's checkout has ended"));
                        };
                    };
                    case (#error({ message })) return #err(#PaymentFailed(message));
                    case (#list) return #err(#PaymentFailed("Unexpected reply from Stripe"));
                };
            };
            case null {};
        };

        Set.add(stripeCheckoutsInProgress, Nat32.compare, orderId);
        try {
            await* openStripeCheckout<system>(order, key, successUrl, cancelUrl);
        } finally {
            Set.remove(stripeCheckoutsInProgress, Nat32.compare, orderId);
        };
    };

    /// Creates `order`'s Checkout Session (one node), reads it back (replicated) to confirm what
    /// Stripe made, and records it on the order. Runs under the `stripeCheckoutsInProgress` lock.
    private func openStripeCheckout<system>(
        order : Order,
        key : Text,
        successUrl : Text,
        cancelUrl : Text,
    ) : async* Result<{ url : Text }, { #NotFoundError : Text; #Unauthorized : Text; #InvalidStatus : Text; #InputError : Text; #Busy : Text; #PaymentFailed : Text }> {
        let now = Time.now();
        if (not Checkout.takeCall(stripeCalls, now)) {
            return #err(#Busy("Too many card payments right now. Try again in a minute."));
        };
        let expiresAtSeconds = Int.abs(now) / 1_000_000_000 + Checkout.SESSION_SECONDS;
        let request : Checkout.SessionRequest = {
            orderId = order.id;
            shopId = Principal.toText(shopId);
            currency = "usd";
            items = Array.map<{ title : Text; unitPrice : Money; quantity : Nat32 }, Checkout.LineItem>(
                order.items,
                func(item) = {
                    name = item.title;
                    unitAmount = Nat64.toNat(item.unitPrice.amount);
                    quantity = Nat32.toNat(item.quantity);
                },
            );
            successUrl;
            cancelUrl;
            expiresAtSeconds;
        };
        // One key per attempt: a retry with the same key and a later `expires_at` would be refused.
        let idempotencyKey = Principal.toText(shopId) # "-order-" # Nat32.toText(order.id) # "-" # Nat.toText(expiresAtSeconds);
        let created = await* Stripe.createSession(key, request, idempotencyKey, stripeTransform);
        let sessionId = switch (created) {
            case (#session(session)) session.id;
            case (#error({ message })) return #err(#PaymentFailed("Stripe couldn't start the checkout: " # message));
            case (#list) return #err(#PaymentFailed("Unexpected reply from Stripe"));
        };

        // One node made the create, so confirm with a replicated read before trusting its URL.
        if (not Checkout.takeCall(stripeCalls, Time.now())) {
            return #err(#Busy("Too many card payments right now. Try again in a minute."));
        };
        let confirmed = await* Stripe.retrieveSession(key, sessionId, stripeTransform);
        let url = switch (confirmed) {
            case (#session(session)) {
                switch (Checkout.outcome(session, expectedSession(order, sessionId)), session.url) {
                    case (#open, ?url) url;
                    case (#mismatch(reason), _) {
                        logger.error("Stripe session " # sessionId # " for order " # Nat32.toText(order.id) # " doesn't match it: " # reason);
                        return #err(#PaymentFailed("Stripe's checkout doesn't match this order"));
                    };
                    case _ return #err(#PaymentFailed("Stripe's checkout isn't open"));
                };
            };
            case (#error({ message })) return #err(#PaymentFailed("Couldn't confirm the checkout with Stripe: " # message));
            case (#list) return #err(#PaymentFailed("Unexpected reply from Stripe"));
        };

        // The order may have been cancelled or expired during the calls. Then nobody gets this
        // session's URL, and Stripe expires it unused.
        let ?current = Map.get(orders, Map.n32hash, order.id) else {
            return #err(#NotFoundError("Order with ID " # Nat32.toText(order.id) # " not found"));
        };
        if (not OrderExpiry.isAwaitingPayment(current.status) or stripeSessionId(current) != null) {
            return #err(#InvalidStatus("This order no longer awaits payment"));
        };
        let opened : Order = {
            current with
            status = #awaitingPayment;
            payment = ?{
                provider = #Stripe;
                reference = sessionId;
                paidAt = null;
                status = #unpaid;
                amount = current.totals.total;
            };
            expiresAt = expiresAtSeconds * 1_000_000_000 + Checkout.SETTLE_DELAY_NANOS;
            updatedAt = Time.now();
        };
        storeOrder(opened, #buyer, #awaitingPayment({ provider = #Stripe }));
        scheduleOrderExpiry<system>(opened);
        Map.set(stripeCheckoutUrls, Map.n32hash, order.id, url);
        logger.info("Order " # Nat32.toText(order.id) # " sent to Stripe Checkout (session " # sessionId # ")");
        await* publishOrderUpdated(opened);
        #ok({ url });
    };

    /// `checkPayment` for a card order: reads its Checkout Session from Stripe, at most once per
    /// order every `PaymentCheck.COOLDOWN_NANOS`, and marks the order paid if Stripe charged the
    /// total, or cancels it if the session expired.
    private func checkCardPayment<system>(order : Order) : async* Result<(), { #NotFoundError : Text; #Unauthorized : Text; #PaymentFailed : Text }> {
        switch (order.status) {
            case (#created or #awaitingPayment) {};
            case (#paid or #processing or #partiallyFulfilled or #fulfilled) return #ok(());
            case (#canceled) return #err(#PaymentFailed("Order was canceled"));
            case (#refunded) return #err(#PaymentFailed("Order was refunded"));
        };
        let ?sessionId = stripeSessionId(order) else {
            if (OrderExpiry.isExpired(order, Time.now())) {
                await expireOrder<system>(order.id);
                return #err(#PaymentFailed("Order expired before the card payment was started"));
            };
            return #err(#PaymentFailed("Card payment not started"));
        };
        let ?key = stripe.restrictedKey else {
            return #err(#PaymentFailed("This shop no longer takes card payments"));
        };
        let startedAt = Time.now();
        switch (PaymentCheck.begin(paymentChecks, order.id, startedAt)) {
            case (#read) {};
            case (#recent(_)) return #err(#PaymentFailed("Checked moments ago: try again in a few seconds."));
        };
        if (not Checkout.takeCall(stripeCalls, startedAt)) {
            PaymentCheck.forget(paymentChecks, order.id);
            return #err(#PaymentFailed("Too many payment checks right now. Try again in a minute."));
        };
        let reply = await* Stripe.retrieveSession(key, sessionId, stripeTransform);
        PaymentCheck.record(paymentChecks, order.id, startedAt, 0);
        switch (await* applyCardReply(order.id, sessionId, reply)) {
            case (#paid) {
                PaymentCheck.forget(paymentChecks, order.id);
                #ok(());
            };
            case (#open) #err(#PaymentFailed("Payment not received"));
            case (#closed(message) or #failed(message)) {
                PaymentCheck.forget(paymentChecks, order.id);
                #err(#PaymentFailed(message));
            };
            case (#retry(message)) #err(#PaymentFailed(message));
        };
    };

    /// Settles an expired card order. No session yet: cancelled. Otherwise its session is read
    /// from Stripe: paid → paid, expired → cancelled. An open session or a failed read is retried
    /// by the expiry sweep later.
    private func settleExpiredCardOrder<system>(orderId : OrderId) : async* () {
        let ?order = Map.get(orders, Map.n32hash, orderId) else return;
        if (not OrderExpiry.isAwaitingPayment(order.status)) return;
        if (Set.contains(stripeCheckoutsInProgress, Nat32.compare, orderId)) {
            retryExpiry<system>(orderId, "its Stripe checkout is being created");
            return;
        };
        let ?sessionId = stripeSessionId(order) else {
            return await* settleExpiredOrder(orderId, 0, 0, #expired);
        };
        let ?key = stripe.restrictedKey else {
            logger.warning("Order " # Nat32.toText(orderId) # " expired with no Stripe key to check session " # sessionId # "; cancelling it. If the buyer paid, refund them from the Stripe dashboard.");
            return await* settleExpiredOrder(orderId, 0, 0, #expired);
        };
        if (not Checkout.takeCall(stripeCalls, Time.now())) {
            retryExpiry<system>(orderId, "too many Stripe calls this minute");
            return;
        };
        let reply = await* Stripe.retrieveSession(key, sessionId, stripeTransform);
        switch (await* applyCardReply(orderId, sessionId, reply)) {
            case (#paid or #closed(_) or #failed(_)) {};
            case (#open) retryExpiry<system>(orderId, "its Stripe session " # sessionId # " is still open");
            case (#retry(message)) retryExpiry<system>(orderId, message);
        };
    };

    /// Applies a Stripe `reply` about card order `orderId`'s session `sessionId`: marks the order
    /// paid if the session charged its total, cancels it if the session expired or isn't this
    /// order's. Re-reads the order first, since it may have changed during the Stripe call.
    private func applyCardReply(orderId : OrderId, sessionId : Text, reply : Checkout.Reply) : async* {
        #paid;
        #open;
        #closed : Text;
        #failed : Text;
        #retry : Text;
    } {
        let ?current = Map.get(orders, Map.n32hash, orderId) else return #closed("Order not found");
        if (not OrderExpiry.isAwaitingPayment(current.status)) {
            return if (current.status == #canceled or current.status == #refunded) #closed("Order was canceled") else #paid;
        };
        if (stripeSessionId(current) != ?sessionId) return #retry("The order's checkout changed; check again");
        let session = switch (reply) {
            case (#session(s)) s;
            case (#error({ message })) return #retry("Couldn't read the payment from Stripe: " # message);
            case (#list) return #retry("Unexpected reply from Stripe");
        };
        switch (Checkout.outcome(session, expectedSession(current, sessionId))) {
            case (#paid) {
                ignore await* storePaidOrder(
                    current,
                    {
                        provider = #Stripe;
                        reference = sessionId;
                        paidAt = ?Time.now();
                        status = #captured;
                        amount = current.totals.total;
                    },
                );
                Map.delete(stripeCheckoutUrls, Map.n32hash, orderId);
                logger.info("Order " # Nat32.toText(orderId) # " paid by card (Stripe session " # sessionId # ")");
                #paid;
            };
            case (#open or #pending) #open;
            case (#expired) {
                Map.delete(stripeCheckoutUrls, Map.n32hash, orderId);
                await* settleExpiredOrder(orderId, 0, 0, #expired);
                #closed("The card checkout expired before payment");
            };
            case (#mismatch(reason)) {
                logger.error("Stripe session " # sessionId # " doesn't match order " # Nat32.toText(orderId) # ": " # reason # "; cancelling the order");
                Map.delete(stripeCheckoutUrls, Map.n32hash, orderId);
                await* settleExpiredOrder(orderId, 0, 0, #paymentMismatch);
                #failed("The card payment doesn't match this order");
            };
        };
    };

    func orderId(o : Order) : OrderId = o.id;

    /// Owner or Admin: every stored order, newest first, a page at a time (see `lib/Pagination`:
    /// pass `next` back as `after`). Other callers get an empty page.
    public query ({ caller }) func listOrders(after : ?OrderId, limit : ?Nat) : async Pagination.Page<Order, OrderId> {
        if (not OrderAccess.canViewAllOrders(authService, caller)) {
            return { items = []; next = null };
        };

        let list = List.empty<Order>();

        Map.forEach<OrderId, Order>(
            orders,
            func(_orderId, order) {
                List.add(list, order);
            },
        );

        Pagination.page(List.toArray(list), orderId, Pagination.descending(Nat32.compare), after, limit);
    };

    /// Orders placed by `caller`, newest first, a page at a time. Empty for the anonymous principal.
    public query ({ caller }) func listMyOrders(after : ?OrderId, limit : ?Nat) : async Pagination.Page<Order, OrderId> {
        let list = List.empty<Order>();

        Map.forEach<OrderId, Order>(
            orders,
            func(_orderId, order) {
                if (OrderAccess.isBuyer(caller, order)) {
                    List.add(list, order);
                };
            },
        );

        Pagination.page(List.toArray(list), orderId, Pagination.descending(Nat32.compare), after, limit);
    };

    /// Order `orderId` for its buyer, `Orders.View`, controllers (core, for the shops it hosts) or
    /// Marketplace. Core reads the orders it missed `OrderUpdated` notifications for, after finding
    /// them in `listOrderEvents` (BRE-203), so the same callers may read both.
    public query ({ caller }) func getMyOrder(orderId : OrderId) : async Result<Order, { #NotFoundError : Text; #Unauthorized : Text }> {
        let order = switch (Map.get(orders, Map.n32hash, orderId)) {
            case (?o) o;
            case null {
                return #err(#NotFoundError("Order with ID " # Nat32.toText(orderId) # " not found"));
            };
        };

        let isMarketplace = Principal.isController(caller) or AuthService.isMarketplace(authService, caller);
        if (not (isMarketplace or OrderAccess.canViewOrder(authService, caller, order))) {
            return #err(#Unauthorized("Only the order buyer, Owner or Admin can view this order"));
        };

        return #ok(order);
    };

    /// Order `orderId`'s history, oldest first (BRE-133), for its buyer or an Owner or Admin. Events
    /// name who acted only by role (`#buyer`, `#merchant`, `#automatic`), never by principal.
    public query ({ caller }) func getOrderHistory(orderId : OrderId) : async Result<[OrderEvents.OrderEvent], { #NotFoundError : Text; #Unauthorized : Text }> {
        let ?order = Map.get(orders, Map.n32hash, orderId) else {
            return #err(#NotFoundError("Order with ID " # Nat32.toText(orderId) # " not found"));
        };
        if (not OrderAccess.canViewOrder(authService, caller, order)) {
            return #err(#Unauthorized("Only the order buyer or staff with Orders.View can view this order"));
        };
        #ok(OrderEvents.history(orderEvents, orderId));
    };

    /// Every order's history across the shop, oldest first, after sequence number `after` (see
    /// `lib/Pagination`). A subscriber that missed `OrderUpdated` notifications pages from the last
    /// `seq` it applied. Controllers (core, for the shops it hosts), Marketplace and `Orders.View`
    /// only: events reveal what was ordered when. Other callers get an empty page.
    public query ({ caller }) func listOrderEvents(after : ?Nat, limit : ?Nat) : async Pagination.Page<OrderEvents.OrderEvent, Nat> {
        if (not (Principal.isController(caller) or AuthService.isMarketplace(authService, caller) or OrderAccess.canViewAllOrders(authService, caller))) {
            return { items = []; next = null };
        };
        OrderEvents.listAfter(orderEvents, after, limit);
    };
};
