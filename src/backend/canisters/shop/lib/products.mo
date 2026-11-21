import { type Result } "mo:core/Result";
import Array "mo:core/Array";
import Nat32 "mo:core/Nat32";
import Time "mo:core/Time";
import Map "mo:map/Map";

import Stock "stock";
import VariantSkus "variant_skus";
import VariantAttributes "variant_attributes";

import {
    type ProductVariant;
    type ProductId;
    type VariantId;
    type SKU;
    type PriceContext;
    type ProductType;
    type ProductAttribute;
    type ProductAttributeConfig;
    type ProductStatus;
    type Product;
    type InventoryEntry;
    type ProductWithInventory;
    type ProductVariantWithInventory;
    type Pricing;
    type Deliverable;
} "../types";

module ProductService {
    /// A variant in `createProduct`/`updateProduct`. `attributes` (e.g. Color = Black, Size = M) let the
    /// product page offer one picker per attribute; null means none on create and the stored ones on update.
    public type VariantInput = {
        status : ProductStatus;
        name : Text;
        sku : SKU;
        price : PriceContext;
        imageUrls : [Text];
        attributes : ?[ProductAttribute];
        /// `#minimum` for name-your-price (BRE-184). Null means `#fixed` on create and the stored value
        /// on update. The release a variant sells is set with `setVariantDeliverable`.
        pricing : ?Pricing;
    };

    public type CreateProductInput = {
        title : Text;
        description : Text;
        variants : [VariantInput];
        productType : ProductType;
        tags : ?[Text];
        category : ?Text;
    };
    public type CreateProductError = {
        #InputError : Text;
        #InternalError : Text;
    };

    public type UpdateProductInput = {
        id : ProductId;
        productType : ProductType;
        title : Text;
        description : Text;
        variants : [VariantInput];
        tags : ?[Text];
        category : ?Text;
    };
    public type UpdateProductError = {
        #InputError : Text;
        #InternalError : Text;
    };

    public type State = {
        products : Map.Map<ProductId, Product>;
        productVariants : Map.Map<VariantId, ProductVariant>;
        productVariantsBySKU : Map.Map<SKU, VariantId>;
        productAttributeConfigs : Map.Map<ProductId, ProductAttributeConfig>;
        inventory : Map.Map<VariantId, InventoryEntry>;
        getNextProductId : () -> ProductId;
        getNextVariantId : () -> VariantId;
    };

    public class ProductService(state : State) {
        public let products = state.products;
        public let productVariants = state.productVariants;
        public let productVariantsBySKU = state.productVariantsBySKU;
        public let productAttributeConfigs = state.productAttributeConfigs;
        public let inventory = state.inventory;
        public let getNextProductId = state.getNextProductId;
        public let getNextVariantId = state.getNextVariantId;
    };

    /// Whether a variant never runs out: a digital product's variant that sells a release (BRE-185).
    /// Its order lines neither reserve nor use up stock. A physical product that comes with a release
    /// (a record with its download) still counts its units.
    public func sellsWithoutStock(productType : ProductType, variant : ProductVariant) : Bool {
        productType == #Digital and variant.deliverable != null;
    };

    /// Returns the product `id` with each variant's available stock (stock minus units unpaid orders
    /// reserve) and stock status, or `null` if missing.
    public func getProduct(productService : ProductService, id : ProductId) : ?ProductWithInventory {
        let product = switch (Map.get(productService.products, Map.n32hash, id)) {
            case (?p) p;
            case null { return null };
        };

        let variantsWithInventory = Array.map<ProductVariant, ProductVariantWithInventory>(
            product.variants,
            func(variant) : ProductVariantWithInventory {
                let inventoryEntry = switch (Map.get(productService.inventory, Map.n32hash, variant.id)) {
                    case (?entry) entry;
                    case null {
                        {
                            productId = variant.productId;
                            variantId = variant.id;
                            stock : Nat32 = 0;
                            reserved : Nat32 = 0;
                            lowStockThreshold : Nat32 = 10;
                        };
                    };
                };
                // Buyers see what's left to order: units held by unpaid orders aren't for sale (BRE-167).
                let available = Stock.available(inventoryEntry);
                let stockStatus = if (sellsWithoutStock(product.productType, variant)) {
                    #InStock;
                } else if (available == 0) {
                    #OutOfStock;
                } else if (available < inventoryEntry.lowStockThreshold) {
                    #LowStock;
                } else {
                    #InStock;
                };
                return {
                    id = variant.id;
                    productId = variant.productId;
                    name = variant.name;
                    sku = variant.sku;
                    price = variant.price;
                    status = variant.status;
                    attributes = variant.attributes;
                    imageUrls = variant.imageUrls;
                    deliverable = variant.deliverable;
                    pricing = variant.pricing;
                    stock = available;
                    stockStatus = stockStatus;
                };
            },
        );

        return ?{
            id = product.id;
            title = product.title;
            description = product.description;
            status = product.status;
            variants = variantsWithInventory;
            tags = product.tags;
            category = product.category;
            productType = product.productType;
        };
    };

