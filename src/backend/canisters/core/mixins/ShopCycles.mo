import Array "mo:core/Array";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Set "mo:core/Set";
import Map "mo:map/Map";

import HandoverAPI "../api/handover";
import ShopAPI "../api/shop";
import ShopCanistersAPI "../api/shop_canisters";
import ShopCyclesAPI "../api/shop_cycles";
import RateLimit "../../../lib/RateLimit";
import Types "../types";

/// Each shop's and vault's cycles and time left before it freezes, for the shop admin (BRE-13).
/// Merchants top up with ICP through the CMC from the frontend; core only reads balances.
mixin (
    shopRegistry : Map.Map<Principal, ShopAPI.ShopRegistryItem>,
    shopCanistersState : ShopCanistersAPI.State,
    shopCyclesState : ShopCyclesAPI.State,
    handoverState : HandoverAPI.State,
    userRegistry : Map.Map<Principal, Types.UserRegistryItem>,
    shopCyclesOps : ShopCyclesAPI.Operations,
    /// Canisters with a status read in flight, so concurrent refreshes don't read one twice.
    shopCyclesBusy : Set.Set<Principal>,
    /// What each user may make core read per hour (BRE-120).
    refreshQuota : RateLimit.PerCaller,
) {
    /// The shop canister and, when core knows it, its vault.
    func shopCanisters(shopId : Principal) : [(ShopCyclesAPI.ShopCanisterKind, Principal)] {
        switch (Map.get(shopCanistersState.vaultsByShop, Map.phash, shopId)) {
            case (?vaultId) [(#shop, shopId), (#vault, vaultId)];
            case null [(#shop, shopId)];
        };
    };

    func shopRunways(shopId : Principal) : [ShopCyclesAPI.CanisterRunway] {
        Array.map<(ShopCyclesAPI.ShopCanisterKind, Principal), ShopCyclesAPI.CanisterRunway>(
            shopCanisters(shopId),
            func((kind, id)) = ShopCyclesAPI.get(shopCyclesState, kind, id, HandoverAPI.isSelfManaged(handoverState, id)),
        );
    };

    /// The shop's and vault's balances and time left as of core's last reading (at most a day
    /// old). Anyone may call it: a shop's cycle balance is already public through its own
    /// `getCyclesBalance`.
    public query func getShopCycles(shopId : Principal) : async Result<[ShopCyclesAPI.CanisterRunway], { #NotFound }> {
        if (not Map.has(shopRegistry, Map.phash, shopId)) {
            return #err(#NotFound);
        };
        #ok(shopRunways(shopId));
    };

    /// Reads the shop's and vault's balances again (after a top-up, say) and returns them as
    /// `getShopCycles` does. Registered users only, and a canister read in the last 5 minutes isn't
    /// read again. Each user may also trigger at most 20 reads an hour (a shop and its
    /// vault are two), else `#RateLimited`, so no one can sweep every shop. No owner
    /// check: the result is public anyway (see `getShopCycles`).
    public shared ({ caller }) func refreshShopCycles(shopId : Principal) : async Result<[ShopCyclesAPI.CanisterRunway], { #Unauthorized; #NotFound; #RateLimited }> {
        if (caller.isAnonymous() or not Map.has(userRegistry, Map.phash, caller)) {
            return #err(#Unauthorized);
        };
        if (not Map.has(shopRegistry, Map.phash, shopId)) {
            return #err(#NotFound);
        };
        let now = shopCyclesOps.now();
        let stale = Array.filterMap<(ShopCyclesAPI.ShopCanisterKind, Principal), Principal>(
            shopCanisters(shopId),
            // Self-managed canisters (BRE-79) are skipped: core is no longer their controller.
            func((_, id)) = if (ShopCyclesAPI.isStale(shopCyclesState, id, now) and not shopCyclesBusy.contains(Principal.compare, id) and not HandoverAPI.isSelfManaged(handoverState, id)) ?id else null,
        );
        // Reserved before the first await; the reads happen even if they fail.
        if (stale.size() > 0 and not RateLimit.take(refreshQuota, caller, stale.size(), now)) {
            return #err(#RateLimited);
        };
        for (id in stale.vals()) { shopCyclesBusy.add(Principal.compare, id) };
        try {
            // Failures leave the previous reading in place; the daily sample logs them.
            ignore await* ShopCyclesAPI.sample(shopCyclesState, shopCyclesOps, stale);
        } finally {
            for (id in stale.vals()) {
                shopCyclesBusy.remove(Principal.compare, id);
            };
        };
        #ok(shopRunways(shopId));
    };
};
