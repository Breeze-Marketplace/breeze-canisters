import Map "mo:map/Map";

// Order notifications name their order log event (BRE-203), so a subscriber that sees a sequence
// number skipped knows it missed one. The subscribers' callbacks are stored with the event type, so
// they are re-typed: a callback that took the old event takes the new one (its extra field is dropped
// by a subscriber that doesn't know it). Every subscription stays as it was.
module {
    type Currency = {
        class_ : { #Cryptocurrency; #FiatCurrency };
        symbol : Text;
    };
    type Money = {
        currency : Currency;
        amount : Nat64;
        metadata : { decimals : Nat32 };
    };
    type LineItemSnapshot = {
        productId : Nat32;
        variantId : Nat32;
        title : Text;
        sku : ?Text;
        options : [(Text, Text)];
        unitPrice : Money;
        listedPrices : [Money];
        quantity : Nat32;
    };
    type Totals = {
        subtotal : Money;
        discounts : Money;
        tax : Money;
        shipping : Money;
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

    type OldEventData = {
        orderId : Nat32;
        buyer : Principal;
        items : [LineItemSnapshot];
        totals : Totals;
        status : OrderStatus;
        createdAt : Int;
    };
    type NewEventData = OldEventData and { logEvent : ?{ seq : Nat; at : Int } };

    type OldListener = shared { data : OldEventData } -> async ();
    type NewListener = shared { data : NewEventData } -> async ();

    type OldActor = {
        orderUpdatedSubscribers : Map.Map<Principal, OldListener>;
    };
    type NewActor = {
        orderUpdatedSubscribers : Map.Map<Principal, NewListener>;
    };

    public func migration(old : OldActor) : NewActor {
        let orderUpdatedSubscribers = Map.new<Principal, NewListener>();
        for ((subscriber, listener) in Map.entries(old.orderUpdatedSubscribers)) {
            Map.set<Principal, NewListener>(orderUpdatedSubscribers, Map.phash, subscriber, listener);
        };
        { orderUpdatedSubscribers };
    };
};