    /// Creates a product from `input` with new IDs and empty inventory rows, rejecting duplicate SKUs.
    /// The product is `#Active` when any variant is. The caller checks roles and notifies subscribers.
    public func createProduct(
        productService : ProductService,
        input : CreateProductInput,
    ) : Result<Product, CreateProductError> {
        var status : ProductStatus = #Draft;

        switch (VariantSkus.checkNoDuplicates(Array.map<VariantInput, SKU>(input.variants, func(v) = v.sku))) {
            case (#err(e)) return #err(#InputError(e));
            case (#ok) {};
        };

        let attributes = Array.map<VariantInput, [ProductAttribute]>(
            input.variants,
            func(v) = switch (v.attributes) { case (?a) a; case null [] },
        );
        switch (validateAttributes(input.variants, attributes)) {
            case (#err(e)) return #err(#InputError(e));
            case (#ok) {};
        };

        for (variant in Array.values(input.variants)) {
            let existingVariant = Map.get(
                productService.productVariantsBySKU,
                Map.thash,
                variant.sku,
            );
            if (existingVariant != null) {
                return #err(#InputError("SKU " # variant.sku # " already exists"));
            };

            if (variant.status == #Active) {
                status := #Active;
            };
        };

        let id = productService.getNextProductId();
        switch (Map.get(productService.products, Map.n32hash, id)) {
            case (null) {};
            case (_) {
                return #err(#InternalError("Product with ID " # Nat32.toText(id) # " already exists"));
            };
        };

        let product : Product = {
            id;
            title = input.title;
            description = input.description;
            status;
            productType = input.productType;
            tags = switch (input.tags) {
                case null { [] };
                case (?t) t;
            };
            category = input.category;
            createdAt = Time.now();
            variants = Array.tabulate(
                input.variants.size(),
                func(i) : ProductVariant {
                    let variantInput = input.variants[i];
                    let variantId = productService.getNextVariantId();
                    let variant : ProductVariant = {
                        id = variantId;
                        productId = id;
                        name = variantInput.name;
                        sku = variantInput.sku;
                        price = variantInput.price;
                        status = variantInput.status;
                        attributes = attributes[i];
                        imageUrls = variantInput.imageUrls;
                        deliverable = null;
                        pricing = switch (variantInput.pricing) {
                            case (?p) ?p;
                            case null ?#fixed;
                        };
                    };
                    let _ = Map.put(
                        productService.productVariants,
                        Map.n32hash,
                        variantId,
                        variant,
                    );
                    let _ = Map.put(
                        productService.productVariantsBySKU,
                        Map.thash,
                        variant.sku,
                        variantId,
                    );
                    putEmptyInventory(productService, id, variantId);
                    return variant;
                },
            );
        };

        let _ = Map.put(productService.products, Map.n32hash, id, product);
        return #ok(product);
    };

    /// Replaces product `input.id`'s fields and variants. Variants are matched by SKU: a known SKU keeps
    /// its variant (and stock), a new one gets a new variant and inventory row, and variants left out are
    /// removed. Rejects an SKU listed twice or used by another product. The caller checks roles.
    public func updateProduct(
        productService : ProductService,
        input : UpdateProductInput,
    ) : Result<Product, UpdateProductError> {
        let existingProduct = Map.get(productService.products, Map.n32hash, input.id);
        let product = switch (existingProduct) {
            case (?p) p;
            case null {
                return #err(#InputError("Product with ID " # Nat32.toText(input.id) # " does not exist"));
            };
        };
        var status : ProductStatus = product.status;

        let plan = switch (
            VariantSkus.planUpdate(
                product.id,
                Array.map<ProductVariant, VariantId>(product.variants, func(v) = v.id),
                Array.map<VariantInput, SKU>(input.variants, func(v) = v.sku),
                func(sku) = storedVariant(productService, sku),
            )
        ) {
            case (#ok(plan)) plan;
            case (#err(e)) return #err(#InputError(e));
        };

        let attributes = Array.map<VariantInput, [ProductAttribute]>(
            input.variants,
            func(v) = switch (v.attributes) {
                case (?a) a;
                case null storedAttributes(productService, input.id, v.sku);
            },
        );
        switch (validateAttributes(input.variants, attributes)) {
            case (#err(e)) return #err(#InputError(e));
            case (#ok) {};
        };

        for (variant in Array.values(input.variants)) {
            if (variant.status == #Active) {
                status := #Active;
            };
        };

        let updatedProduct : Product = {
            id = product.id;
            title = input.title;
            description = input.description;
            status = status;
            productType = input.productType;
            tags = switch (input.tags) {
                case null { product.tags };
                case (?t) t;
            };
            category = switch (input.category) {
                case null { product.category };
                case (?c) ?c;
            };
            createdAt = product.createdAt;
            variants = Array.tabulate(
                input.variants.size(),
                func(i) : ProductVariant {
                    let variantInput = input.variants[i];
                    let variantId = switch (plan.variantIds[i]) {
                        case (?vid) vid;
                        case null {
                            let vid = productService.getNextVariantId();
                            putEmptyInventory(productService, input.id, vid);
                            vid;
                        };
                    };
                    let stored = Map.get(productService.productVariants, Map.n32hash, variantId);
                    let variant : ProductVariant = {
                        id = variantId;
                        status = variantInput.status;
                        name = variantInput.name;
                        sku = variantInput.sku;
                        price = variantInput.price;
                        imageUrls = variantInput.imageUrls;
                        attributes = attributes[i];
                        productId = input.id;
                        deliverable = switch (stored) {
                            case (?v) v.deliverable;
                            case null null;
                        };
                        pricing = switch (variantInput.pricing, stored) {
                            case (?p, _) ?p;
                            case (null, ?v) v.pricing;
                            case (null, null) ?#fixed;
                        };
                    };
                    let _ = Map.put(productService.productVariants, Map.n32hash, variantId, variant);
                    let _ = Map.put(productService.productVariantsBySKU, Map.thash, variant.sku, variantId);
                    variant;
                },
            );
        };

        for (variantId in plan.removed.values()) {
            removeVariant(productService, variantId);
        };
        let _ = Map.put(productService.products, Map.n32hash, input.id, updatedProduct);

        return #ok(updatedProduct);
    };

    /// Sets what variant `variantId` delivers from the music library, in both the variant index and its
    /// product. The caller checks roles and that the release may be linked. Returns the previous value.
    public func setVariantDeliverable(productService : ProductService, variantId : VariantId, deliverable : ?Deliverable) : Result<?Deliverable, Text> {
        let ?variant = Map.get(productService.productVariants, Map.n32hash, variantId) else return #err("Variant " # Nat32.toText(variantId) # " not found");
        let ?product = Map.get(productService.products, Map.n32hash, variant.productId) else return #err("Product " # Nat32.toText(variant.productId) # " not found");
        let updated = { variant with deliverable };
        Map.set(productService.productVariants, Map.n32hash, variantId, updated);
        Map.set(
            productService.products,
            Map.n32hash,
            product.id,
            {
                product with variants = Array.map<ProductVariant, ProductVariant>(product.variants, func(v) = if (v.id == variantId) updated else v)
            },
        );
        #ok(variant.deliverable);
    };

    /// The variant `sku` is indexed to, or `null` for a free SKU (including a stale index entry).
    func storedVariant(productService : ProductService, sku : SKU) : ?VariantSkus.StoredVariant {
        let ?variantId = Map.get(productService.productVariantsBySKU, Map.thash, sku) else return null;
        let ?variant = Map.get(productService.productVariants, Map.n32hash, variantId) else return null;
        ?{ id = variant.id; productId = variant.productId };
    };

    func putEmptyInventory(productService : ProductService, productId : ProductId, variantId : VariantId) {
        let entry : InventoryEntry = {
            productId;
            variantId;
            stock = 0;
            reserved = 0;
            lowStockThreshold = 10;
        };
        let _ = Map.put(productService.inventory, Map.n32hash, variantId, entry);
    };

    /// Removes a variant with its SKU index entry and inventory row. Its digital asset key stays:
    /// buyers of past orders still download through it, and variant IDs are never reused.
    func removeVariant(productService : ProductService, variantId : VariantId) {
        let ?variant = Map.remove(productService.productVariants, Map.n32hash, variantId) else return;
        if (Map.get(productService.productVariantsBySKU, Map.thash, variant.sku) == ?variantId) {
            let _ = Map.remove(productService.productVariantsBySKU, Map.thash, variant.sku);
        };
        let _ = Map.remove(productService.inventory, Map.n32hash, variantId);
    };

    func validateAttributes(variants : [VariantInput], attributes : [[ProductAttribute]]) : Result<(), Text> {
        VariantAttributes.validateProduct(
            Array.tabulate<{ name : Text; attributes : [ProductAttribute] }>(
                variants.size(),
                func(i) = {
                    name = variants[i].name;
                    attributes = attributes[i];
                },
            )
        );
    };

    /// The attributes stored on product `productId`'s variant with SKU `sku`, or none for a new SKU.
    func storedAttributes(productService : ProductService, productId : ProductId, sku : SKU) : [ProductAttribute] {
        let ?variantId = Map.get(productService.productVariantsBySKU, Map.thash, sku) else return [];
        switch (Map.get(productService.productVariants, Map.n32hash, variantId)) {
            case (?variant) if (variant.productId == productId) variant.attributes else [];
            case null [];
        };
    };

    public func archiveProduct(
        productService : ProductService,
        id : ProductId,
    ) : Result<Product, { #InputError : Text; #InternalError : Text }> {
        let existingProduct = Map.get(productService.products, Map.n32hash, id);
        let product = switch (existingProduct) {
            case (?p) p;
            case null {
                return #err(#InputError("Product with ID " # Nat32.toText(id) # " does not exist"));
            };
        };
        let archivedVariants = Array.map<ProductVariant, ProductVariant>(
            product.variants,
            func(v : ProductVariant) : ProductVariant {
                { v with status = #Archived };
            },
        );
        let updatedProduct : Product = {
            product with status = #Archived;
            variants = archivedVariants;
        };
        for (v in archivedVariants.vals()) {
            let _ = Map.put(productService.productVariants, Map.n32hash, v.id, v);
            let _ = Map.put(productService.productVariantsBySKU, Map.thash, v.sku, v.id);
        };
        let _ = Map.put(productService.products, Map.n32hash, id, updatedProduct);

        return #ok(updatedProduct);
    };

    public func deleteProduct(
        productService : ProductService,
        id : ProductId,
    ) : Result<(), { #InputError : Text }> {
        let existingProduct = Map.get(productService.products, Map.n32hash, id);
        let product = switch (existingProduct) {
            case (?p) p;
            case null {
                return #err(#InputError("Product with ID " # Nat32.toText(id) # " does not exist"));
            };
        };
        for (v in product.variants.vals()) {
            let _ = Map.remove(productService.productVariants, Map.n32hash, v.id);
            let _ = Map.remove(productService.productVariantsBySKU, Map.thash, v.sku);
            let _ = Map.remove(productService.inventory, Map.n32hash, v.id);
        };
        let _ = Map.remove(productService.products, Map.n32hash, id);
        let _ = Map.remove(productService.productAttributeConfigs, Map.n32hash, id);
        return #ok;
    };

    public func getProductAttributeConfig(
        productService : ProductService,
        productId : ProductId,
    ) : ?ProductAttributeConfig {
        Map.get(productService.productAttributeConfigs, Map.n32hash, productId);
    };

    public func setProductAttributeConfig(
        productService : ProductService,
        productId : ProductId,
        config : ProductAttributeConfig,
    ) : Result<(), Text> {
        if (not Map.has(productService.products, Map.n32hash, productId)) {
            return #err("Product with ID " # Nat32.toText(productId) # " does not exist");
        };
        switch (VariantAttributes.validateConfig(config)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        let _ = Map.put(productService.productAttributeConfigs, Map.n32hash, productId, config);
        #ok;
    };
};
