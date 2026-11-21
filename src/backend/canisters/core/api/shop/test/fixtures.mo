import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Text "mo:core/Text";
import Time "mo:core/Time";

import CoreMap "mo:core/Map";
import CoreSet "mo:core/Set";
import Map "mo:map/Map";

import ShopProvisioning "../../../provisioning/shop";
import MockLogger "../../../../../lib/Logger/mock";
import WasmVersion "../../../../../lib/WasmVersion";
import ShopInterface "../../../../../interfaces/shop";
import Management "../../../../../interfaces/management";

import { type ReleaseCanisterDependencies } "../../canister_management";
import ShopAPI "../lib";
import Slug "../slug";
import { mockProductIndex } "./mock";

module {
    public let defaultCreateShopRequest : ShopAPI.CreateShopRequest = {
        name = "Test Shop";
        description = "Test Description";
        slug = "test-shop";
    };

    func defaultPrincipal() : Principal {
        Principal.fromText("aaaaa-aa");
    };

    public func shopRegistryItem(
        canisterId : Principal,
        name : Text,
        description : Text,
        logoUrl : ?Text,
        physicalLocation : ?ShopInterface.ShopLocation,
        locationPublic : Bool,
    ) : ShopAPI.ShopRegistryItem {
        {
            canisterId;
            slug = Slug.fromName(name);
            owner = defaultPrincipal();
            shopDetails = {
                name;
                description;
                logoUrl;
                bannerImageUrl = null;
                physicalLocation;
                locationPublic;
            };
            registeredBy = defaultPrincipal();
            registrationDate = Time.now();
            presentation = #storefront;
        };
    };

    public func sortShopsByCanisterId(shops : [ShopAPI.PublicShopInfo]) : [ShopAPI.PublicShopInfo] {
        Array.sort(
            shops,
            func(a : ShopAPI.PublicShopInfo, b : ShopAPI.PublicShopInfo) : {
                #less;
                #equal;
                #greater;
            } {
                switch (Text.compare(Principal.toText(a.canisterId), Principal.toText(b.canisterId))) {
                    case (#less) { #less };
                    case (#equal) { #equal };
                    case (#greater) { #greater };
                };
            },
        );
    };

    public func makeDependencies(shopRegistry : ?Map.Map<Principal, ShopAPI.ShopRegistryItem>) : ShopAPI.Dependencies {
        let registry = switch (shopRegistry) {
            case (?value) { value };
            case (null) { Map.new<Principal, ShopAPI.ShopRegistryItem>() };
        };

        let shopRegistryByOwner = Map.new<Principal, Principal>();
        let shopRegistryByName = Map.new<Text, Principal>();
        let shopIdsOrdered = CoreSet.empty<Principal>();
        let shopsByDisplayName = CoreSet.empty<ShopAPI.ShopNameKey>();
        let artistShops = CoreSet.empty<Principal>();
        let hiddenShops = CoreSet.empty<Principal>();
        let managedShopsByUser = Map.new<Principal, [Principal]>();
        let mockedProductIndex = mockProductIndex(null);
        let slugs : ShopAPI.SlugState = {
            bySlug = CoreMap.empty<Text, Principal>();
            byShop = CoreMap.empty<Principal, [Text]>();
        };

        for (item in Map.vals(registry)) {
            let normalizedName = ShopAPI.normalizeShopName(item.shopDetails.name);
            let _ = Map.put(shopRegistryByOwner, Map.phash, item.owner, item.canisterId);
            let _ = Map.put(shopRegistryByName, Map.thash, normalizedName, item.canisterId);
            CoreSet.add(shopIdsOrdered, Principal.compare, item.canisterId);
            CoreSet.add(shopsByDisplayName, ShopAPI.compareShopNameKey, { name = item.shopDetails.name; canisterId = item.canisterId });
            if (item.presentation == #artist) CoreSet.add(artistShops, Principal.compare, item.canisterId);
            slugs.bySlug.add(Text.compare, item.slug, item.canisterId);
            slugs.byShop.add(Principal.compare, item.canisterId, [item.slug]);
        };

        {
            shopRegistry = registry;
            shopRegistryByOwner;
            shopRegistryByName;
            shopIdsOrdered;
            shopsByDisplayName;
            artistShops;
            hiddenShops;
            hiddenShopsCopy = { var complete = true };
            managedShopsByUser;
            slugs;
            slugReservedByQuote = func(_ : Text) : Bool { false };
            ShopService = {
                createShop = func(
                    _ : Principal,
                    _ : Blob,
                    _ : {
                        canisterId : Principal;
                        isNewCanister : Bool;
                    },
                    _ : {
                        controllers : [Principal];
                        details : {
                            name : Text;
                            description : Text;
                        };
                    },
                ) : async ShopProvisioning.CreateShopResponse {
                    #ok(defaultPrincipal());
                };
            };
            logger = MockLogger.bind(MockLogger.new(defaultPrincipal()));
            releaseCanister = func(_ : Principal, _ : ReleaseCanisterDependencies) : async () {};
            createMediaCanister = func(_ : Principal) : async Result<Principal, { #Unauthorized; #WasmNotFound; #InsufficientCycles : Text; #FailedToCreate : Text }> {
                #ok(defaultPrincipal());
            };
            canisterFactory = {
                getWasm = func(_ : WasmVersion.WasmName, _ : WasmVersion.Version) : async Result<{ wasm : Blob; sha256 : Blob }, { #NotFound; #Yanked }> {
                    #ok({
                        wasm = Blob.fromArray([0x00, 0x01, 0x02]);
                        sha256 = "" : Blob;
                    }); // dummy wasm
                };
                createCanister = func(_ : ?Management.CanisterSettings) : async Result<{ canisterId : Principal; isNewCanister : Bool }, { #Unauthorized : Text }> {
                    #ok({
                        canisterId = defaultPrincipal();
                        isNewCanister = true;
                    });
                };
                addCanisterToPool = func(_ : Principal) : async Result<(), { #Unauthorized : Text }> {
                    #ok;
                };
            };
            productIndex = mockedProductIndex.productIndex;
        };
    };

    public func defaultRegisterShopHooks(controllers : [Principal]) : ShopAPI.RegisterShopHooks {
        {
            getShopDetails = func(_ : Principal) : async ShopAPI.ShopCanisterDetails {
                defaultShopCanisterDetails("Test Shop", "Test Description");
            };
            subscribeToShopEvents = func(_ : Principal) : async () {};
            getControllers = func(_ : Principal) : async [Principal] {
                controllers;
            };
        };
    };

    public func defaultShopCanisterDetails(
        name : Text,
        description : Text,
    ) : ShopAPI.ShopCanisterDetails {
        {
            name;
            description;
            logoUrl = null;
            bannerImageUrl = null;
            physicalLocation = null;
            showPhysicalLocation = false;
        };
    };

    /// An event as a shop older than BRE-197 sends it: no presentation.
    public func shopDetailsUpdatedEvent(
        name : Text,
        description : Text,
    ) : ShopInterface.ShopDetailsUpdatedEvent {
        shopDetailsEventWithPresentation(name, description, null);
    };

    public func shopDetailsEventWithPresentation(
        name : Text,
        description : Text,
        presentation : ?ShopInterface.ShopPresentation,
    ) : ShopInterface.ShopDetailsUpdatedEvent {
        {
            data = {
                name;
                description;
                logoUrl = "https://example.com/logo.png";
                bannerImageUrl = ?"https://example.com/banner.png";
                physicalLocation = ?#PostalCode("90210");
                locationPublic = true;
                presentation;
            };
        };
    };

    public func sampleProduct(productId : Nat32) : ShopInterface.Product {
        let usd = {
            class_ = #FiatCurrency;
            symbol = "USD";
        };
        {
            id = productId;
            title = "Sample Product";
            description = "A test product";
            status = #Active;
            variants = [
                {
                    id = 1;
                    productId;
                    name = "Default";
                    sku = "SKU-1";
                    price = {
                        catalog = [
                            {
                                currency = usd;
                                amount = 1000;
                                metadata = { decimals = 2 };
                            },
                        ];
                    };
                    status = #Active;
                    attributes = [{ key = "Color"; value = "Blue" }];
                    imageUrls = ["https://example.com/product.png"];
                    release = null;
                },
            ];
            productType = #Physical;
            tags = ["featured"];
            category = ?"Apparel";
        };
    };

    public func productUpdatedEvent(productId : Nat32) : ShopInterface.ProductUpdatedEvent {
        let product = sampleProduct(productId);
        {
            data = {
                productId = product.id;
                title = product.title;
                description = product.description;
                variants = Array.map(
                    product.variants,
                    func(v : ShopInterface.ProductVariant) : {
                        variantId : Nat32;
                        name : Text;
                        sku : Text;
                        priceCatalog : [ShopInterface.Money];
                        status : ShopInterface.ProductStatus;
                        attributes : [ShopInterface.ProductAttribute];
                        imageUrls : [Text];
                        release : ?ShopInterface.MarketplaceRelease;
                    } {
                        {
                            variantId = v.id;
                            name = v.name;
                            sku = v.sku;
                            priceCatalog = v.price.catalog;
                            status = v.status;
                            attributes = v.attributes;
                            imageUrls = v.imageUrls;
                            release = v.release;
                        };
                    },
                );
                tags = product.tags;
                category = product.category;
                productType = product.productType;
            };
        };
    };

    public func productDeletedEvent(productId : Nat32) : ShopInterface.ProductDeletedEvent {
        {
            data = {
                productId;
            };
        };
    };
};
