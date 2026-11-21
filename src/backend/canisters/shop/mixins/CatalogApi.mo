import Array "mo:base/Array";
import { type Result } "mo:core/Result";
import List "mo:core/List";
import Int32 "mo:base/Int32";
import Nat32 "mo:core/Nat32";
import Map "mo:map/Map";

import Logger "../../../lib/Logger";
import Pagination "../../../lib/Pagination";
import AdminAccess "../lib/admin_access";
import AuthService "../lib/auth";
import ShopPermissions "../lib/permissions";
import Music "../lib/music";
import PubSubService "../lib/pubsub";
import ProductService "../lib/products";
import {
    type Product;
    type CatalogProduct;
    type CatalogVariant;
    type ProductVariant;
    type ProductAttributeConfig;
    type ProductId;
    type VariantId;
    type InventoryEntry;
    type ProductWithInventory;
    type InventoryItem;
    type UpdateInventoryRequest;
} "../types";

/// Products, variants, attribute configs, categories and inventory.
mixin (
    products : Map.Map<ProductId, Product>,
    productVariants : Map.Map<VariantId, ProductVariant>,
    inventory : Map.Map<VariantId, InventoryEntry>,
    music : Music.Library,
    productService : ProductService.ProductService,
    authService : AuthService.AuthService,
    pubSubService : PubSubService.PubSubService,
    // Whether an order awaiting payment holds a variant (`OrdersApi`, BRE-185).
    unpaidOrderHolds : VariantId -> Bool,
    logger : Logger.BoundLogger,
) {
    /// Returns the product `id` with per-variant stock and stock status, or `null` if missing.
    public query func getProduct(id : ProductId) : async ?ProductWithInventory {
        return ProductService.getProduct(productService, id);
    };

    /// Product records (catalog view without merged inventory fields), each variant with the release it
    /// sells, a page at a time in ID order (see `lib/Pagination`: pass `next` back as `after`).
    public query func getProducts(after : ?ProductId, limit : ?Nat) : async Pagination.Page<CatalogProduct, ProductId> {
        Pagination.page(Map.toArray(products), func((id, _) : (ProductId, Product)) : ProductId = id, Nat32.compare, after, limit) |> Pagination.map(_, func((_, p) : (ProductId, Product)) : CatalogProduct = catalogProduct(p));
    };

    private func catalogProduct(p : Product) : CatalogProduct {
        {
            p with variants = Array.map<ProductVariant, CatalogVariant>(p.variants, func(v) = { v with release = Music.marketplaceRelease(music, v.deliverable) })
        };
    };

    /// Creates a product from `input`, assigns IDs and inventory rows, and rejects an SKU listed twice or already used. Owner or Admin.
    /// If any variant is `#Active`, the product becomes `#Active` and subscribers are notified.
    public shared ({ caller }) func createProduct(
        input : ProductService.CreateProductInput
    ) : async Result<Product, { #InputError : Text; #InternalError : Text; #Unauthorized : Text }> {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.productsEdit)) {
            return #err(#Unauthorized("Insufficient role to create products"));
        };
        let product = switch (ProductService.createProduct(productService, input)) {
            case (#ok(product)) product;
            case (#err(e)) return #err(e);
        };
        logger.info("Created product " # debug_show (product.id) # " \"" # product.title # "\" (" # debug_show (product.status) # ")");
        switch (product.status) {
            case (#Active) {
                try { ignore pubSubService.notifyProductUpdated(product) } catch (e) {
                    pubSubService.logUnsent("ProductUpdated", e);
                };
            };
            case _ {};
        };
        return #ok(product);
    };

    /// Updates product `input.id` and its variants, matched by SKU: new SKUs create new variant IDs and inventory,
    /// and variants left out are removed. Rejects an SKU listed twice or used by another product. Owner or Admin.
    /// Active products trigger a product-updated notification.
    public shared ({ caller }) func updateProduct(
        input : ProductService.UpdateProductInput
    ) : async Result<Product, { #InputError : Text; #InternalError : Text; #Unauthorized : Text }> {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.productsEdit)) {
            return #err(#Unauthorized("Insufficient role to update products"));
        };
        // A digital release variant holds no stock and a physical one does, and an unpaid order
        // settles the stock it reserved by that, so its product keeps its type until it's paid or expires.
        switch (Map.get(products, Map.n32hash, input.id)) {
            case (?stored) if (stored.productType != input.productType) {
                for (variant in stored.variants.vals()) {
                    if (variant.deliverable != null and unpaidOrderHolds(variant.id)) {
                        return #err(#InputError("An order awaiting payment holds " # variant.name # ", which sells a release; change the product type once it's paid or expires"));
                    };
                };
            };
            case null {};
        };
        let product = switch (ProductService.updateProduct(productService, input)) {
            case (#ok(product)) product;
            case (#err(e)) return #err(e);
        };
        logger.info("Updated product " # debug_show (product.id) # " \"" # product.title # "\" (" # debug_show (product.status) # ")");
        switch (product.status) {
            case (#Active) {
                try { ignore pubSubService.notifyProductUpdated(product) } catch (e) {
                    pubSubService.logUnsent("ProductUpdated", e);
                };
            };
            case _ {};
        };
        return #ok(product);
    };

    /// Archives the product and every variant (`#Archived`) and notifies product-deleted listeners. Owner or Admin.
    public shared ({ caller }) func archiveProduct(
        id : ProductId
    ) : async Result<Product, { #InputError : Text; #InternalError : Text; #Unauthorized : Text }> {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.productsEdit)) {
            return #err(#Unauthorized("Insufficient role to archive products"));
        };
        let product = switch (ProductService.archiveProduct(productService, id)) {
            case (#ok(product)) product;
            case (#err(e)) return #err(e);
        };
        logger.info("Archived product " # debug_show (product.id) # " \"" # product.title # "\"");
        try { ignore pubSubService.notifyProductDeleted(product.id) } catch (e) {
            pubSubService.logUnsent("ProductDeleted", e);
        };
        return #ok(product);
    };

    /// Permanently removes the product, variants, and inventory; order history keeps line snapshots.
    public shared ({ caller }) func deleteProduct(
        id : ProductId
    ) : async Result<(), { #InputError : Text; #InternalError : Text; #Unauthorized : Text }> {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.productsEdit)) {
            return #err(#Unauthorized("Insufficient role to delete products"));
        };
        switch (ProductService.deleteProduct(productService, id)) {
            case (#ok()) {
                logger.info("Deleted product " # debug_show (id));
                try { ignore pubSubService.notifyProductDeleted(id) } catch (e) {
                    pubSubService.logUnsent("ProductDeleted", e);
                };
                return #ok;
            };
            case (#err(e)) {
                return #err(e);
            };
        };
    };

    public query func getProductAttributeConfig(
        productId : ProductId
    ) : async ?ProductAttributeConfig {
        return ProductService.getProductAttributeConfig(productService, productId);
    };

    public shared ({ caller }) func setProductAttributeConfig(
        productId : ProductId,
        config : ProductAttributeConfig,
    ) : async Result<(), { #InputError : Text; #InternalError : Text; #Unauthorized : Text }> {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.productsEdit)) {
            return #err(#Unauthorized("Insufficient role to set product attribute config"));
        };
        switch (ProductService.setProductAttributeConfig(productService, productId, config)) {
            case (#err(e)) return #err(#InputError(e));
            case (#ok) {};
        };
        logger.info("Set attribute config of product " # debug_show (productId));
        return #ok;
    };

    /// Returns distinct non-empty category strings assigned across products.
    public query func getCategories() : async [Text] {
        let categorySet = Map.new<Text, ()>();
        let categoryList = List.empty<Text>();

        Map.forEach<ProductId, Product>(
            products,
            func(_productId, product) {
                switch (product.category) {
                    case null {};
                    case (?category) {
                        if (category != "") {
                            let existing = Map.get(categorySet, Map.thash, category);
                            switch (existing) {
                                case null {
                                    let _ = Map.put(categorySet, Map.thash, category, ());
                                    List.add(categoryList, category);
                                };
                                case (_) {};
                            };
                        };
                    };
                };
            },
        );

        return List.toArray(categoryList);
    };

    /// Owner or Admin: one row per inventory entry with variant/product labels, available qty, and stock
    /// status, a page at a time in variant ID order. Other callers get an empty page (BRE-105).
    public query ({ caller }) func getInventory(after : ?VariantId, limit : ?Nat) : async Pagination.Page<InventoryItem, VariantId> {
        if (not AdminAccess.canViewInventory(authService, caller)) {
            return { items = []; next = null };
        };
        let list = List.empty<InventoryItem>();

        Map.forEach<VariantId, InventoryEntry>(
            inventory,
            func(variantId, entry) {
                let variant = switch (Map.get(productVariants, Map.n32hash, variantId)) {
                    case (?v) v;
                    case null { return };
                };
                let product = switch (Map.get(products, Map.n32hash, entry.productId)) {
                    case (?p) p;
                    case null { return };
                };
                List.add(
                    list,
                    {
                        variant = {
                            id = variant.id;
                            sku = variant.sku;
                            name = variant.name;
                        };
                        product = { id = product.id; title = product.title };
                        stock = entry.stock;
                        reserved = entry.reserved;
                        available = entry.stock - entry.reserved;
                        lowStockThreshold = entry.lowStockThreshold;
                        status = if (entry.stock == 0) {
                            #OutOfStock;
                        } else if (entry.stock < entry.lowStockThreshold) {
                            #LowStock;
                        } else {
                            #InStock;
                        };
                    },
                );
            },
        );

        Pagination.page(List.toArray(list), func(item : InventoryItem) : VariantId = item.variant.id, Nat32.compare, after, limit);
    };

    /// Applies `stockDelta` and `reservedDelta` to `input.variantId`, optionally updates low-stock threshold. Owner or Admin.
    public shared ({ caller }) func updateInventory(
        input : UpdateInventoryRequest
    ) : async Result<InventoryItem, { #InputError : Text; #NotFoundError : Text; #Unauthorized : Text }> {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.inventoryEdit)) {
            return #err(#Unauthorized("Insufficient role to update inventory"));
        };
        let { variantId; stockDelta; reservedDelta; lowStockThreshold } = input;
        let existingEntry = Map.get(inventory, Map.n32hash, variantId);
        let entry = switch (existingEntry) {
            case (?e) e;
            case null {
                return #err(#InputError("Inventory entry for variant ID " # debug_show (variantId) # " does not exist"));
            };
        };

        let newStock = Int32.fromNat32(entry.stock) + stockDelta;
        let newReserved = Int32.fromNat32(entry.reserved) + reservedDelta;
        let newLowStockThreshold = switch (lowStockThreshold) {
            case null { entry.lowStockThreshold };
            case (?threshold) threshold;
        };

        if (newStock < 0 or newReserved < 0 or newReserved > newStock) {
            return #err(#InputError("Invalid stock or reserved quantity update"));
        };

        let _ = Map.put(
            inventory,
            Map.n32hash,
            variantId,
            {
                productId = entry.productId;
                variantId = variantId;
                stock = Int32.toNat32(newStock);
                reserved = Int32.toNat32(newReserved);
                lowStockThreshold = newLowStockThreshold;
            },
        );

        logger.info(
            "Updated inventory of variant " # debug_show (variantId) # " (product " # debug_show (entry.productId) # "): stock " # debug_show (entry.stock) # " -> " # debug_show (newStock) # ", reserved " # debug_show (entry.reserved) # " -> " # debug_show (newReserved)
        );

        let variant = switch (Map.get(productVariants, Map.n32hash, variantId)) {
            case (?v) v;
            case null {
                return #err(#NotFoundError("Product variant for variant ID " # debug_show (variantId) # " not found"));
            };
        };
        let product = switch (Map.get(products, Map.n32hash, entry.productId)) {
            case (?p) p;
            case null {
                return #err(#NotFoundError("Product for variant ID " # debug_show (variantId) # " not found"));
            };
        };

        let inventoryItem : InventoryItem = {
            variant = {
                id = variant.id;
                sku = variant.sku;
                name = variant.name;
            };
            product = { id = product.id; title = product.title };
            stock = Int32.toNat32(newStock);
            reserved = Int32.toNat32(newReserved);
            available = Int32.toNat32(newStock - newReserved);
            lowStockThreshold = newLowStockThreshold;
            status = if (Int32.toNat32(newStock) == 0) {
                #OutOfStock;
            } else if (Int32.toNat32(newStock) < newLowStockThreshold) {
                #LowStock;
            } else {
                #InStock;
            };
        };

        return #ok(inventoryItem);
    };
};
