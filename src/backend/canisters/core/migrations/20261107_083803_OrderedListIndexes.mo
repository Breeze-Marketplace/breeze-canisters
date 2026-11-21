import CoreSet "mo:core/Set";
import Int "mo:core/Int";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Map "mo:map/Map";

/// BRE-96: ordered indexes for core's list queries, so each page is read from its cursor instead of
/// sorting the whole collection. Adds the registry's shops in canister ID order and by display name,
/// and turns each buyer's list of order keys into a set of order cursors, newest first. `orders` and
/// `shopRegistry` are read, not changed.
module {
    type Currency = {
        class_ : { #FiatCurrency; #Cryptocurrency };
        symbol : Text;
    };

    type Money = {
        currency : Currency;
        amount : Nat64;
        metadata : { decimals : Nat32 };
    };

    type Address = {
        line1 : Text;
        line2 : ?Text;
        city : Text;
        region : Text;
        postalCode : Text;
        country : Text;
    };

    type ShopLocation = {
        #PostalCode : Text;
        #FullAddress : Address;
    };

    type ShopRegistryItem = {
        canisterId : Principal;
        owner : Principal;
        shopDetails : {
            name : Text;
            description : Text;
            logoUrl : ?Text;
            bannerImageUrl : ?Text;
            physicalLocation : ?ShopLocation;
            locationPublic : Bool;
        };
        registeredBy : Principal;
        registrationDate : Int;
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

    type Order = {
        id : Nat32;
        shopId : Principal;
        buyer : Principal;
        items : [LineItemSnapshot];
        totals : {
            subtotal : Money;
            discounts : Money;
            tax : Money;
            shipping : Money;
            total : Money;
        };
        status : {
            #created;
            #awaitingPayment;
            #paid;
            #processing;
            #partiallyFulfilled;
            #fulfilled;
            #canceled;
            #refunded;
        };
        createdAt : Int;
    };

    type ShopNameKey = { name : Text; canisterId : Principal };

    type UserOrderCursor = {
        createdAt : Int;
        orderId : Nat32;
        shopCanisterId : Principal;
    };

    type OldActor = {
        shopRegistry : Map.Map<Principal, ShopRegistryItem>;
        orders : Map.Map<Text, Order>;
        ordersByBuyer : Map.Map<Principal, [Text]>;
    };

    type NewActor = {
        shopRegistry : Map.Map<Principal, ShopRegistryItem>;
        orders : Map.Map<Text, Order>;
        shopIdsOrdered : CoreSet.Set<Principal>;
        shopsByDisplayName : CoreSet.Set<ShopNameKey>;
        ordersByBuyer : Map.Map<Principal, CoreSet.Set<UserOrderCursor>>;
    };

    // Same order as `ShopAPI.compareShopNameKey`.
    func compareShopNameKey(a : ShopNameKey, b : ShopNameKey) : {
        #less;
        #equal;
        #greater;
    } {
        switch (Text.compare(a.name, b.name)) {
            case (#equal) { Principal.compare(a.canisterId, b.canisterId) };
            case (order) { order };
        };
    };

    // Same order as `OrderAPI.compareUserOrderCursor`: newest first, then order ID descending, then shop.
    func compareUserOrderCursor(a : UserOrderCursor, b : UserOrderCursor) : {
        #less;
        #equal;
        #greater;
    } {
        switch (Int.compare(b.createdAt, a.createdAt)) {
            case (#equal) {};
            case (order) { return order };
        };
        switch (Nat32.compare(b.orderId, a.orderId)) {
            case (#equal) {
                Principal.compare(a.shopCanisterId, b.shopCanisterId);
            };
            case (order) { order };
        };
    };

    public func migration(old : OldActor) : NewActor {
        let shopIdsOrdered = CoreSet.empty<Principal>();
        let shopsByDisplayName = CoreSet.empty<ShopNameKey>();
        for (item in Map.vals(old.shopRegistry)) {
            CoreSet.add(shopIdsOrdered, Principal.compare, item.canisterId);
            CoreSet.add(shopsByDisplayName, compareShopNameKey, { name = item.shopDetails.name; canisterId = item.canisterId });
        };

        // Rebuilt from the orders themselves: a key in the old index with no order, or whose order
        // belongs to another buyer, was never listed, so it is dropped.
        let ordersByBuyer = Map.new<Principal, CoreSet.Set<UserOrderCursor>>();
        for ((buyer, keys) in Map.entries(old.ordersByBuyer)) {
            let cursors = CoreSet.empty<UserOrderCursor>();
            for (key in keys.values()) {
                switch (Map.get(old.orders, Map.thash, key)) {
                    case (?order) {
                        if (order.buyer == buyer) {
                            CoreSet.add(cursors, compareUserOrderCursor, { createdAt = order.createdAt; orderId = order.id; shopCanisterId = order.shopId });
                        };
                    };
                    case null {};
                };
            };
            if (not CoreSet.isEmpty(cursors)) {
                Map.set(ordersByBuyer, Map.phash, buyer, cursors);
            };
        };

        {
            shopRegistry = old.shopRegistry;
            orders = old.orders;
            shopIdsOrdered;
            shopsByDisplayName;
            ordersByBuyer;
        };
    };
};
