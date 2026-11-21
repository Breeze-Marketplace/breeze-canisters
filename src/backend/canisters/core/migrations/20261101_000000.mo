import Map "mo:map/Map";
import Set "mo:map/Set";

module {
    type Time = Int;

    type Address = {
        line1 : Text;
        line2 : ?Text;
        city : Text;
        region : Text;
        postalCode : Text;
        country : Text;
    };

    type ShopLocation = {
        #FullAddress : Address;
        #PostalCode : Text;
    };

    type ShopDetails = {
        name : Text;
        description : Text;
        logoUrl : ?Text;
        bannerImageUrl : ?Text;
        physicalLocation : ?ShopLocation;
        locationPublic : Bool;
    };

    type ShopRegistryItem = {
        canisterId : Principal;
        owner : Principal;
        registeredBy : Principal;
        registrationDate : Time;
        shopDetails : ShopDetails;
    };

    type UserRegistryItem = {
        registrationDate : Time;
    };

    type XrcAsset = {
        class_ : { #Cryptocurrency; #FiatCurrency };
        symbol : Text;
    };

    type ExchangeRateMetadata = {
        decimals : Nat32;
        base_asset_num_queried_sources : Nat64;
        base_asset_num_received_rates : Nat64;
        quote_asset_num_queried_sources : Nat64;
        quote_asset_num_received_rates : Nat64;
        standard_deviation : Nat64;
        forex_timestamp : ?Nat64;
    };

    type ExchangeRate = {
        base_asset : XrcAsset;
        quote_asset : XrcAsset;
        timestamp : Nat64;
        rate : Nat64;
        metadata : ExchangeRateMetadata;
    };

    type ExchangeRateCacheEntry = {
        xrcResponse : ExchangeRate;
        descaledRate : Float;
        lastUpdated : Time;
    };

    type Money = {
        amount : Nat64;
        currency : {
            class_ : { #Cryptocurrency; #FiatCurrency };
            symbol : Text;
        };
        metadata : { decimals : Nat32 };
    };

    type LineItemSnapshot = {
        productId : Nat32;
        variantId : Nat32;
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

    /// `shopId:orderId`
    type OrderKey = Text;

    type Order = {
        id : Nat32;
        shopId : Principal;
        buyer : Principal;
        createdAt : Time;
        items : [LineItemSnapshot];
        totals : Totals;
        status : OrderStatus;
    };

    type QuoteId = Nat;

    type QuoteStatus = {
        #Pending;
        #Paid;
        #Creating;
        #Created : Principal;
        #Refunding;
        #Refunded;
    };

    type Quote = {
        id : QuoteId;
        owner : Principal;
        name : Text;
        normalizedName : Text;
        description : Text;
        currency : { #ICP; #ckUSDC };
        amount : Nat;
        createdAt : Time;
        expiresAt : Time;
        status : QuoteStatus;
        lastError : ?Text;
    };

    type ShopCreationState = {
        quotes : Map.Map<QuoteId, Quote>;
        quotesByOwner : Map.Map<Principal, [QuoteId]>;
        reservedNames : Map.Map<Text, QuoteId>;
        var nextQuoteId : QuoteId;
        var priceUsdCents : Nat;
    };

    type OldActor = {};

    type NewActor = {
        userRegistry : Map.Map<Principal, UserRegistryItem>;
        shopRegistry : Map.Map<Principal, ShopRegistryItem>;
        shopRegistryByOwner : Map.Map<Principal, Principal>;
        shopRegistryByName : Map.Map<Text, Principal>;
        managedShopsByUser : Map.Map<Principal, [Principal]>;
        exchangeRateCache : Map.Map<(XrcAsset, XrcAsset), ExchangeRateCacheEntry>;
        admins : Set.Set<Principal>;
        orders : Map.Map<OrderKey, Order>;
        ordersByBuyer : Map.Map<Principal, [OrderKey]>;
        unsubscribedShops : Set.Set<Principal>;
        shopCreationState : ShopCreationState;
        var shopCount : Nat;
    };

    public func migration(_ : OldActor) : NewActor {
        {
            userRegistry = Map.new<Principal, UserRegistryItem>();
            shopRegistry = Map.new<Principal, ShopRegistryItem>();
            shopRegistryByOwner = Map.new<Principal, Principal>();
            shopRegistryByName = Map.new<Text, Principal>();
            managedShopsByUser = Map.new<Principal, [Principal]>();
            exchangeRateCache = Map.new<(XrcAsset, XrcAsset), ExchangeRateCacheEntry>();
            admins = Set.new<Principal>();
            orders = Map.new<OrderKey, Order>();
            ordersByBuyer = Map.new<Principal, [OrderKey]>();
            unsubscribedShops = Set.new<Principal>();
            shopCreationState = {
                quotes = Map.new<QuoteId, Quote>();
                quotesByOwner = Map.new<Principal, [QuoteId]>();
                reservedNames = Map.new<Text, QuoteId>();
                var nextQuoteId = 0;
                // ShopCreationAPI.DEFAULT_PRICE_USD_CENTS when this migration was written.
                var priceUsdCents = 1_000;
            };
            var shopCount = 0;
        };
    };
};
