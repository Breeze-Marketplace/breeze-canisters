import Array "mo:core/Array";
import Int "mo:core/Int";
import List "mo:core/List";
import Map "mo:map/Map";
import CoreMap "mo:core/Map";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Order "mo:core/Order";
import Set "mo:core/Set";

// Adds `orderEvents`, every order's history (BRE-133), and rebuilds what it can for orders stored
// before it existed, from the times each order records: created at `createdAt`, paid at
// `payment.paidAt`, fulfilled at `fulfillment.date`, cancelled at `canceledAt`. Rebuilt events are
// `#automatic`; a rebuilt cancellation has no reason and a rebuilt fulfilment no method unless the
// order kept a carrier or tracking number. Past digital downloads were never recorded, so no
// `#lineDelivered` events are rebuilt. Events are numbered in time order (ties by order ID).
// Pure, with no division or array indexing, so it can't trap.
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

    // Inlined copies of the event types in ../lib/order_events.mo as of this migration.
    type DeliveryMethod = {
        #shipped : { carrier : ?Text; trackingNumber : ?Text };
        #digital;
        #inPerson;
    };

    type CancelReason = { #expired; #buyer; #merchant; #paymentMismatch };

    type OrderEventKind = {
        #created;
        #awaitingPayment : { provider : { #ICRC1; #Manual; #Stripe } };
        #paid : { provider : { #ICRC1; #Manual; #Stripe } };
        #lineDelivered : { lineIndex : Nat; method : DeliveryMethod };
        #fulfilled : { method : ?DeliveryMethod };
        #partiallyFulfilled;
        #canceled : { reason : ?CancelReason };
        #refunded;
    };

    type OrderEvent = {
        seq : Nat;
        orderId : OrderId;
        at : Int;
        by : { #buyer; #merchant; #automatic };
        kind : OrderEventKind;
    };

    type Log = {
        events : CoreMap.Map<Nat, OrderEvent>;
        bySubject : Set.Set<(OrderId, Nat)>;
        var nextSeq : Nat;
    };

    // Only the fields this migration reads or adds; every other field carries over unchanged.
    type OldActor = {
        orders : Map.Map<OrderId, Order>;
    };

    type NewActor = {
        orders : Map.Map<OrderId, Order>;
        orderEvents : Log;
    };

    type Rebuilt = { orderId : OrderId; at : Int; kind : OrderEventKind };

    func compareOrderSeq((o1, s1) : (OrderId, Nat), (o2, s2) : (OrderId, Nat)) : Order.Order {
        switch (Nat32.compare(o1, o2)) {
            case (#equal) Nat.compare(s1, s2);
            case other other;
        };
    };

    func compareRebuilt(a : Rebuilt, b : Rebuilt) : Order.Order {
        switch (Int.compare(a.at, b.at)) {
            case (#equal) Nat32.compare(a.orderId, b.orderId);
            case other other;
        };
    };

    func rebuild(order : Order, out : List.List<Rebuilt>) {
        List.add(out, { orderId = order.id; at = order.createdAt; kind = #created });
        switch (order.payment) {
            case (?{ paidAt = ?at; provider }) List.add(out, { orderId = order.id; at; kind = #paid({ provider }) });
            case _ {};
        };
        switch (order.fulfillment) {
            case (?{ date; carrier; trackingNumber }) {
                let method : ?DeliveryMethod = if (carrier == null and trackingNumber == null) null else ?#shipped({
                    carrier;
                    trackingNumber;
                });
                List.add(out, { orderId = order.id; at = date; kind = #fulfilled({ method }) });
            };
            case null {};
        };
        switch (order.canceledAt) {
            case (?at) List.add(out, { orderId = order.id; at; kind = #canceled({ reason = null }) });
            case null {};
        };
    };

    public func migration(old : OldActor) : NewActor {
        let rebuilt = List.empty<Rebuilt>();
        for ((_, order) in Map.entries(old.orders)) rebuild(order, rebuilt);
        // `List.add` within one order keeps its events in time order, and the stable sort keeps it.
        let sorted = Array.sort(List.toArray(rebuilt), compareRebuilt);

        let events = CoreMap.empty<Nat, OrderEvent>();
        let bySubject = Set.empty<(OrderId, Nat)>();
        var seq = 0;
        for (e in sorted.values()) {
            CoreMap.add(events, Nat.compare, seq, { seq; orderId = e.orderId; at = e.at; by = #automatic; kind = e.kind });
            Set.add(bySubject, compareOrderSeq, (e.orderId, seq));
            seq += 1;
        };
        {
            orders = old.orders;
            orderEvents = { events; bySubject; var nextSeq = seq };
        };
    };
};
