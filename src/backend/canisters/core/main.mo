import Error "mo:core/Error";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import { type Result } "mo:core/Result";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import Map "mo:map/Map";
import Set "mo:map/Set";
import CoreSet "mo:core/Set";

import Ledger "canister:icp_ledger";
import CKUSDC_Ledger "canister:ckusdc_ledger";
import XRC "canister:xrc";

import Management "../../interfaces/management";

import CanisterCycles "../../lib/CanisterCycles";
import WasmVersion "../../lib/WasmVersion";
import Logger "../../lib/Logger";
import Pagination "../../lib/Pagination";
import ExchangeRates "../../lib/ExchangeRates";
import ExchangeRatesMixin "../../mixins/ExchangeRates";
import Logs "../../mixins/Logs";
import TeamApi "../../mixins/Team";
import Permissions "../../lib/Permissions";
import PlatformPermissions "../../lib/PlatformPermissions";
import ShopInterface "../../interfaces/shop";
import VaultInterface "../../interfaces/vault";
import ShopProvisioning "./provisioning/shop";

import AddressesAPI "./api/addresses";
import AdminAPI "./api/admin";
import ShopAPI "./api/shop";
import OrderAPI "./api/orders";
import CanisterManagementAPI "./api/canister_management";
import MediaAPI "./api/media";
import ShopCreationAPI "./api/shop_creation";
import ShopCanistersAPI "./api/shop_canisters";
import ShopCyclesAPI "./api/shop_cycles";
import RateLimit "../../lib/RateLimit";
import ShopCallFeesAPI "./api/shop_call_fees";
import UpgradesAPI "./api/upgrades";
import HandoverAPI "./api/handover";
import ReleasesAPI "./api/releases";
import AlertsAPI "./api/alerts";
import HistoryAPI "./api/history";
import ShopEvents "./lib/ShopEvents";
import Siblings "./lib/Siblings";
import Types "./types";

import Users "./mixins/Users";
import Alerts "./mixins/Alerts";
import Admins "./mixins/Admins";
import History "./mixins/History";
import ShopCreation "./mixins/ShopCreation";
import Shops "./mixins/Shops";
import Orders "./mixins/Orders";
import Balances "./mixins/Balances";
import Upgrades "./mixins/Upgrades";
import ShopCycles "./mixins/ShopCycles";
import Handover "./mixins/Handover";
import Releases "./mixins/Releases";
import ShopCallFees "./mixins/ShopCallFees";
import Marketplace "./mixins/Marketplace";
import Addresses "./mixins/Addresses";

