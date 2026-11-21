import Map "mo:map/Map";
import Nat32 "mo:core/Nat32";
import Set "mo:core/Set";

// Adds `awaitingPaymentOrderIds`, the IDs of orders still awaiting payment (`#created` or
// `#awaitingPayment`), so the payment watcher and the post-upgrade timer re-arming read only
// those orders instead of every order the shop ever took (BRE-100). Built once here from `orders`;
// the shop keeps it current from then on. Pure, and a single pass over `orders`, so it can't trap.
module {
    // Inlined copies of the order types in ../types.mo as of this migration.
    type Time = Int;
    type OrderId = Nat32;
    type ProductId = Nat32;
    type VariantId = Nat32;

    type Money = {
        amount : Nat64;
        currency : {
            class_ : { #Cryptocurrency; #FiatCurrency };
            symbol : Text;
        };
        metadata : { decimals : Nat32 };
    };

    type LineItemSnapshot = {
        productId : ProductId;
        variantId : VariantId;
        title : Text;
        sku : ?Text;
        options : [(Text, Text)];
        quantity : Nat32;
        unitPrice : Money;
        listedPrices : [Money];
    };

    type Totals = {
        subtotal : Money;
        discounts : Money;
        shipping : Money;
        tax : Money;
        total : Money;
    };

    type OrderStatus = {
        #created;
        #awaitingPayment;
        #paid;
        #processing;
        #partiallyFulfilled;
        #fulfilled;
        #canceled;
        #refunded;
    };

    type PaymentRef = {
        provider : { #ICRC1; #Manual; #Stripe };
        reference : Text;
        amount : Money;
        status : { #unpaid; #authorized; #captured; #failed; #refunded };
        paidAt : ?Time;
    };

    type ShippingAddress = {
        name : Text;
        line1 : Text;
        line2 : ?Text;
        city : Text;
        region : Text;
        postalCode : Text;
        country : Text;
        phone : ?Text;
    };

    type Fulfillment = {
        carrier : ?Text;
        trackingNumber : ?Text;
        date : Time;
    };

    type Order = {
        id : OrderId;
        buyer : Principal;
        createdAt : Time;
        updatedAt : Time;
        canceledAt : ?Time;
        expiresAt : Time;
        items : [LineItemSnapshot];
        totals : Totals;
        status : OrderStatus;
        payment : ?PaymentRef;
        shippingAddress : ?ShippingAddress;
        fulfillment : ?Fulfillment;
        notes : ?Text;
    };

    // Only the fields this migration reads or adds; every other field carries over unchanged.
    type OldActor = {
        orders : Map.Map<OrderId, Order>;
    };

    type NewActor = {
        orders : Map.Map<OrderId, Order>;
        awaitingPaymentOrderIds : Set.Set<OrderId>;
    };

    public func migration(old : OldActor) : NewActor {
        let awaitingPaymentOrderIds = Set.empty<OrderId>();
        for ((orderId, order) in Map.entries(old.orders)) {
            switch (order.status) {
                case (#created or #awaitingPayment) Set.add(awaitingPaymentOrderIds, Nat32.compare, orderId);
                case _ {};
            };
        };
        { orders = old.orders; awaitingPaymentOrderIds };
    };
};
