import { type Nat32 } "mo:base/Nat32";
import { type Result } "mo:core/Result";
import Array "mo:core/Array";
import List "mo:core/List";
import Nat32 "mo:core/Nat32";
import Time "mo:core/Time";
import Map "mo:map/Map";
import OrderExpiry "order_expiry";
import {
    type Order;
    type OrderId;
    type ProductId;
    type VariantId;
    type Currency;
    type LineItemSnapshot;
    type Money;
    type SKU;
    type PriceContext;
    type ProductVariant;
    type ShippingAddress;
} "../types";

module {
    public class OrderService(dependencies : { productVariants : Map.Map<VariantId, ProductVariant> }) {
        public let productVariants = dependencies.productVariants;
    };

    public func buildOrder(
        service : OrderService,
        buyer : Principal,
        input : {
            orderId : OrderId;
            items : [{
                productId : ProductId;
                variantId : VariantId;
                title : Text;
                quantity : Nat32;
                unitPrice : Money; // At order creation; the catalog price may change later.
            }];
            paymentCurrency : Currency;
            shippingAddress : ?ShippingAddress;
        },
    ) : Result<Order, { #InternalError : Text }> {
        let { items; paymentCurrency; orderId; shippingAddress } = input;
        let lineItems = List.empty<LineItemSnapshot>();

        if (Array.size(items) == 0) {
            return #err(#InternalError("Order must contain at least one item"));
        };

        for (item in Array.values(items)) {
            let lineItem = switch (_itemToLineItemSnapshot(service, item, paymentCurrency)) {
                case (#ok(li)) li;
                case (#err(#InternalError { message; productId; variantId })) {
                    return #err(#InternalError("Failed to create line item snapshot for product " # Nat32.toText(productId) # " variant " # Nat32.toText(variantId) # ": " # message));
                };
            };
            List.add(lineItems, lineItem);
        };

        var subtotal : Nat64 = 0;
        for (lineItem in List.toArray(lineItems).vals()) {
            subtotal += lineItem.unitPrice.amount * Nat32.toNat64(lineItem.quantity);
        };

        let metadata = {
            decimals = items[0].unitPrice.metadata.decimals; // Assumes every line has the same decimals (`createOrder` rescales USDC lines to ckUSDC's).
        };

        let now = Time.now();
        let order : Order = {
            id = orderId;
            buyer = buyer;
            items = List.toArray(lineItems);
            status = #created;
            createdAt = now;
            updatedAt = now;
            canceledAt = null;
            expiresAt = OrderExpiry.expiresAt(now);
            notes = null;
            payment = null;
            shippingAddress;
            fulfillment = null;
            totals = {
                subtotal = {
                    currency = paymentCurrency;
                    amount = subtotal;
                    metadata;
                };
                discounts = { currency = paymentCurrency; amount = 0; metadata };
                tax = { currency = paymentCurrency; amount = 0; metadata };
                shipping = { currency = paymentCurrency; amount = 0; metadata };
                total = {
                    currency = paymentCurrency;
                    amount = subtotal;
                    metadata;
                };
            };
        };

        return #ok(order);
    };

    private func _itemToLineItemSnapshot(
        service : OrderService,
        item : {
            productId : ProductId;
            variantId : VariantId;
            title : Text;
            quantity : Nat32;
            unitPrice : Money;
        },
        paymentCurrency : Currency,
    ) : Result<LineItemSnapshot, { #InternalError : { message : Text; productId : ProductId; variantId : VariantId } }> {
        let variant = switch (Map.get(service.productVariants, Map.n32hash, item.variantId)) {
            case (?v) v;
            case null {
                return #err(#InternalError({ message = "Variant not found"; productId = item.productId; variantId = item.variantId }));
            };
        };

        return #ok({
            productId = item.productId;
            variantId = item.variantId;
            title = item.title;
            sku = ?variant.sku;
            options = []; // TODO: implement
            unitPrice = {
                currency = paymentCurrency;
                amount = item.unitPrice.amount;
                metadata = item.unitPrice.metadata;
            };
            quantity = item.quantity;
            // The catalog prices at purchase time, so the invoice can show the order's USD value
            // without a fresh rate fetch (BRE-22).
            listedPrices = variant.price.catalog;
        });
    };
};
