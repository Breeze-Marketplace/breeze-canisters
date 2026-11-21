import Blob "mo:core/Blob";
import Principal "mo:core/Principal";
import Map "mo:map/Map";

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

    type WalletAccount = {
        owner : Principal;
        subaccount : ?Blob;
        name : ?Text;
        identifier : Text;
    };

    type Wallet = {
        owner : Principal;
        accounts : Map.Map<Text, WalletAccount>;
        accountsByIdentifier : Map.Map<Text, Text>;
    };

    type ProductId = Nat32;
    type VariantId = Nat32;
    type OrderId = Nat32;
    type SKU = Text;

    type Money = {
        amount : Nat64;
        currency : {
            class_ : { #Cryptocurrency; #FiatCurrency };
            symbol : Text;
        };
        metadata : { decimals : Nat32 };
    };

    type ProductStatus = { #Draft; #Active; #Inactive; #Archived };

    type ProductType = { #Physical; #Digital; #Service };

    type ProductAttribute = { key : Text; value : Text };

    type ProductAttributeConfig = [(key : Text, values : [Text])];

    type ProductVariant = {
        id : VariantId;
        productId : ProductId;
        name : Text;
        sku : SKU;
        price : { catalog : [Money] };
        status : ProductStatus;
        attributes : [ProductAttribute];
        imageUrls : [Text];
    };

    type Product = {
        id : ProductId;
        title : Text;
        description : Text;
        status : ProductStatus;
        productType : ProductType;
        tags : [Text];
        category : ?Text;
        variants : [ProductVariant];
    };

    type InventoryEntry = {
        productId : ProductId;
        variantId : VariantId;
        stock : Nat32;
        reserved : Nat32;
        lowStockThreshold : Nat32;
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

    type Role = { #Owner; #Admin; #Marketplace };

    type ProductUpdatedEventListener = shared {
        data : {
            productId : ProductId;
            title : Text;
            description : Text;
            productType : ProductType;
            tags : [Text];
            category : ?Text;
            variants : [{
                variantId : VariantId;
                name : Text;
                sku : SKU;
                priceCatalog : [Money];
                status : ProductStatus;
                attributes : [ProductAttribute];
                imageUrls : [Text];
            }];
        };
    } -> async ();

    type ProductDeletedEventListener = shared {
        data : { productId : ProductId };
    } -> async ();

    type ShopDetailsUpdatedEventListener = shared {
        data : {
            name : Text;
            description : Text;
            logoUrl : Text;
            bannerImageUrl : ?Text;
            physicalLocation : ?ShopLocation;
            locationPublic : Bool;
        };
    } -> async ();

    type OrderUpdatedEventListener = shared {
        data : {
            orderId : OrderId;
            buyer : Principal;
            createdAt : Time;
            items : [LineItemSnapshot];
            totals : Totals;
            status : OrderStatus;
        };
    } -> async ();

    type XrcAsset = {
        class_ : { #Cryptocurrency; #FiatCurrency };
        symbol : Text;
    };

    type ExchangeRateCacheEntry = {
        xrcResponse : {
            base_asset : XrcAsset;
            quote_asset : XrcAsset;
            timestamp : Nat64;
            rate : Nat64;
            metadata : {
                decimals : Nat32;
                base_asset_num_queried_sources : Nat64;
                base_asset_num_received_rates : Nat64;
                quote_asset_num_queried_sources : Nat64;
                quote_asset_num_received_rates : Nat64;
                standard_deviation : Nat64;
                forex_timestamp : ?Nat64;
            };
        };
        descaledRate : Float;
        lastUpdated : Time;
    };

    type OldActor = {};

    type NewActor = {
        var initialized : Bool;
        var mediaCanisterId : ?Principal;
        var name : Text;
        var description : Text;
        var logoUrl : ?Text;
        var bannerImageUrl : ?Text;
        var physicalLocation : ?ShopLocation;
        var showPhysicalLocation : Bool;
        var wallet : Wallet;
        var productIdCounter : ProductId;
        products : Map.Map<ProductId, Product>;
        productAttributeConfigs : Map.Map<ProductId, ProductAttributeConfig>;
        var variantIdCounter : VariantId;
        productVariants : Map.Map<VariantId, ProductVariant>;
        productVariantsBySKU : Map.Map<SKU, VariantId>;
        inventory : Map.Map<VariantId, InventoryEntry>;
        orders : Map.Map<OrderId, Order>;
        var orderIdCounter : OrderId;
        var hmacSecretKey : Blob;
        var hmacSecretKeyVersion : Nat8;
        digitalAssetKeys : Map.Map<Text, Text>;
        rolesByPrincipal : Map.Map<Principal, [Role]>;
        productUpdatedSubscribers : Map.Map<Principal, ProductUpdatedEventListener>;
        productDeletedSubscribers : Map.Map<Principal, ProductDeletedEventListener>;
        shopDetailsUpdatedSubscribers : Map.Map<Principal, ShopDetailsUpdatedEventListener>;
        orderUpdatedSubscribers : Map.Map<Principal, OrderUpdatedEventListener>;
        exchangeRateCache : Map.Map<(XrcAsset, XrcAsset), ExchangeRateCacheEntry>;
    };

    public func migration(_ : OldActor) : NewActor {
        {
            var initialized = false;
            var mediaCanisterId = null;
            // The actor body replaces name, description and the wallet owner from the init args
            // and the canister's own principal on the first install.
            var name = "";
            var description = "";
            var logoUrl = null;
            var bannerImageUrl = null;
            var physicalLocation = null;
            var showPhysicalLocation = false;
            var wallet = {
                owner = Principal.anonymous();
                accounts = Map.new<Text, WalletAccount>();
                accountsByIdentifier = Map.new<Text, Text>();
            };
            var productIdCounter = 0;
            products = Map.new<ProductId, Product>();
            productAttributeConfigs = Map.new<ProductId, ProductAttributeConfig>();
            var variantIdCounter = 0;
            productVariants = Map.new<VariantId, ProductVariant>();
            productVariantsBySKU = Map.new<SKU, VariantId>();
            inventory = Map.new<VariantId, InventoryEntry>();
            orders = Map.new<OrderId, Order>();
            var orderIdCounter = 0;
            // In production, use a secure random key and rotate it periodically.
            var hmacSecretKey = Blob.fromArray([0x01, 0x02, 0x03, 0x04]);
            // DigitalDelivery.TOKEN_VERSION when this migration was written.
            var hmacSecretKeyVersion = 1;
            digitalAssetKeys = Map.new<Text, Text>();
            rolesByPrincipal = Map.new<Principal, [Role]>();
            productUpdatedSubscribers = Map.new<Principal, ProductUpdatedEventListener>();
            productDeletedSubscribers = Map.new<Principal, ProductDeletedEventListener>();
            shopDetailsUpdatedSubscribers = Map.new<Principal, ShopDetailsUpdatedEventListener>();
            orderUpdatedSubscribers = Map.new<Principal, OrderUpdatedEventListener>();
            exchangeRateCache = Map.new<(XrcAsset, XrcAsset), ExchangeRateCacheEntry>();
        };
    };
};
