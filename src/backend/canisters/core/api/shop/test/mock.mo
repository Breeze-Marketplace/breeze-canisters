import List "mo:core/List";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import ShopInterface "../../../../../interfaces/shop";
import ShopAPI "../lib";

module {
    public type SyncShopProductBatchCall = {
        shopId : Principal;
        products : [ShopAPI.MarketplaceProductListing];
    };

    public type PruneShopProductsCall = {
        shopId : Principal;
        keep : [ShopInterface.ProductId];
    };

    public type SyncUpdatedProductCall = {
        shopId : Principal;
        product : ShopAPI.MarketplaceProductListing;
    };

    public type SyncDeletedProductsCall = {
        shopId : Principal;
        productIds : [ShopInterface.ProductId];
    };

    public func mockProductIndex(
        implementation : ?{
            syncShopProductBatch : ?((shopId : Principal, products : [ShopAPI.MarketplaceProductListing]) -> async Result<(), Text>);
            pruneShopProducts : ?((shopId : Principal, keep : [ShopInterface.ProductId]) -> async Result<Nat, Text>);
            syncUpdatedProduct : ?((shopId : Principal, product : ShopAPI.MarketplaceProductListing) -> async Result<(), Text>);
            syncDeletedProducts : ?((shopId : Principal, productIds : [ShopInterface.ProductId]) -> async Result<(), Text>);
        }
    ) : {
        productIndex : ShopAPI.ProductIndexInterface;
        syncShopProductBatchCalls : List.List<SyncShopProductBatchCall>;
        pruneShopProductsCalls : List.List<PruneShopProductsCall>;
        syncUpdatedProductCalls : List.List<SyncUpdatedProductCall>;
        syncDeletedProductsCalls : List.List<SyncDeletedProductsCall>;
    } {
        let syncShopProductBatchCalls = List.empty<SyncShopProductBatchCall>();
        let pruneShopProductsCalls = List.empty<PruneShopProductsCall>();
        let syncUpdatedProductCalls = List.empty<SyncUpdatedProductCall>();
        let syncDeletedProductsCalls = List.empty<SyncDeletedProductsCall>();

        let productIndex : ShopAPI.ProductIndexInterface = {
            syncShopProductBatch = func(shopId : Principal, products : [ShopAPI.MarketplaceProductListing]) : async Result<(), Text> {
                List.add(syncShopProductBatchCalls, { shopId; products });
                switch (implementation) {
                    case (?impl) {
                        switch (impl.syncShopProductBatch) {
                            case (?fn) { await fn(shopId, products) };
                            case (null) { #ok(()) };
                        };
                    };
                    case (null) { #ok(()) };
                };
            };
            pruneShopProducts = func(shopId : Principal, keep : [ShopInterface.ProductId]) : async Result<Nat, Text> {
                List.add(pruneShopProductsCalls, { shopId; keep });
                switch (implementation) {
                    case (?impl) {
                        switch (impl.pruneShopProducts) {
                            case (?fn) { await fn(shopId, keep) };
                            case (null) { #ok(0) };
                        };
                    };
                    case (null) { #ok(0) };
                };
            };
            syncUpdatedProduct = func(shopId : Principal, product : ShopAPI.MarketplaceProductListing) : async Result<(), Text> {
                List.add(syncUpdatedProductCalls, { shopId; product });
                switch (implementation) {
                    case (?impl) {
                        switch (impl.syncUpdatedProduct) {
                            case (?fn) { await fn(shopId, product) };
                            case (null) { #ok(()) };
                        };
                    };
                    case (null) { #ok(()) };
                };
            };
            syncDeletedProducts = func(shopId : Principal, productIds : [ShopInterface.ProductId]) : async Result<(), Text> {
                List.add(syncDeletedProductsCalls, { shopId; productIds });
                switch (implementation) {
                    case (?impl) {
                        switch (impl.syncDeletedProducts) {
                            case (?fn) { await fn(shopId, productIds) };
                            case (null) { #ok(()) };
                        };
                    };
                    case (null) { #ok(()) };
                };
            };
        };

        {
            productIndex;
            syncShopProductBatchCalls;
            pruneShopProductsCalls;
            syncUpdatedProductCalls;
            syncDeletedProductsCalls;
        };
    };
};
