import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Error "mo:core/Error";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Text "mo:core/Text";
import Time "mo:core/Time";

import CoreMap "mo:core/Map";
import CoreSet "mo:core/Set";
import Map "mo:map/Map";

import ShopProvisioning "../../provisioning/shop";
import Logger "../../../../lib/Logger";
import WasmVersion "../../../../lib/WasmVersion";
import Pagination "../../../../lib/Pagination";
import Management "../../../../interfaces/management";
import ShopInterface "../../../../interfaces/shop";
import { type ShopLocation } "../../../../interfaces/shop";

import { type ReleaseCanisterFunction } "../canister_management";
import MediaAPI "../media";
import Slug "./slug";

module {
    public type ShopId = Principal;

    public type ShopDetails = {
        name : Text;
        description : Text;
        logoUrl : ?Text;
        bannerImageUrl : ?Text;
        physicalLocation : ?ShopLocation;
        locationPublic : Bool;
    };

    /// A shop by its display name, then canister ID: the order `shopsByDisplayName` keeps.
    public type ShopNameKey = { name : Text; canisterId : Principal };

    public func compareShopNameKey(a : ShopNameKey, b : ShopNameKey) : {
        #less;
        #equal;
        #greater;
    } {
        switch (Text.compare(a.name, b.name)) {
            case (#equal) { Principal.compare(a.canisterId, b.canisterId) };
            case (order) { order };
        };
    };

    public type ShopRegistryItem = {
        canisterId : Principal;
        /// The shop's current URL slug (BRE-71). Its earlier slugs still lead to it: see `SlugState`.
        slug : Text;
        owner : Principal;
        shopDetails : ShopDetails;
        registeredBy : Principal;
        registrationDate : Time.Time;
        /// Storefront or artist page, from the shop's `ShopDetailsUpdated` events (BRE-197). A new or
        /// registered shop starts as a storefront until its first event says otherwise.
        presentation : ShopInterface.ShopPresentation;
    };

    type ShopService = {
        createShop : (
            caller : Principal,
            wasm : Blob,
            canister : {
                canisterId : Principal;
                isNewCanister : Bool;
            },
            args : {
                controllers : [Principal];
                details : {
                    name : Text;
                    description : Text;
                };
            },
        ) -> async ShopProvisioning.CreateShopResponse;
    };

    type CanisterFactoryInterface = {
        getWasm : (WasmVersion.WasmName, WasmVersion.Version) -> async Result<{ wasm : Blob; sha256 : Blob }, { #NotFound; #Yanked }>;
        createCanister : (?Management.CanisterSettings) -> async Result<{ canisterId : Principal; isNewCanister : Bool }, { #Unauthorized : Text }>;
        addCanisterToPool : (Principal) -> async Result<(), { #Unauthorized : Text }>;
    };

    public type CreateShopRequest = {
        name : Text;
        description : Text;
        /// Reserved with the quote, so free and valid.
        slug : Text;
    };

    /// Every slug a shop has had (BRE-71). A slug, once given, stays with its shop for good, also
    /// after the shop changes it or is unregistered, so a link shared with an old slug never leads
    /// to a different shop. The shop's current slug is the one on its `ShopRegistryItem`.
    public type SlugState = {
        /// Slug -> the shop that has or had it.
        bySlug : CoreMap.Map<Text, Principal>;
        /// Shop -> its slugs, oldest first.
        byShop : CoreMap.Map<Principal, [Text]>;
    };

    /// Most slugs one shop can hold, its current one included: each change keeps the old slug
    /// stored for good, so changes are capped.
    public let MAX_SLUGS_PER_SHOP = 10;

    public type ShopCanisterDetails = {
        name : Text;
        description : Text;
        logoUrl : ?Text;
        bannerImageUrl : ?Text;
        physicalLocation : ?ShopLocation;
        showPhysicalLocation : Bool;
    };

    public type RegisterShopHooks = {
        getShopDetails : (canisterId : Principal) -> async ShopCanisterDetails;
        subscribeToShopEvents : (canisterId : Principal) -> async ();
        /// The canister's controllers, read from its `canister_status` (core must be a controller or
        /// status viewer of it). Throws when they can't be read.
        getControllers : (canisterId : Principal) -> async [Principal];
    };

    /// Seconds before a bounded-wait call to a shop canister (which core doesn't trust) or the
    /// management canister gives up, so a silent canister can't block core's stop or upgrade (BRE-119).
    public let REGISTER_CALL_TIMEOUT_SECONDS : Nat32 = 30;

    /// How many registered shops one user may manage through `registerShop`.
    public let MAX_REGISTERED_SHOPS_PER_USER : Nat = 20;

    /// Catalog price line (minor units); aligned with shop `Money` for search / marketplace display.
    public type CatalogMoney = {
        currency : {
            class_ : { #FiatCurrency; #Cryptocurrency };
            symbol : Text;
        };
        amount : Nat64;
        metadata : { decimals : Nat32 };
    };

    public type MarketplaceVariantStatus = {
        #Draft;
        #Active;
        #Inactive;
        #Archived;
    };

    public type MarketplaceVariantAttribute = {
        key : Text;
        value : Text;
    };

    /// One variant row for marketplace indexing (prices and options per SKU).
    public type MarketplaceVariantListing = {
        variantId : Nat32;
        name : Text;
        sku : Text;
        priceCatalog : [CatalogMoney];
        status : MarketplaceVariantStatus;
        attributes : [MarketplaceVariantAttribute];
        imageUrls : [Text];
        /// The release the variant sells, for the marketplace's Music listings (BRE-187); null otherwise.
        release : ?ShopInterface.MarketplaceRelease;
    };

    /// Snapshot of an active listing from a shop canister; used for marketplace search and browse.
    public type MarketplaceProductListing = {
        productId : Nat32;
        title : Text;
        description : Text;
        variants : [MarketplaceVariantListing];
        tags : [Text];
        category : ?Text;
        productType : ShopInterface.ProductType;
    };

    public type ProductIndexInterface = {
        syncShopProductBatch : (shopId : Principal, products : [MarketplaceProductListing]) -> async Result<(), Text>;
        pruneShopProducts : (shopId : Principal, keep : [ShopInterface.ProductId]) -> async Result<Nat, Text>;
        syncUpdatedProduct : (shopId : Principal, product : MarketplaceProductListing) -> async Result<(), Text>;
        syncDeletedProducts : (shopId : Principal, productIds : [ShopInterface.ProductId]) -> async Result<(), Text>;
    };

    public type ProductsPage = {
        items : [ShopInterface.Product];
        next : ?ShopInterface.ProductId;
    };

    public type SyncShopProductsHooks = {
        /// The shop's products after `after`, a page at a time (the shop's `getProducts`).
        getProductsPage : (shopId : Principal, after : ?ShopInterface.ProductId) -> async ProductsPage;
    };

    /// Most pages a full sync reads from one shop: 250 pages of up to 200 products is 50,000. A cap,
    /// so a shop that keeps returning `next` can't keep core calling it and product_index.
    public let MAX_SYNC_PAGES = 250;

    /// A full product sync in progress for one shop. Product events that arrive while it runs are
    /// newer than the pages it read, so it records them: it doesn't send those products again, and
    /// the final prune keeps the updated ones and drops the deleted ones.
    public type ProductSync = {
        updated : Map.Map<ShopInterface.ProductId, ()>;
        deleted : Map.Map<ShopInterface.ProductId, ()>;
    };

    public type SyncShopProductsResult = {
        /// Products the shop has, as far as this sync read.
        products : Nat;
        /// Products product_index removed because the shop no longer has them.
        removed : Nat;
        /// False when the sync stopped at `MAX_SYNC_PAGES`: products past the cap weren't sent, and
        /// nothing was removed.
        complete : Bool;
    };

    public type SyncShopProductsError = {
        #Unauthorized;
        #NotRegistered;
        /// A full sync of this shop is already running.
        #InProgress;
        #Failed : Text;
    };

    public type Dependencies = {
        shopRegistry : Map.Map<Principal, ShopRegistryItem>;
        shopRegistryByOwner : Map.Map<Principal, Principal>;
        shopRegistryByName : Map.Map<Text, Principal>;
        /// Registered shops' canister IDs, in order, so `listShops` reads a page from its cursor (BRE-96).
        shopIdsOrdered : CoreSet.Set<Principal>;
        /// Registered shops by display name, for the admin registry's pages (BRE-96).
        shopsByDisplayName : CoreSet.Set<ShopNameKey>;
        /// Registered shops shown as artist pages, in canister ID order, for `listArtistShops` (BRE-201).
        artistShops : CoreSet.Set<Principal>;
        /// Shops trust_safety has hidden from the marketplace (BRE-201). Hiding a shop doesn't change
        /// the registry: it only leaves the shop out of public discovery.
        hiddenShops : CoreSet.Set<Principal>;
        /// Whether core has once copied every hidden shop from product_index. Until then it can't
        /// tell which artist shops are hidden, so it lists none.
        hiddenShopsCopy : { var complete : Bool };
        managedShopsByUser : Map.Map<Principal, [Principal]>;
        slugs : SlugState;
        /// True if an open shop creation quote holds this slug.
        slugReservedByQuote : (slug : Text) -> Bool;
        ShopService : ShopService;
        logger : Logger.BoundLogger;
        canisterFactory : CanisterFactoryInterface;
        releaseCanister : ReleaseCanisterFunction;
        createMediaCanister : (Principal) -> async MediaAPI.CreateMediaCanisterResponse;
        productIndex : ProductIndexInterface;
    };

    public class API(dependencies : Dependencies) {
        public let {
            shopRegistry;
            shopRegistryByOwner;
            shopRegistryByName;
            shopIdsOrdered;
            shopsByDisplayName;
            artistShops;
            hiddenShops;
            hiddenShopsCopy;
            managedShopsByUser;
            slugs;
            slugReservedByQuote;
            ShopService;
            logger;
            canisterFactory;
            releaseCanister;
            createMediaCanister;
            productIndex;
        } = dependencies;

        /// Full product syncs running now, by shop. Transient: a sync doesn't outlive an upgrade,
        /// which stops core and so waits for it to finish.
        public let productSyncs = Map.new<Principal, ProductSync>();

        /// trust_safety's shop decisions numbered as they arrive, and each shop's latest, so a copy of
        /// product_index's hidden shops skips a shop decided while its page was in flight (see
        /// `copyHiddenShops`). Transient: no copy outlives an upgrade.
        public var visibilityDecisions : Nat = 0;
        public let lastVisibilityDecision = CoreMap.empty<Principal, Nat>();
    };

    /// Normalizes a shop name by converting it to lowercase and removing all whitespace. This is used to enforce uniqueness of shop names
    /// in a case-insensitive manner, while still allowing shops to have display names with capitalization and spaces.
    public func normalizeShopName(name : Text) : Text {
        Text.toLower(Text.replace(name, #char ' ', ""));
    };

    public type CreateShopError = {
        #CanisterCreationFailed : Text;
    };

    public type CreateShopResponse = Result<(item : ShopRegistryItem, mediaCanisterId : Principal), CreateShopError>;

    /// Installs the shop wasm `version` (core's current shop version, BRE-85) from canister_factory.
    public func createShop(
        api : API,
        caller : Principal,
        tempOwner : Principal,
        req : CreateShopRequest,
        version : WasmVersion.Version,
    ) : async CreateShopResponse {
        let wasm = switch (await api.canisterFactory.getWasm(#shop, version)) {
            case (#ok(w)) { w.wasm };
            case (#err(#NotFound)) {
                return #err(#CanisterCreationFailed("Shop canister WASM not found"));
            };
            case (#err(#Yanked)) {
                return #err(#CanisterCreationFailed("Shop canister WASM " # WasmVersion.toText(version) # " is yanked"));
            };
        };

        let mediaCanisterId = switch (await api.createMediaCanister(caller)) {
            case (#ok((id))) { id };
            case (#err(#Unauthorized)) {
                return #err(#CanisterCreationFailed("Unauthorized to create media canister"));
            };
            case (#err(#WasmNotFound)) {
                return #err(#CanisterCreationFailed("Media canister WASM not found"));
            };
            case (#err(#InsufficientCycles(msg))) {
                return #err(#CanisterCreationFailed("Insufficient cycles to create media canister: " # msg));
            };
            case (#err(#FailedToCreate(msg))) {
                return #err(#CanisterCreationFailed(msg));
            };
        };

        let controllers = [tempOwner];
        var canisterId = Principal.fromText("aaaaa-aa"); // placeholder until createCanister returns
        var isNewCanister = false;

        try {
            let res = await api.canisterFactory.createCanister(
                ?{
                    controllers = ?controllers;
                    compute_allocation = null;
                    memory_allocation = null;
                    freezing_threshold = null;
                }
            );
            let data = switch (res) {
                case (#ok(c)) { c };
                case (#err(#Unauthorized(_))) {
                    throw Error.reject("Unauthorized request to canister factory");
                };
            };
            canisterId := data.canisterId;
            isNewCanister := data.isNewCanister;
        } catch (e) {
            await api.releaseCanister(mediaCanisterId, { logger = api.logger; canisterFactory = api.canisterFactory });
            return #err(#CanisterCreationFailed("Failed to create shop canister: " # Error.message(e)));
        };

        // TODO: integration-test a management canister trap in install_code or update_settings, to check
        // both canisters are released (the unit tests can't make it trap).
        try {
            let result = await api.ShopService.createShop(
                tempOwner,
                wasm,
                { canisterId; isNewCanister },
                {
                    controllers;
                    details = {
                        name = req.name;
                        description = req.description;
                    };
                },
            );

            switch (result) {
                case (#err(#InsufficientCycles(msg))) {
                    await api.releaseCanister(canisterId, { logger = api.logger; canisterFactory = api.canisterFactory });
                    await api.releaseCanister(mediaCanisterId, { logger = api.logger; canisterFactory = api.canisterFactory });
                    return #err(#CanisterCreationFailed("Insufficient cycles to create shop canister: " # msg));
                };
                case (#err(#UnusableCanister(msg))) {
                    // The pooled shop canister can't be checked or topped up: keep it out of the pool.
                    await api.releaseCanister(mediaCanisterId, { logger = api.logger; canisterFactory = api.canisterFactory });
                    return #err(#CanisterCreationFailed("Pooled shop canister is unusable: " # msg));
                };
                case (#ok(_)) {};
            };
        } catch (e) {
            await api.releaseCanister(canisterId, { logger = api.logger; canisterFactory = api.canisterFactory });
            await api.releaseCanister(mediaCanisterId, { logger = api.logger; canisterFactory = api.canisterFactory });
            return #err(#CanisterCreationFailed("Failed to create shop canister: " # Error.message(e)));
        };

        let item : ShopRegistryItem = {
            canisterId;
            slug = req.slug;
            owner = caller;
            shopDetails = {
                name = req.name;
                description = req.description;
                logoUrl = null;
                bannerImageUrl = null;
                physicalLocation = null;
                locationPublic = false;
            };
            registeredBy = caller;
            registrationDate = Time.now();
            presentation = #storefront;
        };

        return #ok(item, mediaCanisterId);
    };

    public func getShopName(api : API, shopId : ShopId) : Text {
        switch (Map.get(api.shopRegistry, Map.phash, shopId)) {
            case (?shop) { shop.shopDetails.name };
            case (null) { Principal.toText(shopId) };
        };
    };

    public func isRegisteredShop(api : API, principal : Principal) : Bool {
        Map.has(api.shopRegistry, Map.phash, principal);
    };

    public type PublicShopInfo = {
        canisterId : Principal;
        /// The shop's current URL slug: link to `/shop/<slug>` (BRE-71).
        slug : Text;
        name : Text;
        description : Text;
        logoUrl : ?Text;
        physicalLocation : ?ShopLocation;
        locationPublic : Bool;
    };

    /// When `selfCanister` is null, any existing name index entry is a conflict (used when creating a new shop).
    /// When set, the name is allowed only if unindexed or still mapped to that canister (rename / detail sync).
    public func shopNameConflicts(api : API, normalizedName : Text, selfCanister : ?Principal) : Bool {
        switch (Map.get(api.shopRegistryByName, Map.thash, normalizedName), selfCanister) {
            case (null, _) { false };
            case (?_, null) { true };
            case (?id, ?selfId) { id != selfId };
        };
    };

    /// The registered shop with this normalized name, if `owner` owns it.
    public func findShop(api : API, normalizedName : Text, owner : Principal) : ?Principal {
        let ?shopId = Map.get(api.shopRegistryByName, Map.thash, normalizedName) else return null;
        switch (Map.get(api.shopRegistry, Map.phash, shopId)) {
            case (?item) { if (item.owner == owner) { ?shopId } else { null } };
            case (null) { null };
        };
    };

    public func putShopRegistryAndIndexes(api : API, item : ShopRegistryItem, normalizedName : Text) {
        switch (Map.put(api.shopRegistry, Map.phash, item.canisterId, item)) {
            case (?previous) {
                CoreSet.remove(api.shopsByDisplayName, compareShopNameKey, { name = previous.shopDetails.name; canisterId = item.canisterId });
            };
            case null {};
        };
        CoreSet.add(api.shopIdsOrdered, Principal.compare, item.canisterId);
        CoreSet.add(api.shopsByDisplayName, compareShopNameKey, { name = item.shopDetails.name; canisterId = item.canisterId });
        switch (item.presentation) {
            case (#artist) CoreSet.add(api.artistShops, Principal.compare, item.canisterId);
            case (#storefront) CoreSet.remove(api.artistShops, Principal.compare, item.canisterId);
        };
        let _ = Map.put(api.shopRegistryByOwner, Map.phash, item.owner, item.canisterId);
        let _ = Map.put(api.shopRegistryByName, Map.thash, normalizedName, item.canisterId);
        recordSlug(api, item.canisterId, item.slug);
    };

    // Slugs (BRE-71)

    /// True if any shop has or had `slug`, registered or not.
    public func slugTaken(api : API, slug : Text) : Bool {
        api.slugs.bySlug.containsKey(Text.compare, slug);
    };

    /// True if `slug` is free for `shopId` (null: a shop not created yet): no other shop has or had
    /// it, and no open quote holds it. A shop's own earlier slugs are free for it.
    public func slugAvailable(api : API, slug : Text, shopId : ?Principal) : Bool {
        switch (api.slugs.bySlug.get(Text.compare, slug), shopId) {
            case (?holder, ?id) { holder == id };
            case (?_, null) { false };
            case (null, _) { not api.slugReservedByQuote(slug) };
        };
    };

    /// A free slug made from `name`, with a numeric suffix if it's taken.
    public func deriveSlug(api : API, name : Text, shopId : ?Principal) : Text {
        Slug.unique(Slug.fromName(name), func s = slugAvailable(api, s, shopId));
    };

    func recordSlug(api : API, shopId : Principal, slug : Text) {
        api.slugs.bySlug.add(Text.compare, slug, shopId);
        let own = switch (api.slugs.byShop.get(Principal.compare, shopId)) {
            case (?list) { list };
            case null { [] };
        };
        if (Array.find<Text>(own, func s = s == slug) == null) {
            api.slugs.byShop.add(Principal.compare, shopId, Array.concat(own, [slug]));
        };
    };

    public type ResolvedShopSlug = {
        canisterId : Principal;
        /// The shop's current slug. Differs from the one asked for when that's an old slug.
        canonicalSlug : Text;
    };

    /// The registered shop that has or had `slug` (any case), and its current slug.
    public func resolveSlug(api : API, slug : Text) : ?ResolvedShopSlug {
        let ?shopId = api.slugs.bySlug.get(Text.compare, Text.toLower(slug)) else return null;
        let ?item = Map.get(api.shopRegistry, Map.phash, shopId) else return null;
        ?{ canisterId = shopId; canonicalSlug = item.slug };
    };

    public type ShopSlug = { canisterId : Principal; slug : Text };

    /// The current slug of each registered shop in `ids`, in order; unregistered ones are left out.
    /// Reads at most `Pagination.MAX_LIMIT` IDs.
    public func getSlugs(api : API, ids : [Principal]) : [ShopSlug] {
        let out = List.empty<ShopSlug>();
        var count = 0;
        label ids for (id in ids.values()) {
            if (count >= Pagination.MAX_LIMIT) break ids;
            count += 1;
            switch (Map.get(api.shopRegistry, Map.phash, id)) {
                case (?item) { out.add({ canisterId = id; slug = item.slug }) };
                case null {};
            };
        };
        out.toArray();
    };

    public type SetShopSlugError = {
        #Unauthorized;
        #NotFound;
        #InvalidSlug : Text;
        /// Another shop has or had it, or an open quote holds it.
        #SlugTaken;
        /// The shop holds `MAX_SLUGS_PER_SHOP` slugs: it can only go back to one of them.
        #TooManySlugs;
    };

    /// Changes a shop's slug. Only the shop's registry owner. The old slug keeps leading to the shop,
    /// and going back to one of the shop's own earlier slugs is allowed. Returns the new slug.
    public func setShopSlug(api : API, caller : Principal, shopId : Principal, slug : Text) : Result<Text, SetShopSlugError> {
        if (Principal.isAnonymous(caller)) { return #err(#Unauthorized) };
        let ?item = Map.get(api.shopRegistry, Map.phash, shopId) else return #err(#NotFound);
        if (item.owner != caller) { return #err(#Unauthorized) };
        switch (Slug.validate(slug)) {
            case (#err(msg)) { return #err(#InvalidSlug(msg)) };
            case (#ok) {};
        };
        if (slug == item.slug) { return #ok(slug) };
        if (not slugAvailable(api, slug, ?shopId)) { return #err(#SlugTaken) };
        let own = switch (api.slugs.byShop.get(Principal.compare, shopId)) {
            case (?list) { list };
            case null { [] };
        };
        let isOwn = Array.find<Text>(own, func s = s == slug) != null;
        if (not isOwn and own.size() >= MAX_SLUGS_PER_SHOP) {
            return #err(#TooManySlugs);
        };
        ignore Map.put(api.shopRegistry, Map.phash, shopId, { item with slug });
        recordSlug(api, shopId, slug);
        #ok(slug);
    };

    public func addToManagedShops(api : API, user : Principal, shopCanisterId : Principal) {
        let current = Option.get(Map.get(api.managedShopsByUser, Map.phash, user), []);
        if (Option.isSome(Array.find(current, func(id : Principal) : Bool { id == shopCanisterId }))) {
            return;
        };
        let shops = List.fromArray(current);
        List.add(shops, shopCanisterId);
        let updated = List.toArray(shops);
        let _ = Map.put(api.managedShopsByUser, Map.phash, user, updated);
    };

    public type AddManagedShopError = {
        #Unauthorized : Text;
        #NotFound : Text;
        #AlreadyAdded : Text;
    };

    public type AddManagedShopResponse = Result<(), AddManagedShopError>;

    /// Adds a shop the caller manages (e.g. one they were given access to). Idempotent.
    public func addManagedShop(
        api : API,
        caller : Principal,
        shopCanisterId : Principal,
        isRegisteredUser : Principal -> Bool,
    ) : AddManagedShopResponse {
        if (Principal.isAnonymous(caller)) {
            return #err(#Unauthorized("Must be signed in to add a shop"));
        };

        if (not isRegisteredUser(caller)) {
            return #err(#Unauthorized("User not registered"));
        };

        switch (Map.get(api.shopRegistry, Map.phash, shopCanisterId)) {
            case (null) {
                #err(#NotFound("Shop not found"));
            };
            case (?shop) {
                let current = Option.get(Map.get(api.managedShopsByUser, Map.phash, caller), []);
                if (Option.isSome(Array.find(current, func(id : Principal) : Bool { id == shopCanisterId }))) {
                    return #err(#AlreadyAdded("You already manage this shop"));
                };
                addToManagedShops(api, caller, shop.canisterId);
                #ok(());
            };
        };
    };

    public type UserShopInfo = {
        canisterId : Principal;
        slug : Text;
        name : Text;
    };

    public func getUserShops(api : API, caller : Principal) : [UserShopInfo] {
        var shopIds = Option.get(Map.get(api.managedShopsByUser, Map.phash, caller), []);

        // Users from before managedShopsByUser have only their owner-index shop.
        if (Array.size(shopIds) == 0) {
            let single = Map.get(api.shopRegistryByOwner, Map.phash, caller);
            switch (single) {
                case (?id) { shopIds := [id] };
                case (null) { shopIds := [] };
            };
        };

        let out = List.empty<UserShopInfo>();
        for (id in shopIds.vals()) {
            switch (Map.get(api.shopRegistry, Map.phash, id)) {
                case (?shop) {
                    out.add({
                        canisterId = shop.canisterId;
                        slug = shop.slug;
                        name = shop.shopDetails.name;
                    });
                };
                case (null) {};
            };
        };

        List.toArray(out);
    };

    public type RegisterShopRequest = {
        canisterId : Principal;
    };

    public type RegisterShopError = {
        #Unauthenticated;
        #UserNotRegistered;
        /// The caller isn't a controller of the canister.
        #NotController;
        #TooManyShops;
        /// Core couldn't read the canister's controllers or details, or subscribe to its events:
        /// it isn't a shop, doesn't answer, or core isn't a status viewer of it.
        #ShopUnreachable : Text;
        #ShopNameConflict;
        #AlreadyRegistered;
    };

    public type RegisterShopResponse = Result<(), RegisterShopError>;

    /// Registers `req.canisterId` as a shop owned by `caller`, who must be a registered user and a
    /// controller of the canister (BRE-119): the canister is untrusted, and the caller's claim to it
    /// is proven only by the management canister's controller list. Every call to the canister is
    /// bounded-wait (see the hooks) so a silent canister can't block core.
    public func registerShop(
        api : API,
        caller : Principal,
        req : RegisterShopRequest,
        isRegisteredUser : Principal -> Bool,
        hooks : RegisterShopHooks,
    ) : async RegisterShopResponse {
        if (Principal.isAnonymous(caller)) {
            return #err(#Unauthenticated);
        };
        if (not isRegisteredUser(caller)) {
            return #err(#UserNotRegistered);
        };

        let { canisterId } = req;

        if (registeredShopCount(api, caller) >= MAX_REGISTERED_SHOPS_PER_USER and not manages(api, caller, canisterId)) {
            return #err(#TooManyShops);
        };

        let controllers = try { await hooks.getControllers(canisterId) } catch (e) {
            return #err(#ShopUnreachable("Couldn't read the canister's controllers: " # Error.message(e)));
        };
        if (Option.isNull(Array.find(controllers, func(c : Principal) : Bool { c == caller }))) {
            return #err(#NotController);
        };

        switch (Map.get(api.shopRegistry, Map.phash, canisterId)) {
            case (null) {};
            case (?_) {
                try { await hooks.subscribeToShopEvents(canisterId) } catch (_) {};
                return #err(#AlreadyRegistered);
            };
        };

        let shopDetails = try { await hooks.getShopDetails(canisterId) } catch (e) {
            return #err(#ShopUnreachable("Couldn't read the shop's details: " # Error.message(e)));
        };
        let normalizedName = normalizeShopName(shopDetails.name);
        if (shopNameConflicts(api, normalizedName, ?canisterId)) {
            return #err(#ShopNameConflict);
        };

        try { await hooks.subscribeToShopEvents(canisterId) } catch (e) {
            return #err(#ShopUnreachable("Couldn't subscribe to the shop's events: " # Error.message(e)));
        };

        // The awaits above let another call register this shop or take its name.
        if (Map.has(api.shopRegistry, Map.phash, canisterId)) {
            return #err(#AlreadyRegistered);
        };
        if (shopNameConflicts(api, normalizedName, ?canisterId)) {
            return #err(#ShopNameConflict);
        };

        // A shop registered before keeps its last slug; otherwise one is made from its name. Read
        // after the awaits, so a slug taken meanwhile isn't handed out twice.
        let slug = switch (api.slugs.byShop.get(Principal.compare, canisterId)) {
            case (?own) {
                if (own.size() > 0) { own[own.size() - 1] } else {
                    deriveSlug(api, shopDetails.name, ?canisterId);
                };
            };
            case null { deriveSlug(api, shopDetails.name, ?canisterId) };
        };

        let shopRegistryItem : ShopRegistryItem = {
            canisterId;
            slug;
            owner = caller;
            shopDetails = {
                name = shopDetails.name;
                description = shopDetails.description;
                logoUrl = shopDetails.logoUrl;
                bannerImageUrl = shopDetails.bannerImageUrl;
                physicalLocation = shopDetails.physicalLocation;
                locationPublic = shopDetails.showPhysicalLocation;
            };
            registeredBy = caller;
            registrationDate = Time.now();
            presentation = #storefront;
        };

        putShopRegistryAndIndexes(api, shopRegistryItem, normalizedName);
        addToManagedShops(api, caller, canisterId);

        return #ok;
    };

    func manages(api : API, user : Principal, shopId : Principal) : Bool {
        let managed = Option.get(Map.get(api.managedShopsByUser, Map.phash, user), []);
        Option.isSome(Array.find(managed, func(id : Principal) : Bool { id == shopId }));
    };

    /// How many registered shops `user` manages (shops that were unregistered don't count).
    func registeredShopCount(api : API, user : Principal) : Nat {
        let managed = Option.get(Map.get(api.managedShopsByUser, Map.phash, user), []);
        Array.filter(managed, func(id : Principal) : Bool { Map.has(api.shopRegistry, Map.phash, id) }).size();
    };

    /// `unregisterShop` for a caller: a marketplace admin, or the shop's owner as the registry records
    /// it (BRE-119).
    public func unregisterShopAs(api : API, caller : Principal, callerIsAdmin : Bool, canisterId : Principal) : Result<(), Text> {
        switch (Map.get(api.shopRegistry, Map.phash, canisterId)) {
            case (?item) {
                if (not callerIsAdmin and (Principal.isAnonymous(caller) or item.owner != caller)) {
                    return #err("Unauthorized");
                };
            };
            case null {};
        };
        unregisterShop(api, canisterId);
    };

    public func unregisterShop(api : API, canisterId : Principal) : Result<(), Text> {
        switch (Map.get(api.shopRegistry, Map.phash, canisterId)) {
            case (null) {
                #err("Shop not found");
            };
            case (?item) {
                let _ = Map.remove(api.shopRegistry, Map.phash, canisterId);
                CoreSet.remove(api.shopIdsOrdered, Principal.compare, canisterId);
                CoreSet.remove(api.shopsByDisplayName, compareShopNameKey, { name = item.shopDetails.name; canisterId });
                CoreSet.remove(api.artistShops, Principal.compare, canisterId);
                let normalizedName = normalizeShopName(item.shopDetails.name);
                let _ = Map.remove(api.shopRegistryByName, Map.thash, normalizedName);
                let _ = Map.remove(api.shopRegistryByOwner, Map.phash, item.owner);
                // The shop's slugs stay in `slugs`: no other shop may get them (BRE-71).
                #ok(());
            };
        };
    };

    /// The location anyone may see: the shop's own when it made it public, otherwise null.
    /// Owners and admins read a private location from the shop's `getShopDetails` instead (BRE-57).
    public func publicLocation(details : ShopDetails) : ?ShopLocation {
        if (details.locationPublic) { details.physicalLocation } else { null };
    };

    /// Registered shops, for browsing, a page at a time in canister ID order, read from
    /// `shopIdsOrdered` from the cursor. Anyone can call it, so a shop's location is included only
    /// when `locationPublic` is true.
    public func listShops(api : API, after : ?Principal, limit : ?Nat) : Pagination.Page<PublicShopInfo, Principal> {
        let ids = switch (after) {
            case (?a) {
                CoreSet.valuesFrom(api.shopIdsOrdered, Principal.compare, a);
            };
            case null { CoreSet.values(api.shopIdsOrdered) };
        };
        Pagination.scan<Principal, PublicShopInfo, Principal>(
            ids,
            func id = id,
            Principal.compare,
            after,
            func id = switch (Map.get(api.shopRegistry, Map.phash, id)) {
                case (?item) {
                    ?{
                        canisterId = item.canisterId;
                        slug = item.slug;
                        name = item.shopDetails.name;
                        description = item.shopDetails.description;
                        logoUrl = item.shopDetails.logoUrl;
                        physicalLocation = publicLocation(item.shopDetails);
                        locationPublic = item.shopDetails.locationPublic;
                    };
                };
                case null { null };
            },
            limit,
        );
    };

    /// A shop shown as an artist page, as anyone may see it in the marketplace's artist listing.
    public type ArtistShopInfo = {
        canisterId : Principal;
        /// The shop's current URL slug: link to `/shop/<slug>`.
        slug : Text;
        name : Text;
        logoUrl : ?Text;
    };

    /// Shops shown as artist pages, for the marketplace's Music page (BRE-201), a page at a time in
    /// canister ID order, read from `artistShops` from the cursor. Shops trust_safety hid are left out,
    /// so a page can be short, or empty with a `next` (see `Pagination.scan`).
    public func listArtistShops(api : API, after : ?Principal, limit : ?Nat) : Pagination.Page<ArtistShopInfo, Principal> {
        if (not api.hiddenShopsCopy.complete) return { items = []; next = null };
        let ids = switch (after) {
            case (?a) CoreSet.valuesFrom(api.artistShops, Principal.compare, a);
            case null CoreSet.values(api.artistShops);
        };
        Pagination.scan<Principal, ArtistShopInfo, Principal>(
            ids,
            func id = id,
            Principal.compare,
            after,
            func id {
                if (CoreSet.contains(api.hiddenShops, Principal.compare, id)) return null;
                let ?item = Map.get(api.shopRegistry, Map.phash, id) else return null;
                ?{
                    canisterId = item.canisterId;
                    slug = item.slug;
                    name = item.shopDetails.name;
                    logoUrl = item.shopDetails.logoUrl;
                };
            },
            limit,
        );
    };

    public type ShopVisibility = { #visible; #hidden };

    /// Records trust_safety's decision to hide or show a shop, registered or not (a shop hidden before
    /// it registers stays hidden).
    public func setShopVisibility(api : API, shopId : Principal, visibility : ShopVisibility) {
        api.visibilityDecisions += 1;
        CoreMap.add(api.lastVisibilityDecision, Principal.compare, shopId, api.visibilityDecisions);
        switch (visibility) {
            case (#hidden) CoreSet.add(api.hiddenShops, Principal.compare, shopId);
            case (#visible) CoreSet.remove(api.hiddenShops, Principal.compare, shopId);
        };
    };

    /// Starts a copy of product_index's hidden shops (one at a time): forgets earlier decisions,
    /// which the copy's pages are newer than.
    public func startHiddenShopsCopy(api : API) {
        CoreMap.clear(api.lastVisibilityDecision);
    };

    /// Where trust_safety's decisions stand: take it before asking product_index for a page, and
    /// pass it to `copyHiddenShops` with that page.
    public func visibilityMark(api : API) : Nat = api.visibilityDecisions;

    /// Hides the shops of a page product_index listed as hidden, except ones trust_safety decided
    /// after `mark` (a Show while the page was in flight must not be undone). Returns how many it hid.
    /// Only adds: core's own set can't drop a shop on product_index's word, because a page doesn't
    /// say which shops were shown.
    public func copyHiddenShops(api : API, shops : [Principal], mark : Nat) : Nat {
        var hidden = 0;
        for (shopId in shops.values()) {
            let decidedSince = switch (CoreMap.get(api.lastVisibilityDecision, Principal.compare, shopId)) {
                case (?n) n > mark;
                case null false;
            };
            if (not decidedSince) {
                CoreSet.add(api.hiddenShops, Principal.compare, shopId);
                hidden += 1;
            };
        };
        hidden;
    };

    /// The whole of product_index's hidden shops has been copied once: artist shops can be listed.
    public func finishHiddenShopsCopy(api : API) {
        api.hiddenShopsCopy.complete := true;
    };

    public func productToMarketplaceListing(p : ShopInterface.Product) : MarketplaceProductListing {
        {
            productId = p.id;
            title = p.title;
            description = p.description;
            variants = Array.map(p.variants, variantToMarketplaceVariant);
            tags = p.tags;
            category = p.category;
            productType = p.productType;
        };
    };

    public func variantToMarketplaceVariant(v : ShopInterface.ProductVariant) : MarketplaceVariantListing {
        {
            variantId = v.id;
            name = v.name;
            sku = v.sku;
            priceCatalog = v.price.catalog;
            status = switch (v.status) {
                case (#Draft) { #Draft };
                case (#Active) { #Active };
                case (#Inactive) { #Inactive };
                case (#Archived) { #Archived };
            };
            attributes = Array.map(
                v.attributes,
                func(a : ShopInterface.ProductAttribute) : MarketplaceVariantAttribute {
                    {
                        key = a.key;
                        value = a.value;
                    };
                },
            );
            imageUrls = v.imageUrls;
            release = v.release;
        };
    };

    public func syncShopDetails(api : API, caller : Principal, event : ShopInterface.ShopDetailsUpdatedEvent) : () {
        if (Principal.isAnonymous(caller)) {
            return;
        };

        let shopOpt = Map.get(api.shopRegistry, Map.phash, caller);
        switch (shopOpt) {
            case (null) {
                return;
            };
            case (?item) {
                let oldName = normalizeShopName(item.shopDetails.name);
                let newName = normalizeShopName(event.data.name);
                if (shopNameConflicts(api, newName, ?caller)) {
                    api.logger.error(
                        "Shop " # Principal.toText(caller) # " attempted to update name to " # event.data.name # " which conflicts with an existing shop; skipping update"
                    );
                    return;
                };
                if (oldName != newName) {
                    let _ = Map.remove(api.shopRegistryByName, Map.thash, oldName);
                };
                let updated = {
                    item with
                    // An older shop's event has no presentation: keep the one core knows.
                    presentation = Option.get(event.data.presentation, item.presentation);
                    shopDetails = {
                        name = event.data.name;
                        description = event.data.description;
                        logoUrl = ?event.data.logoUrl;
                        bannerImageUrl = event.data.bannerImageUrl;
                        physicalLocation = event.data.physicalLocation;
                        locationPublic = event.data.locationPublic;
                    };
                };
                putShopRegistryAndIndexes(api, updated, newName);
            };
        };
    };

    /// Sends a shop's whole catalog to product_index and removes the products it no longer has
    /// (BRE-97). A whole catalog doesn't fit in one inter-canister message (2 MB), so this reads the
    /// shop a page at a time and sends each page as its own batch. Every listing is a projection of
    /// a product in the shop's reply, so a batch is never larger than the page the shop sent. Then
    /// it sends the IDs it saw, and product_index removes the rest. If the sync fails, or stops at
    /// `MAX_SYNC_PAGES`, nothing is removed: the index keeps the shop's old products until the next
    /// full sync, rather than losing products this sync didn't read.
    ///
    /// One sync per shop at a time. Check the caller before calling this.
    public func syncShopProducts(
        api : API,
        shopId : Principal,
        hooks : SyncShopProductsHooks,
    ) : async Result<SyncShopProductsResult, SyncShopProductsError> {
        if (not isRegisteredShop(api, shopId)) {
            return #err(#NotRegistered);
        };
        if (Map.has(api.productSyncs, Map.phash, shopId)) {
            return #err(#InProgress);
        };
        let sync : ProductSync = {
            updated = Map.new<ShopInterface.ProductId, ()>();
            deleted = Map.new<ShopInterface.ProductId, ()>();
        };
        // Lock the shop before the first await; `finally` unlocks it however the call ends.
        Map.set(api.productSyncs, Map.phash, shopId, sync);
        let shopText = Principal.toText(shopId);
        try {
            let seen = Map.new<ShopInterface.ProductId, ()>();
            var after : ?ShopInterface.ProductId = null;
            var pagesLeft = MAX_SYNC_PAGES;
            var complete = false;
            label pages while (pagesLeft > 0) {
                pagesLeft -= 1;
                let page = await hooks.getProductsPage(shopId, after);
                for (p in page.items.values()) {
                    Map.set(seen, Map.n32hash, p.id, ());
                };
                // Skip products an event changed after this page was read: the event's data is newer.
                let batch = Array.filter<ShopInterface.Product>(
                    page.items,
                    func p = not Map.has(sync.updated, Map.n32hash, p.id) and not Map.has(sync.deleted, Map.n32hash, p.id),
                );
                if (batch.size() > 0) {
                    switch (await api.productIndex.syncShopProductBatch(shopId, Array.map(batch, productToMarketplaceListing))) {
                        case (#ok) {};
                        case (#err(msg)) {
                            api.logger.error("Product sync for shop " # shopText # " failed sending a batch: " # msg);
                            return #err(#Failed(msg));
                        };
                    };
                };
                switch (page.next) {
                    case null {
                        complete := true;
                        break pages;
                    };
                    case (?next) { after := ?next };
                };
            };

            if (not complete) {
                api.logger.warning(
                    "Product sync for shop " # shopText # " stopped at " # Nat.toText(MAX_SYNC_PAGES) # " pages (" # Nat.toText(Map.size(seen)) # " products); later products weren't sent and none were removed"
                );
                return #ok({
                    products = Map.size(seen);
                    removed = 0;
                    complete = false;
                });
            };

            for (id in Map.keys(sync.updated)) {
                Map.set(seen, Map.n32hash, id, ());
            };
            for (id in Map.keys(sync.deleted)) {
                Map.delete(seen, Map.n32hash, id);
            };
            let keep = Iter.toArray(Map.keys(seen));
            switch (await api.productIndex.pruneShopProducts(shopId, keep)) {
                case (#ok(removed)) {
                    #ok({ products = keep.size(); removed; complete = true });
                };
                case (#err(msg)) {
                    api.logger.error("Product sync for shop " # shopText # " failed removing old products: " # msg);
                    #err(#Failed(msg));
                };
            };
        } catch (e) {
            api.logger.error("Product sync for shop " # shopText # " failed: " # Error.message(e));
            #err(#Failed(Error.message(e)));
        } finally {
            Map.delete(api.productSyncs, Map.phash, shopId);
        };
    };

    // Records a product event for a full sync of `shopId` that is running now, if there is one.
    func noteProductEvent(api : API, shopId : Principal, productId : ShopInterface.ProductId, deleted : Bool) {
        switch (Map.get(api.productSyncs, Map.phash, shopId)) {
            case null {};
            case (?sync) {
                if (deleted) {
                    Map.delete(sync.updated, Map.n32hash, productId);
                    Map.set(sync.deleted, Map.n32hash, productId, ());
                } else {
                    Map.delete(sync.deleted, Map.n32hash, productId);
                    Map.set(sync.updated, Map.n32hash, productId, ());
                };
            };
        };
    };

    public func syncUpdatedProduct(
        api : API,
        caller : Principal,
        event : ShopInterface.ProductUpdatedEvent,
    ) : async () {
        if (not isRegisteredShop(api, caller)) {
            return;
        };

        noteProductEvent(api, caller, event.data.productId, false);
        let res = await api.productIndex.syncUpdatedProduct(caller, event.data);
        switch (res) {
            case (#ok(_)) {};
            case (#err(msg)) {
                api.logger.error("Failed to sync updated product for shop " # Principal.toText(caller) # ": " # msg);
            };
        };
    };

    public func syncDeletedProduct(
        api : API,
        caller : Principal,
        event : ShopInterface.ProductDeletedEvent,
    ) : async () {
        if (not isRegisteredShop(api, caller)) {
            return;
        };

        noteProductEvent(api, caller, event.data.productId, true);
        let res = await api.productIndex.syncDeletedProducts(caller, [event.data.productId]);
        switch (res) {
            case (#ok(_)) {};
            case (#err(msg)) {
                api.logger.error("Failed to sync deleted product for shop " # Principal.toText(caller) # ": " # msg);
            };
        };
    };
};
