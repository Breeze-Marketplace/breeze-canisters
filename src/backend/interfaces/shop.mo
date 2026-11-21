import Result "mo:base/Result";
import Time "mo:core/Time";

module {
    public type ProductId = Nat32;
    public type VariantId = Nat32;
    public type Currency = {
        class_ : { #FiatCurrency; #Cryptocurrency };
        symbol : Text;
    };
    public type SKU = Text;

    public type ProductStatus = {
        #Draft;
        #Active;
        #Inactive;
        #Archived;
    };

    public type ProductAttribute = {
        key : Text;
        value : Text;
    };

    public type Money = {
        currency : Currency;
        amount : Nat64;
        metadata : {
            decimals : Nat32; // e.g. 2 for USD, 8 for ICP
        };
    };

    public type Address = {
        line1 : Text;
        line2 : ?Text;
        city : Text;
        region : Text; // state/province
        postalCode : Text;
        country : Text;
    };

    public type ShopLocation = {
        #PostalCode : Text;
        #FullAddress : Address;
    };

    public type PriceContext = {
        catalog : [Money];
    };

    /// What the marketplace knows of the release a variant sells (BRE-187).
    public type MarketplaceRelease = {
        kind : { #Single; #EP; #Album };
        artist : Text;
        genre : ?Text;
    };

    public type ProductVariant = {
        id : VariantId;
        productId : ProductId;
        name : Text;
        sku : SKU;
        price : PriceContext;
        status : ProductStatus;
        attributes : [ProductAttribute];
        imageUrls : [Text];
        /// The release the variant sells; null for other variants and from shops before BRE-187.
        release : ?MarketplaceRelease;
    };

    public type ProductType = {
        #Physical;
        #Digital;
        #Service;
    };

    public type Product = {
        id : ProductId;
        title : Text;
        description : Text;
        status : ProductStatus;
        variants : [ProductVariant];
        productType : ProductType;
        tags : [Text];
        category : ?Text;
    };

    public type Totals = {
        subtotal : Money;
        discounts : Money;
        tax : Money;
        shipping : Money;
        total : Money;
    };

    public type LineItemSnapshot = {
        productId : ProductId;
        variantId : VariantId;
        title : Text;
        sku : ?Text;
        options : [(Text, Text)]; // e.g. [("Size","M"),("Color","Black")]
        unitPrice : Money; // snapshot at purchase time
        listedPrices : [Money]; // all prices listed at purchase time
        quantity : Nat32;
    };

    public type OrderStatus = {
        #created; // order record exists, not yet paid
        #awaitingPayment;
        #paid;
        #processing;
        #partiallyFulfilled;
        #fulfilled;
        #canceled;
        #refunded;
    };

    public type OrderId = Nat32;

    public type ProductUpdatedEventData = {
        productId : ProductId;
        title : Text;
        description : Text;
        variants : [{
            variantId : VariantId;
            name : Text;
            sku : SKU;
            priceCatalog : [Money];
            status : ProductStatus;
            attributes : [ProductAttribute];
            imageUrls : [Text];
            /// The release the variant sells; null for other variants and from shops before BRE-187.
            release : ?MarketplaceRelease;
        }];
        tags : [Text];
        category : ?Text;
        productType : ProductType;
    };

    public type ProductUpdatedEvent = { data : ProductUpdatedEventData };

    public type ProductUpdatedEventListener = shared (event : ProductUpdatedEvent) -> async ();

    public type ProductDeletedEvent = { data : { productId : ProductId } };

    public type ProductDeletedEventListener = shared (event : ProductDeletedEvent) -> async ();

    public type ShopUpdatedEventData = {
        name : Text;
        description : Text;
        logoUrl : Text;
        bannerImageUrl : ?Text;
        physicalLocation : ?ShopLocation;
        locationPublic : Bool;
        /// Null from a shop older than BRE-197, or for a presentation this interface doesn't know.
        presentation : ?ShopPresentation;
    };

    /// Whether the shop shows as a storefront or an artist page (BRE-197).
    public type ShopPresentation = { #storefront; #artist };

    public type ShopDetailsUpdatedEvent = { data : ShopUpdatedEventData };

    public type ShopDetailsUpdatedEventListener = shared (event : ShopDetailsUpdatedEvent) -> async ();

    public type OrderUpdatedEventData = {
        orderId : OrderId;
        buyer : Principal;
        items : [LineItemSnapshot];
        totals : Totals;
        status : OrderStatus;
        createdAt : Time.Time;
        /// The order log event the notification is for; null from shops before BRE-203.
        logEvent : ?OrderLogEvent;
    };

    /// Where an event sits in a shop's order log.
    public type OrderLogEvent = { seq : Nat; at : Int };

    public type OrderUpdatedEvent = { data : OrderUpdatedEventData };

    public type OrderUpdatedEventListener = shared (event : OrderUpdatedEvent) -> async ();

    /// What core reads of an order event in the shop's log (`listOrderEvents`, BRE-133). The shop's
    /// event has more; Candid drops what core doesn't name. `kind` is optional so a kind or payload
    /// this interface doesn't know decodes as null instead of failing the page.
    public type OrderEvent = {
        seq : Nat;
        orderId : OrderId;
        at : Int;
        kind : ?OrderEventKind;
    };

    /// The kinds of `OrderEvent`, with only the payload fields core reads (none).
    public type OrderEventKind = {
        #created;
        #awaitingPayment : {};
        #paid : {};
        #lineDelivered : {};
        #fulfilled : {};
        #partiallyFulfilled;
        #canceled : {};
        #refunded;
    };

    /// What core reads of an order from `getMyOrder`: the fields of its order listing.
    public type Order = {
        id : OrderId;
        buyer : Principal;
        items : [LineItemSnapshot];
        totals : Totals;
        status : OrderStatus;
        createdAt : Time.Time;
    };

    public type GetOrderResponse = Result.Result<Order, { #NotFoundError : Text; #Unauthorized : Text }>;

    public type SetMediaCanisterIdResponse = Result.Result<(), { #Unauthorized : Text }>;
    public type SetOwnerResponse = Result.Result<(), { #Unauthorized : Text }>;

    /// The events a shop publishes.
    public type EventKind = {
        #ProductUpdated;
        #ProductDeleted;
        #ShopDetailsUpdated;
        #OrderUpdated;
    };

    public type Shop = actor {
        getProducts : query (after : ?ProductId, limit : ?Nat) -> async {
            items : [Product];
            next : ?ProductId;
        };
        getShopDetails : query () -> async {
            name : Text;
            description : Text;
            logoUrl : ?Text;
            bannerImageUrl : ?Text;
            physicalLocation : ?ShopLocation;
            showPhysicalLocation : Bool;
        };
        subscribeToShopDetailsUpdated : (callback : ShopDetailsUpdatedEventListener) -> async ();
        subscribeToProductUpdated : (callback : ProductUpdatedEventListener) -> async ();
        subscribeToProductDeleted : (callback : ProductDeletedEventListener) -> async ();
        subscribeToOrderUpdated : (callback : OrderUpdatedEventListener) -> async ();
        /// Missing on shop versions from before BRE-195: calling it there fails.
        getMyEventSubscriptions : query () -> async [EventKind];
        /// The shop's order log after `after`, oldest first. Missing before BRE-133; an empty page
        /// for callers that aren't controllers, Marketplace or `Orders.View`.
        listOrderEvents : query (after : ?Nat, limit : ?Nat) -> async {
            items : [OrderEvent];
            next : ?Nat;
        };
        /// Refuses core (`#Unauthorized`) on shop versions from before BRE-203.
        getMyOrder : query (orderId : OrderId) -> async GetOrderResponse;
        setMediaCanisterId : (mediaCanisterId : Principal) -> async Result.Result<(), { #Unauthorized : Text }>;
        setOwner : (newOwner : Principal) -> async Result.Result<(), { #Unauthorized : Text }>;
    };
};
