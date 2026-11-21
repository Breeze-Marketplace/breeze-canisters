import Map "mo:map/Map";
import Time "mo:core/Time";

// Adds `createdAt` to every product (BRE-128). Products made before this have no record of when, so
// they get the upgrade time; the storefront breaks ties by product ID, which only goes up.
module {
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

    type ProductStatus = { #Draft; #Active; #Inactive; #Archived };

    type ProductType = { #Physical; #Digital; #Service };

    type ProductVariant = {
        id : VariantId;
        productId : ProductId;
        name : Text;
        sku : Text;
        price : { catalog : [Money] };
        status : ProductStatus;
        attributes : [{ key : Text; value : Text }];
        imageUrls : [Text];
    };

    type OldProduct = {
        id : ProductId;
        title : Text;
        description : Text;
        status : ProductStatus;
        productType : ProductType;
        tags : [Text];
        category : ?Text;
        variants : [ProductVariant];
    };

    type NewProduct = OldProduct and { createdAt : Int };

    public func migration(old : { products : Map.Map<ProductId, OldProduct> }) : {
        products : Map.Map<ProductId, NewProduct>;
    } {
        let upgradedAt = Time.now();
        {
            products = Map.map<ProductId, OldProduct, NewProduct>(
                old.products,
                Map.n32hash,
                func(_, product) = { product with createdAt = upgradedAt },
            );
        };
    };
};
