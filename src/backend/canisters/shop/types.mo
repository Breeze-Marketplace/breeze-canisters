import Nat64 "mo:base/Nat64";
import Float "mo:base/Float";
import Time "mo:core/Time";

import XRC "canister:xrc";

import ShopThemes "lib/shop_theme";
import StorefrontLayouts "lib/storefront_layout";
import Music "lib/music";
import ShopPresentation "lib/presentation";

module {
    public type ProductId = Nat32;
    public type VariantId = Nat32;
    public type OrderId = Nat32;
    public type Currency = {
        class_ : { #Cryptocurrency; #FiatCurrency };
        symbol : Text;
    };
    public type SKU = Text;

    public type PriceContext = {
        // the merchant-defined catalog prices at time of checkout
        catalog : [Money]; // e.g. [{currency="ICP";...}, {currency="USD";...}]
    };

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

    public type ProductVariant = {
        id : VariantId;
        productId : ProductId;
        name : Text;
        sku : SKU;
        price : PriceContext;
        status : ProductStatus;
        attributes : [ProductAttribute];
        imageUrls : [Text];
        /// What the variant delivers from the music library (BRE-182); null for today's one-media-key delivery.
        deliverable : ?Deliverable;
        /// `#minimum` makes the price the least a buyer may pay (name-your-price, BRE-184). This shop
        /// always sets it; it's optional so clients can read shops still on a version without it, where
        /// null means `#fixed`.
        pricing : ?Pricing;
    };

    /// The music library (BRE-182), defined with its rules in `lib/music.mo`.
    public type TrackId = Music.TrackId;
    public type ReleaseId = Music.ReleaseId;
    public type AudioFormat = Music.AudioFormat;
    public type AudioFile = Music.AudioFile;
    public type Track = Music.Track;
    public type Release = Music.Release;
    public type Deliverable = Music.Deliverable;
    public type Pricing = Music.Pricing;
    public type MarketplaceRelease = Music.MarketplaceRelease;
    public type MusicLibrary = Music.Library;

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
        tags : [Text];
        category : ?Text;
        productType : ProductType;
        /// When the product was created. Products from before BRE-128 have their shop's upgrade time.
        createdAt : Time.Time;
    };

    /// A variant as `getProducts` returns it: with the release it sells, so core's full marketplace sync
    /// carries the same music fields as the product-updated event (BRE-187).
    public type CatalogVariant = ProductVariant and {
        release : ?MarketplaceRelease;
    };

    public type CatalogProduct = {
        id : ProductId;
        title : Text;
        description : Text;
        status : ProductStatus;
        variants : [CatalogVariant];
        tags : [Text];
        category : ?Text;
        productType : ProductType;
        createdAt : Time.Time;
    };

    public type ProductAttributeConfig = [(key : Text, values : [Text])];

    public type BuyerField = {
        name : Text;
        config : {
            #Text;
            #Number;
            #Email;
            #Phone;
            #Address;
            #Date;
            #Time;
            #DateTime;
            #Select : { options : [Text] };
            #MultiSelect : { options : [Text] };
        };
        required : Bool;
    };

    public type ProductFullfillmentConfig = {
        #Digital : {
            deliveryMethod : Text;
            slaNote : Text;
            buyerFields : [BuyerField];
            returnPolicy : Text;
        };
        #Physical : {
            allowPickup : Bool;
            allowDelivery : Bool;
            slaNote : Text;
            buyerFields : [BuyerField];
            returnPolicy : Text;
        };
        #Service : {
            buyerFields : [BuyerField];
            returnPolicy : Text;
        };
    };

    // Use "minor units" (cents) to avoid floats.
    public type Money = {
        currency : Currency;
        amount : Nat64;
        metadata : {
            decimals : Nat32; // e.g. 2 for USD, 8 for ICP
        };
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

    public type PaymentStatus = {
        #unpaid;
        #authorized;
        #captured;
        #failed;
        #refunded;
    };

    public type PaymentProvider = {
        #ICRC1;
        #Stripe;
        #Manual;
    };

    public type PaymentRef = {
        provider : PaymentProvider;
        reference : Text; // tx hash, block index, intent id, etc.
        paidAt : ?Time.Time;
        status : PaymentStatus;
        amount : Money;
    };

    public type Address = {
        line1 : Text;
        line2 : ?Text;
        city : Text;
        region : Text; // state/province
        postalCode : Text;
        country : Text;
    };

    public type ShippingAddress = Address and {
        name : Text;
        phone : ?Text;
    };

    public type Fulfillment = {
        date : Time.Time;
        trackingNumber : ?Text;
        carrier : ?Text;
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

    public type Totals = {
        subtotal : Money;
        discounts : Money;
        tax : Money;
        shipping : Money;
        total : Money;
    };

    public type Order = {
        id : OrderId;
        buyer : Principal;
        items : [LineItemSnapshot];
        totals : Totals;
        status : OrderStatus;
        shippingAddress : ?ShippingAddress;
        fulfillment : ?Fulfillment;
        payment : ?PaymentRef;
        createdAt : Time.Time;
        updatedAt : Time.Time;
        canceledAt : ?Time.Time;
        /// When the order is cancelled if still unpaid. Set by the shop canister.
        expiresAt : Time.Time;
        notes : ?Text;
    };

    public type ShopLocation = {
        #PostalCode : Text;
        #FullAddress : Address;
    };

    public type Alert = {
        #LowStock : {
            product : { id : ProductId; name : Text };
            currentStock : Nat32;
        };
        #MissingImage : { product : { id : ProductId; name : Text } };
    };

    public type InventoryEntry = {
        productId : ProductId;
        variantId : VariantId;
        stock : Nat32;
        reserved : Nat32;
        lowStockThreshold : Nat32;
    };

    public type CartItem = {
        productId : ProductId;
        variantId : VariantId;
        quantity : Nat32;

        // optional lightweight snapshot for faster UI rendering
        title : ?Text;
        imageUrl : ?Text;
    };

    public type Cart = {
        owner : Principal; // if stored server-side
        items : [CartItem];
        createdAt : Time.Time;
        updatedAt : Time.Time;
    };

    public type ExchangeRateCacheEntry = {
        xrcResponse : XRC.ExchangeRate;
        descaledRate : Float.Float;
        lastUpdated : Time.Time;
    };

    public type ProductVariantWithInventory = {
        id : VariantId;
        productId : ProductId;
        name : Text;
        sku : SKU;
        price : PriceContext;
        status : ProductStatus;
        attributes : [ProductAttribute];
        imageUrls : [Text];
        deliverable : ?Deliverable;
        pricing : ?Pricing;
        stock : Nat32;
        stockStatus : { #InStock; #OutOfStock; #LowStock };
    };

    public type ProductWithInventory = {
        id : ProductId;
        title : Text;
        description : Text;
        status : ProductStatus;
        variants : [ProductVariantWithInventory];
        tags : [Text];
        category : ?Text;
        productType : ProductType;
    };

    public type InventoryItem = {
        variant : {
            id : VariantId;
            sku : SKU;
            name : Text;
        };
        product : {
            id : ProductId;
            title : Text;
        };
        stock : Nat32;
        reserved : Nat32;
        available : Nat32;
        lowStockThreshold : Nat32;
        status : { #InStock; #OutOfStock; #LowStock };
    };

    public type UpdateInventoryRequest = {
        variantId : VariantId;
        stockDelta : Int32;
        reservedDelta : Int32;
        lowStockThreshold : ?Nat32;
    };

    public type TranferFundsToMainError = {
        #NotFoundError : Text;
        #Unauthorized : Text;
        #InvalidStatus : Text;
        #TransferError : { token : Text; msg : Text };
        #InsufficientFunds : { token : Text; balance : Nat; fee : Nat };
    };

    /// The shop's public profile. Fields are `var` so `updateShopDetails` can change them in place.
    public type ShopProfile = {
        /// A merchant-defined name shown on storefronts and marketplaces.
        var name : Text;
        /// A merchant-defined description shown on storefronts and marketplaces. Can be empty.
        var description : Text;
        /// URL for the merchant's logo image. Optional.
        var logoUrl : ?Text;
        /// URL for a banner image. Optional.
        var bannerImageUrl : ?Text;
        /// Location of the shop. Always synced to the product index canister for future indexing.
        var physicalLocation : ?ShopLocation;
        /// When false, the location is hidden from storefront and marketplace UIs (but still used for indexing).
        var showPhysicalLocation : Bool;
    };

    /// The storefront theme and its settings record, defined with their contrast check (BRE-171).
    public type ThemeColor = ShopThemes.ThemeColor;
    public type TextTone = ShopThemes.TextTone;
    public type ShopTheme = ShopThemes.ShopTheme;
    /// The storefront settings and its block layouts (BRE-172).
    public type StorefrontSettings = StorefrontLayouts.StorefrontSettings;

    /// Storefront or artist page, the artist preset and the artist profile (BRE-197).
    public type Presentation = ShopPresentation.Presentation;
    public type PresentationSettings = ShopPresentation.Settings;

    /// The media (vault) canister, used for product images and digital goods, and the HMAC secret shared
    /// with it so it can verify delivery tickets offline (see docs/digital-orders.md).
    public type MediaSettings = {
        var mediaCanisterId : ?Principal;
        var hmacSecretKey : Blob;
        var hmacSecretKeyVersion : Nat8;
    };

    /// Card payments through Stripe Checkout (BRE-123). The key is a restricted key (`rk_…`) limited
    /// to Checkout Sessions; it is never returned by any method.
    public type StripeSettings = {
        var restrictedKey : ?Text;
    };

    public type OrderRefund = {
        token : Text;
        amount : Nat;
        blockIndex : Nat;
    };

    public type RefundDestination = { owner : Principal; subaccount : ?Blob };

    public type RefundError = {
        #TransferError : Text;
        #NothingToReclaim : Text;
    };

    public type DigitalDeliveryResponse = {
        token : Text;
        expiresAt : Nat64;
        mediaKey : Text;
    };
};