shared ({ caller = initializer }) persistent actor class Core() = self {
    transient let logState = Logger.new(Principal.fromActor(self), ?true);
    transient let logger = Logger.bind(logState);

    // A record rather than the actor, so the APIs can take a mock factory in tests.
    transient let canisterFactory = {
        getWasm = func(name : WasmVersion.WasmName, version : WasmVersion.Version) : async Result<{ wasm : Blob; sha256 : Blob }, { #NotFound; #Yanked }> {
            await Siblings.canisterFactory<system>().getWasm(name, version);
        };
        createCanister = func(settings : ?Management.CanisterSettings) : async Result<{ canisterId : Principal; isNewCanister : Bool }, { #Unauthorized : Text }> {
            await Siblings.canisterFactory<system>().createCanister(settings);
        };
        addCanisterToPool = func(canisterId : Principal) : async Result<(), { #Unauthorized : Text }> {
            await Siblings.canisterFactory<system>().addCanisterToPool(canisterId);
        };
    };

    // Stable state gets its initial values from the migration chain in ./migrations.

    let userRegistry : Map.Map<Principal, Types.UserRegistryItem>;

    let shopRegistry : Map.Map<Principal, ShopAPI.ShopRegistryItem>;

    let shopRegistryByOwner : Map.Map<Principal, Principal>;

    // Keyed by normalized name (lowercase, no spaces)
    let shopRegistryByName : Map.Map<Text, Principal>;

    // Every URL slug each shop has had, current and earlier (BRE-71)
    let shopSlugs : ShopAPI.SlugState;

    // Registered shops in canister ID order and by display name, for paging the registry (BRE-96)
    let shopIdsOrdered : CoreSet.Set<Principal>;
    let shopsByDisplayName : CoreSet.Set<ShopAPI.ShopNameKey>;

    // Registered shops shown as artist pages, and shops trust_safety hid, for listing artists (BRE-201)
    let artistShops : CoreSet.Set<Principal>;
    let hiddenShops : CoreSet.Set<Principal>;
    let hiddenShopsCopy : { var complete : Bool };

    // Shops each user created or added via addManagedShop
    let managedShopsByUser : Map.Map<Principal, [Principal]>;

    // Each user's saved shipping addresses, private to that user (BRE-209)
    let savedAddresses : AddressesAPI.AddressesByUser;

    let exchangeRateCache : ExchangeRates.Cache;
    transient let exchangeRates = ExchangeRates.newState(exchangeRateCache);
    include ExchangeRatesMixin(exchangeRates, XRC);

    // Platform staff (BRE-152): roles made of `PlatformPermissions`, held by principals. Core's
    // controllers hold every permission without a role.
    let team : Permissions.Store;

    // What staff, merchants and core did to the marketplace, and who did it (BRE-153).
    let marketplaceHistory : HistoryAPI.State;

    // Events staff are alerted to, and each staff member's alert settings (BRE-210).
    let platformAlerts : AlertsAPI.State;

    let orders : Map.Map<OrderAPI.OrderKey, OrderAPI.Order>;

    // Each buyer's orders, newest first, for paging a user's orders (BRE-96)
    let ordersByBuyer : Map.Map<Principal, CoreSet.Set<OrderAPI.UserOrderCursor>>;

    // Shops whose event subscription last failed (see listUnsubscribedShops)
    let unsubscribedShops : Set.Set<Principal>;

    // How far core has read each shop's order log, and orders found there it couldn't read (BRE-203)
    let orderCatchUp : OrderAPI.CatchUpState;

    // Each shop's vault and the wasm version core last installed on each shop and vault
    let shopCanistersState : ShopCanistersAPI.State;

    // Wasm rollouts (canary, approval), the version each shop or vault ran at its last snapshot, and
    // the current shop and vault versions new shops get (BRE-85)
    let upgradesState : UpgradesAPI.State;

    // Shops handed over to a merchant's own principal, and handovers waiting for it to confirm (BRE-79)
    let handoverState : HandoverAPI.State;

    // Shop and vault releases published for self-managed merchants (BRE-79)
    let releasesState : ReleasesAPI.State;

    // Whether shops core doesn't host must attach cycles to their events (BRE-116)
    let shopCallFeesState : ShopCallFeesAPI.State;

    // Shops and vaults with an upgrade, restore, start or handover step running
    transient let upgradesBusy = CoreSet.empty<Principal>();

    // Sampled cycle balances of shops and vaults, for their time left before freezing (BRE-13)
    let shopCyclesState : ShopCyclesAPI.State;

    // Settled shop creation quotes whose deposit account was found empty: the admin balances view
    // stops reading them (BRE-101)
    let emptyQuoteDeposits : CoreSet.Set<Nat>;

    // Shops and vaults with a status read in flight (see refreshShopCycles)
    transient let shopCyclesBusy = CoreSet.empty<Principal>();

    transient let shopCyclesOps = ShopCyclesAPI.managementOperations(Time.now);

    // Canister status reads each user may trigger with refreshShopCycles per hour (BRE-120)
    transient let shopCyclesRefreshQuota = RateLimit.perCaller(ShopCyclesAPI.refreshReadsPerHour, 3_600_000_000_000);

    // New registrations core accepts per hour in total, and the most users it holds (BRE-120). 200 an
    // hour is under 1 MB of registry a day; a flood can block sign-ups until a fee or proof of
    // work per sign-up exists.
    transient let registrationBudget = RateLimit.global(200, 3_600_000_000_000);
    transient let maxUsers = 1_000_000;

    transient let adminApi = AdminAPI.API({
        team;
        isController = Principal.isController;
    });

    transient let createMediaCanisterDeps = {
        logger;
        canisterFactory;
        releaseCanister = CanisterManagementAPI.releaseCanister;
        backendController = Principal.fromActor(self);
        cycles = CanisterCycles.managementOperations();
    };

    transient let coreId = Principal.fromActor(self);

    /// Checks a canister core just created against the factory's hash of the version it installed,
    /// and records both (BRE-85). Failures are logged: the canister exists either way.
    func verifyNewInstall(canisterId : Principal, name : WasmVersion.WasmName, version : WasmVersion.Version) : async* () {
        let info = try {
            await Siblings.canisterFactory<system>().getWasmInfo(name, version);
        } catch (e) {
            logger.error("Couldn't read the factory's hash of " # WasmVersion.key(name, version) # ": " # Error.message(e));
            null;
        };
        switch (info) {
            case (?i) {
                await* ShopCanistersAPI.verifyInstall(shopCanistersState, canisterId, name, version, i.sha256, UpgradesAPI.moduleHash, logger);
            };
            case (null) {
                logger.error("The factory has no hash of " # WasmVersion.key(name, version) # ", installed on " # Principal.toText(canisterId));
            };
        };
    };

    func createMediaCanisterFor(caller : Principal) : async MediaAPI.CreateMediaCanisterResponse {
        let version = switch (UpgradesAPI.currentVersion(upgradesState, #vault)) {
            case (?v) { v };
            case (null) {
                logger.error("Can't create a vault: no vault version is current");
                return #err(#WasmNotFound);
            };
        };
        let res = await MediaAPI.createMediaCanister(caller, createMediaCanisterDeps, version);
        switch (res) {
            case (#ok(vaultId)) {
                ShopCanistersAPI.recordInstall(shopCanistersState, vaultId, { version; sha256 = null });
                logger.info("Created vault " # Principal.toText(vaultId) # " (" # WasmVersion.toText(version) # ") for " # Principal.toText(caller));
                await* verifyNewInstall(vaultId, #vault, version);
            };
            case (#err(_)) {};
        };
        res;
    };

    // Paid shop creation: quotes, their deposit accounts and reserved shop names and slugs
    let shopCreationState : ShopCreationAPI.State;

    transient let shopApi = ShopAPI.API({
        shopRegistry;
        shopRegistryByOwner;
        shopRegistryByName;
        shopIdsOrdered;
        shopsByDisplayName;
        artistShops;
        hiddenShops;
        hiddenShopsCopy;
        managedShopsByUser;
        slugs = shopSlugs;
        slugReservedByQuote = func(slug : Text) : Bool {
            ShopCreationAPI.slugReserved(shopCreationState, slug, Time.now());
        };
        ShopService = {
            createShop = ShopProvisioning.createShop;
        };
        logger;
        canisterFactory;
        releaseCanister = CanisterManagementAPI.releaseCanister;
        createMediaCanister = createMediaCanisterFor;
        productIndex = {
            syncShopProductBatch = func(shopId : Principal, products : [ShopAPI.MarketplaceProductListing]) : async Result<(), Text> {
                await Siblings.productIndex<system>().syncShopProductBatch(shopId, products);
            };
            pruneShopProducts = func(shopId : Principal, keep : [ShopInterface.ProductId]) : async Result<Nat, Text> {
                await Siblings.productIndex<system>().pruneShopProducts(shopId, keep);
            };
            syncUpdatedProduct = func(shopId : Principal, product : ShopAPI.MarketplaceProductListing) : async Result<(), Text> {
                await Siblings.productIndex<system>().syncUpdatedProduct(shopId, product);
            };
            syncDeletedProducts = func(shopId : Principal, productIds : [ShopInterface.ProductId]) : async Result<(), Text> {
                await Siblings.productIndex<system>().syncDeletedProducts(shopId, productIds);
            };
        };
    });

    transient let orderApi = OrderAPI.API({
        orders;
        ordersByBuyer;
        unsubscribedShops;
        catchUp = orderCatchUp;
        shopApi = {
            getShopName = func(shopId : Principal) : Text {
                ShopAPI.getShopName(shopApi, shopId);
            };
            isRegisteredShop = func(shopId : Principal) : Bool {
                ShopAPI.isRegisteredShop(shopApi, shopId);
            };
        };
        logger;
    });

    // Reads a shop's catalog for a full product sync.
    transient let productPages : ShopAPI.SyncShopProductsHooks = {
        getProductsPage = func(shopId : Principal, after : ?ShopInterface.ProductId) : async ShopAPI.ProductsPage {
            let shop = actor (shopId.toText()) : ShopInterface.Shop;
            await (with timeout = 30) shop.getProducts(after, ?Pagination.MAX_LIMIT);
        };
    };

    // Reads a shop's order log and orders for an order catch-up (BRE-203).
    transient let orderLog : OrderAPI.OrderLogHooks = {
        listOrderEvents = func(shopId : Principal, after : ?Nat, limit : ?Nat) : async {
            items : [ShopInterface.OrderEvent];
            next : ?Nat;
        } {
            let shop = actor (shopId.toText()) : ShopInterface.Shop;
            await (with timeout = 30) shop.listOrderEvents(after, limit);
        };
        getOrder = func(shopId : Principal, orderId : OrderAPI.OrderId) : async ShopInterface.GetOrderResponse {
            let shop = actor (shopId.toText()) : ShopInterface.Shop;
            await (with timeout = 30) shop.getMyOrder(orderId);
        };
    };

    transient let subscriptionChecks : OrderAPI.SubscriptionCheckHooks = {
        orderLog;
        getSubscriptions = ShopEvents.subscriptions;
        subscribe = ShopEvents.subscriber(coreId);
        syncProducts = func(shopId : Principal) : async Result<(), Text> {
            switch (await ShopAPI.syncShopProducts(shopApi, shopId, productPages)) {
                case (#ok({ complete = true })) #ok;
                case (#ok(_)) #err("stopped at " # debug_show ShopAPI.MAX_SYNC_PAGES # " pages");
                case (#err(#Failed(msg))) #err(msg);
                case (#err(e)) #err(debug_show e);
            };
        };
    };

    transient let shopCreationApi = ShopCreationAPI.API({
        state = shopCreationState;
        self = Principal.fromActor(self);
        ledgers = {
            balanceOf = func(currency : ShopCreationAPI.Currency, account : ShopCreationAPI.Account) : async Nat {
                switch (currency) {
                    case (#ICP) { await Ledger.icrc1_balance_of(account) };
                    case (#ckUSDC) {
                        await CKUSDC_Ledger.icrc1_balance_of(account);
                    };
                };
            };
            fee = func(currency : ShopCreationAPI.Currency) : async Nat {
                switch (currency) {
                    case (#ICP) { await Ledger.icrc1_fee() };
                    case (#ckUSDC) { await CKUSDC_Ledger.icrc1_fee() };
                };
            };
            transfer = func(currency : ShopCreationAPI.Currency, args : ShopCreationAPI.TransferArgs) : async Result<Nat, Text> {
                let transferArg = {
                    from_subaccount = ?args.fromSubaccount;
                    to = args.to;
                    amount = args.amount;
                    fee = ?args.fee;
                    memo = null;
                    // Lets the ledger reject a repeat of this exact transfer (BRE-70).
                    created_at_time = ?args.createdAtTime;
                };
                // #Duplicate: the ledger already holds this exact transfer, so it went out.
                switch (currency) {
                    case (#ICP) {
                        switch (await Ledger.icrc1_transfer(transferArg)) {
                            case (#Ok(blockIndex)) { #ok(blockIndex) };
                            case (#Err(#Duplicate({ duplicate_of }))) {
                                #ok(duplicate_of);
                            };
                            case (#Err(e)) { #err(debug_show (e)) };
                        };
                    };
                    case (#ckUSDC) {
                        switch (await CKUSDC_Ledger.icrc1_transfer(transferArg)) {
                            case (#Ok(blockIndex)) { #ok(blockIndex) };
                            case (#Err(#Duplicate({ duplicate_of }))) {
                                #ok(duplicate_of);
                            };
                            case (#Err(e)) { #err(debug_show (e)) };
                        };
                    };
                };
            };
        };
        shopNameTaken = func(normalizedName : Text) : Bool {
            ShopAPI.shopNameConflicts(shopApi, normalizedName, null);
        };
        shopSlugTaken = func(slug : Text) : Bool {
            ShopAPI.slugTaken(shopApi, slug);
        };
        findShop = func(normalizedName : Text, owner : Principal) : ?Principal {
            ShopAPI.findShop(shopApi, normalizedName, owner);
        };
        now = Time.now;
        logger;
    });

    var shopCount : Nat;

    // Kept here rather than in the ShopCreation mixin because it counts shops in `shopCount`, an
    // actor `var` a mixin can't assign.
    func createShopForQuote(quote : ShopCreationAPI.Quote) : async Result<Principal, Text> {
        let owner = quote.owner;
        let version = switch (UpgradesAPI.currentVersion(upgradesState, #shop)) {
            case (?v) { v };
            case (null) { return #err("No shop version is current") };
        };
        logger.info("Creating shop \"" # quote.name # "\" (" # WasmVersion.toText(version) # ") for quote " # debug_show (quote.id) # " (owner " # Principal.toText(owner) # ")");
        let res = await ShopAPI.createShop(
            shopApi,
            owner,
            coreId,
            {
                name = quote.name;
                description = quote.description;
                slug = quote.slug;
            },
            version,
        );

        let (item, mediaCanisterId) = switch (res) {
            case (#ok(item)) { item };
            case (#err(#CanisterCreationFailed(msg))) {
                return #err(msg);
            };
        };
        let { canisterId } = item;

        shopCount += 1;
        ShopAPI.putShopRegistryAndIndexes(shopApi, item, quote.normalizedName);
        ShopAPI.addToManagedShops(shopApi, owner, canisterId);
        ignore HistoryAPI.record(marketplaceHistory, owner, ?canisterId, #shopCreated({ owner; quoteId = quote.id }));
        ignore AlertsAPI.record(platformAlerts, #shopCreated({ shop = canisterId; owner }));
        ShopCanistersAPI.recordInstall(shopCanistersState, canisterId, { version; sha256 = null });
        ShopCanistersAPI.linkVault(shopCanistersState, canisterId, mediaCanisterId);
        logger.info("Registered shop " # Principal.toText(canisterId) # " (" # WasmVersion.toText(version) # ") with vault " # Principal.toText(mediaCanisterId) # " for quote " # debug_show (quote.id));

        // The shop exists and is registered from here on, so a failed step is logged rather than
        // returned: failing would mark the quote retryable, and a retry would create a second shop.
        // verifyNewInstall logs its own failures.
        await* verifyNewInstall(canisterId, #shop, version);
        try {
            let media = actor (Principal.toText(mediaCanisterId)) : VaultInterface.Vault;
            await media.setShopCanisterId(canisterId);

            let shop = actor (Principal.toText(canisterId)) : ShopInterface.Shop;
            switch (await shop.setMediaCanisterId(mediaCanisterId)) {
                case (#ok(_)) {};
                case (#err(#Unauthorized(msg))) {
                    logger.error("Failed to set media canister ID for shop " # Principal.toText(canisterId) # ": " # msg);
                };
            };
            switch (await shop.setOwner(owner)) {
                case (#ok(_)) {};
                case (#err(#Unauthorized(msg))) {
                    logger.error("Failed to set owner for shop " # Principal.toText(canisterId) # ": " # msg);
                };
            };
        } catch (e) {
            logger.error("Failed to finish setting up shop " # Principal.toText(canisterId) # ": " # Error.message(e));
        };

        // Outside the try above so a failed media link doesn't also leave the shop unsubscribed.
        // A failure is recorded for listUnsubscribedShops / resubscribeShops instead of returned.
        switch (await OrderAPI.subscribeShop(orderApi, canisterId, ShopEvents.subscriber(coreId))) {
            case (#ok) {
                logger.info("Subscribed to events of shop " # Principal.toText(canisterId));
            };
            case (#err(_)) {}; // subscribeShop logs the error
        };

        logger.info("Finished creating shop " # Principal.toText(canisterId) # " for " # Principal.toText(owner) # " (" # debug_show (shopCount) # " shops created)");
        return #ok(canisterId);
    };

    include Users(userRegistry, registrationBudget, maxUsers, func(user : Principal) = ignore AlertsAPI.record(platformAlerts, #userRegistered({ user })));
    include Alerts(adminApi, platformAlerts);
    include Admins(adminApi);
    include TeamApi(
        adminApi.access,
        logger,
        func(caller : Principal, change : Permissions.TeamChange) {
            ignore HistoryAPI.record(marketplaceHistory, caller, null, change);
        },
    );
    include History(adminApi, marketplaceHistory);
    include ShopCreation(shopCreationApi, adminApi, shopCreationState, exchangeRates, userRegistry, createShopForQuote, marketplaceHistory, platformAlerts);
    include Shops(shopApi, adminApi, shopCanistersState, handoverState, shopCallFeesState, userRegistry, marketplaceHistory, platformAlerts, coreId, productPages, func(shopId : Principal) = OrderAPI.forgetShop(orderApi, shopId));
    include Orders(orderApi, adminApi, shopRegistry, shopCallFeesState, coreId, subscriptionChecks);
    include ShopCallFees(shopCallFeesState, marketplaceHistory);
    include Balances(adminApi, coreId, shopCreationState, emptyQuoteDeposits);
    include Upgrades(adminApi, shopCanistersState, shopRegistry, upgradesState, upgradesBusy, handoverState, marketplaceHistory, logger);
    include Handover(handoverState, shopCanistersState, shopRegistry, upgradesBusy, marketplaceHistory, coreId);
    include Releases(adminApi, releasesState, marketplaceHistory);
    include ShopCycles(shopRegistry, shopCanistersState, shopCyclesState, handoverState, userRegistry, shopCyclesOps, shopCyclesBusy, shopCyclesRefreshQuota);
    include Logs(logState, func(caller : Principal) : Bool = AdminAPI.has(adminApi, caller, PlatformPermissions.logsView));
    // Read on install and upgrade (a query has no `system` capability); literal name: see lib/Siblings.
    transient let frontendCanisterId = switch (Runtime.envVar<system>("PUBLIC_CANISTER_ID:frontend")) {
        case (?id) ?Principal.fromText(id);
        case null null;
    };
    include Marketplace(coreId, frontendCanisterId);
    include Addresses(savedAddresses, userRegistry);

    // Whether the daily cycles sample is running, so a slow run and the next don't overlap.
    transient var samplingShopCycles = false;

    /// Reads the cycle balance of every registered shop and its vault (BRE-13).
    func sampleShopCycles() : async () {
        if (samplingShopCycles) return;
        samplingShopCycles := true;
        try {
            // Self-managed shops and vaults (BRE-79) are skipped: core is no longer their controller.
            let ids = List.empty<Principal>();
            func addUnlessSelfManaged(id : Principal) {
                if (not HandoverAPI.isSelfManaged(handoverState, id)) ids.add(id);
            };
            for (shopId in Map.keys(shopRegistry)) {
                addUnlessSelfManaged(shopId);
                switch (Map.get(shopCanistersState.vaultsByShop, Map.phash, shopId)) {
                    case (?vaultId) addUnlessSelfManaged(vaultId);
                    case null {};
                };
            };
            let failures = await* ShopCyclesAPI.sample(shopCyclesState, shopCyclesOps, ids.toArray());
            for ((id, msg) in failures.vals()) {
                logger.error("Failed to read the cycles of " # Principal.toText(id) # ": " # msg);
            };
            logger.info("Sampled the cycles of " # debug_show (ids.size() - failures.size()) # " shop and vault canisters");
        } finally {
            samplingShopCycles := false;
        };
    };

    // Whether the daily subscription check is running, so a slow run and the next don't overlap.
    transient var checkingShopSubscriptions = false;

    /// Finds registered shops that dropped core's event subscription and repairs them (BRE-195).
    func checkAllShopSubscriptions() : async () {
        if (checkingShopSubscriptions) return;
        checkingShopSubscriptions := true;
        try {
            let results = await OrderAPI.checkShopSubscriptions(orderApi, Iter.toArray(Map.keys(shopRegistry)), subscriptionChecks);
            var resubscribed = 0;
            var resynced = 0;
            var unknown = 0;
            var orderEvents = 0;
            var ordersPending = 0;
            var ordersSkipped = 0;
            for (r in results.values()) {
                switch (r.check) {
                    case (#resubscribed(_)) resubscribed += 1;
                    case (#resynced(_)) resynced += 1;
                    case (#unknown(_)) unknown += 1;
                    case _ {};
                };
                switch (r.orders) {
                    case (#caughtUp({ events; pending })) {
                        orderEvents += events;
                        ordersPending += pending;
                    };
                    case (#skipped(_) or #unknown(_)) ordersSkipped += 1;
                    case _ {};
                };
            };
            logger.info("Checked the event subscriptions of " # debug_show results.size() # " shops: " # debug_show resubscribed # " resubscribed, " # debug_show resynced # " resynced, " # debug_show unknown # " couldn't say. Order catch-up: " # debug_show orderEvents # " events read, " # debug_show ordersPending # " orders waiting, " # debug_show ordersSkipped # " shops skipped");
        } finally {
            checkingShopSubscriptions := false;
        };
    };

    // Whether a copy of product_index's hidden shops is running, so a retry and the daily copy don't overlap.
    transient var copyingHiddenShops = false;

    /// Copies product_index's hidden shops into `hiddenShops` (BRE-201). trust_safety tells core of
    /// every hide or show, but not of shops it hid before core kept the set, nor of a decision whose
    /// call to core failed after product_index took it. Skips shops trust_safety decided while a page
    /// was in flight, so a Show isn't undone. Until a first copy completes core lists no artists, so a
    /// failed first copy is retried in five minutes rather than the next day.
    func copyHiddenShops() : async () {
        if (copyingHiddenShops) return;
        copyingHiddenShops := true;
        ShopAPI.startHiddenShopsCopy(shopApi);
        var after : ?Principal = null;
        var copied = 0;
        var complete = false;
        try {
            label pages loop {
                let mark = ShopAPI.visibilityMark(shopApi);
                let page = switch (await (with timeout = 30) Siblings.productIndex<system>().listHiddenShops(after, ?Pagination.MAX_LIMIT)) {
                    case (#ok(page)) page;
                    case (#err(msg)) {
                        logger.error("product_index refused to list hidden shops: " # msg);
                        break pages;
                    };
                };
                copied += ShopAPI.copyHiddenShops(shopApi, page.items, mark);
                switch (page.next) {
                    case (?next) after := ?next;
                    case null {
                        ShopAPI.finishHiddenShopsCopy(shopApi);
                        complete := true;
                        logger.info("Copied " # debug_show copied # " hidden shops from product_index");
                        break pages;
                    };
                };
            };
        } catch (e) {
            logger.error("Couldn't copy hidden shops from product_index: " # Error.message(e));
        } finally {
            copyingHiddenShops := false;
        };
        if (not complete and not hiddenShopsCopy.complete) {
            ignore Timer.setTimer<system>(#seconds 300, copyHiddenShops);
        };
    };

    // Timers don't survive upgrades, so arm them on install and every upgrade: one cycles sample a
    // minute in (so a new deploy has readings), then daily; a subscription check five minutes in,
    // then daily. The check also catches up on orders from each shop's order log, so orders placed
    // while core was stopped or upgrading reach the index (BRE-203). Hidden shops are copied from
    // product_index two minutes in (product_index may still be stopped mid-release then), then
    // daily. Arming a timer can't trap.
    ignore Timer.setTimer<system>(#seconds 60, sampleShopCycles);
    ignore Timer.recurringTimer<system>(#seconds(ShopCyclesAPI.sampleIntervalSeconds), sampleShopCycles);
    ignore Timer.setTimer<system>(#seconds 300, checkAllShopSubscriptions);
    ignore Timer.setTimer<system>(#seconds 120, copyHiddenShops);
    ignore Timer.recurringTimer<system>(#seconds(24 * 60 * 60), copyHiddenShops);
    ignore Timer.recurringTimer<system>(#seconds(24 * 60 * 60), checkAllShopSubscriptions);
};
