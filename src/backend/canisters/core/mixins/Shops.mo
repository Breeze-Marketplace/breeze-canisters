import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Map "mo:map/Map";

import Pagination "../../../lib/Pagination";
import ManagementInterface "../../../interfaces/management";
import ShopInterface "../../../interfaces/shop";
import AdminAPI "../api/admin";
import PlatformPermissions "../../../lib/PlatformPermissions";
import HandoverAPI "../api/handover";
import ShopAPI "../api/shop";
import ShopCallFeesAPI "../api/shop_call_fees";
import ShopCanistersAPI "../api/shop_canisters";
import ShopEvents "../lib/ShopEvents";
import Siblings "../lib/Siblings";
import Types "../types";
import AlertsAPI "../api/alerts";
import HistoryAPI "../api/history";

/// The shop registry: registering and listing shops, the shops a user manages, and the detail and
/// product syncs that shops send core (see `lib/ShopEvents`).
mixin (
    shopApi : ShopAPI.API,
    adminApi : AdminAPI.API,
    shopCanistersState : ShopCanistersAPI.State,
    handoverState : HandoverAPI.State,
    callFees : ShopCallFeesAPI.State,
    userRegistry : Map.Map<Principal, Types.UserRegistryItem>,
    history : HistoryAPI.State,
    // Records a platform alert and pushes it to staff who asked (BRE-211).
    recordAlert : <system>(AlertsAPI.AlertKind) -> (),
    coreId : Principal,
    productPages : ShopAPI.SyncShopProductsHooks,
    // Drops how far core read an unregistered shop's order log (BRE-203).
    forgetShopOrders : (shopId : Principal) -> (),
) {
    /// Registers an existing Shop canister in the marketplace. Used when a user creates a shop via other means (e.g. CLI) and wants to list it in the marketplace, or to re-register after unregistering. The caller must be a registered user and a controller of the canister, which core reads through `canister_status`: core must be a controller or status viewer of it (`icp canister settings update <shop> --add-status-viewer <core>`), and the caller's Breeze sign-in principal must be one of the controllers. The shop's vault is recorded too when the caller controls it and core can read its controllers; otherwise an admin links it with `linkShopVault`.
    public shared ({ caller }) func registerShop(req : ShopAPI.RegisterShopRequest) : async ShopAPI.RegisterShopResponse {
        let getControllers = func(canisterId : Principal) : async [Principal] {
            let ic = actor "aaaaa-aa" : ManagementInterface.Management;
            let status = await (with timeout = ShopAPI.REGISTER_CALL_TIMEOUT_SECONDS) ic.canister_status({
                canister_id = canisterId;
            });
            status.settings.controllers;
        };
        let res = await ShopAPI.registerShop(
            shopApi,
            caller,
            req,
            func p = Map.has(userRegistry, Map.phash, p),
            {
                getControllers;
                getShopDetails = func(canisterId : Principal) : async ShopAPI.ShopCanisterDetails {
                    let shop = actor (canisterId.toText()) : ShopInterface.Shop;
                    await (with timeout = ShopAPI.REGISTER_CALL_TIMEOUT_SECONDS) shop.getShopDetails();
                };
                subscribeToShopEvents = ShopEvents.subscriber(coreId);
            },
        );
        if (res == #ok) {
            ignore HistoryAPI.record(history, caller, ?req.canisterId, #shopRegistered({ owner = caller }));
            recordAlert<system>(#shopRegistered({ shop = req.canisterId; owner = caller }));
            ignore await ShopCanistersAPI.linkRegisteredShopVault(
                shopCanistersState,
                req.canisterId,
                caller,
                {
                    getMediaCanisterId = func(shopId : Principal) : async ?Principal {
                        let shop = actor (shopId.toText()) : actor {
                            getMediaCanisterId : query () -> async ?Principal;
                        };
                        await (with timeout = ShopAPI.REGISTER_CALL_TIMEOUT_SECONDS) shop.getMediaCanisterId();
                    };
                    getControllers;
                },
            );
        };
        res;
    };

    /// Shops registered in the marketplace, for browsing, a page at a time in canister ID order (see
    /// `lib/Pagination`: pass `next` back as `after`).
    public query func listShops(after : ?Principal, limit : ?Nat) : async Pagination.Page<ShopAPI.PublicShopInfo, Principal> {
        ShopAPI.listShops(shopApi, after, limit);
    };

    /// Shops shown as artist pages, for the marketplace's Music page (BRE-201), a page at a time in
    /// canister ID order: pass `next` back as `after`. Shops trust_safety hid are left out, so a page
    /// can be short, or empty with a `next`. Empty until core has first copied the hidden shops from
    /// product_index, two minutes after the upgrade that added this (BRE-201).
    public query func listArtistShops(after : ?Principal, limit : ?Nat) : async Pagination.Page<ShopAPI.ArtistShopInfo, Principal> {
        ShopAPI.listArtistShops(shopApi, after, limit);
    };

    /// Hides a shop from, or shows it again in, core's public listings of artists. Only trust_safety
    /// calls it, with each moderator's decision it also sends product_index.
    public shared ({ caller }) func setShopVisibility(shopId : Principal, visibility : ShopAPI.ShopVisibility) : async Result<(), Text> {
        if (not Siblings.isTrustSafety<system>(caller)) {
            return #err("Unauthorized");
        };
        ShopAPI.setShopVisibility(shopApi, shopId, visibility);
        #ok;
    };

    /// The registered shop that has or had `slug` (any case), with its current slug (BRE-71). An old
    /// slug resolves too: send the visitor to `canonicalSlug`. Null for an unknown slug.
    public query func resolveShopSlug(slug : Text) : async ?ShopAPI.ResolvedShopSlug {
        ShopAPI.resolveSlug(shopApi, slug);
    };

    /// The current slug of each registered shop in `ids` (at most 200), for building shop links from
    /// canister IDs (products, orders). Unregistered shops are left out.
    public query func getShopSlugs(ids : [Principal]) : async [ShopAPI.ShopSlug] {
        ShopAPI.getSlugs(shopApi, ids);
    };

    /// Changes a shop's URL slug. Only the shop's owner (as core's registry records it). Its old slug
    /// keeps leading to it, and no other shop can get it; a shop holds at most 10 slugs.
    public shared ({ caller }) func setShopSlug(shopId : Principal, slug : Text) : async Result<Text, ShopAPI.SetShopSlugError> {
        let result = ShopAPI.setShopSlug(shopApi, caller, shopId, slug);
        switch (result) {
            case (#ok(canonical)) ignore HistoryAPI.record(history, caller, ?shopId, #shopSlugChanged({ slug = canonical }));
            case (#err(_)) {};
        };
        result;
    };

    /// Every registered shop with its owner, vault, who controls them (`control`, BRE-79), and the
    /// wasm version core last installed on the shop and its vault (null when unknown: shops created
    /// before versions were recorded, shops registered with `registerShop`, and self-managed
    /// shops). A page at a time, by name. Needs `Shops.View`.
    public query ({ caller }) func listShopRegistry(after : ?ShopCanistersAPI.RegistryCursor, limit : ?Nat) : async Result<Pagination.Page<ShopCanistersAPI.AdminShopInfo, ShopCanistersAPI.RegistryCursor>, { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.shopsView)) {
            return #err(#Unauthorized);
        };
        #ok(ShopCanistersAPI.page(shopCanistersState, shopApi.shopRegistry, shopApi.shopsByDisplayName, func(id : Principal) : HandoverAPI.ControlStatus = HandoverAPI.status(handoverState, id), after, limit));
    };

    /// Asks a registered shop for its vault and records it, for shops whose vault core didn't record
    /// (created before it did, or added with `registerShop`). Returns the vault, or null if the shop
    /// has none. Needs `Shops.Manage`.
    public shared ({ caller }) func linkShopVault(shopId : Principal) : async Result<?Principal, ShopCanistersAPI.LinkShopVaultError or { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.shopsManage)) {
            return #err(#Unauthorized);
        };
        switch (
            await ShopCanistersAPI.linkShopVault(
                shopCanistersState,
                shopApi.shopRegistry,
                shopId,
                func(id : Principal) : async ?Principal {
                    let shop = actor (id.toText()) : actor {
                        getMediaCanisterId : query () -> async ?Principal;
                    };
                    await shop.getMediaCanisterId();
                },
            )
        ) {
            case (#ok(vaultId)) {
                ignore HistoryAPI.record(history, caller, ?shopId, #vaultLinked({ vault = vaultId }));
                #ok(vaultId);
            };
            case (#err(#NotFound)) { #err(#NotFound) };
        };
    };

    /// Unregisters a shop canister from the marketplace: the shop's owner (as core's registry records
    /// it) or an admin. Idempotent for an admin; BRE-119.
    public shared ({ caller }) func unregisterShop(canisterId : Principal) : async Result<(), Text> {
        let result = ShopAPI.unregisterShopAs(shopApi, caller, AdminAPI.has(adminApi, caller, PlatformPermissions.shopsManage), canisterId);
        if (result == #ok) {
            forgetShopOrders(canisterId);
            ignore HistoryAPI.record(history, caller, ?canisterId, #shopUnregistered);
        };
        result;
    };

    /// Called by a Shop canister after updating its public details so the marketplace home list stays in sync.
    /// Every caller must attach `ShopCallFees.EVENT_CYCLES` once enforced (BRE-116).
    public shared ({ caller }) func syncShopDetails(event : ShopInterface.ShopDetailsUpdatedEvent) : async () {
        await* ShopCallFeesAPI.chargeOrReject<system>(callFees);
        ShopAPI.syncShopDetails(shopApi, caller, event);
    };

    /// Replaces a shop's slice of the marketplace product index with what the shop has now: core
    /// reads the shop's products a page at a time, sends each page to product_index, then removes the
    /// products the shop no longer has (BRE-97). Needs `Shops.Manage`: a sync costs core cycles for
    /// each page (up to `MAX_SYNC_PAGES`), so a shop calling it on itself could repeat it for free (BRE-118).
    public shared ({ caller }) func syncShopProducts(
        shopId : Principal
    ) : async Result<ShopAPI.SyncShopProductsResult, ShopAPI.SyncShopProductsError> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.shopsManage)) {
            return #err(#Unauthorized);
        };
        await ShopAPI.syncShopProducts(shopApi, shopId, productPages);
    };

    /// Called by a Shop canister after updating a product so the marketplace index stays in sync.
    /// Every caller must attach `ShopCallFees.EVENT_CYCLES` once enforced (BRE-116).
    public shared ({ caller }) func syncUpdatedProduct(
        event : ShopInterface.ProductUpdatedEvent
    ) : async () {
        await* ShopCallFeesAPI.chargeOrReject<system>(callFees);
        await ShopAPI.syncUpdatedProduct(shopApi, caller, event);
    };

    /// Called by a Shop canister after deleting a product so the marketplace index stays in sync.
    /// Every caller must attach `ShopCallFees.EVENT_CYCLES` once enforced (BRE-116).
    public shared ({ caller }) func syncDeletedProduct(
        event : ShopInterface.ProductDeletedEvent
    ) : async () {
        await* ShopCallFeesAPI.chargeOrReject<system>(callFees);
        await ShopAPI.syncDeletedProduct(shopApi, caller, event);
    };

    // Adds a shop the caller manages (e.g. one they were given access to). Idempotent.
    public shared ({ caller }) func addManagedShop(
        shopCanisterId : Principal
    ) : async ShopAPI.AddManagedShopResponse {
        ShopAPI.addManagedShop(shopApi, caller, shopCanisterId, func p = Map.has(userRegistry, Map.phash, p));
    };

    /// Shops the caller manages (owns or was given access to), for the user dashboard, a page at a
    /// time in canister ID order.
    public query ({ caller }) func getUserShops(after : ?Principal, limit : ?Nat) : async Pagination.Page<ShopAPI.UserShopInfo, Principal> {
        Pagination.page(ShopAPI.getUserShops(shopApi, caller), func(s : ShopAPI.UserShopInfo) : Principal = s.canisterId, Principal.compare, after, limit);
    };
};
