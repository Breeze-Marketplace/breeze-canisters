import Error "mo:core/Error";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Set "mo:core/Set";

import Management "../../../../interfaces/management";

/// Handing a shop and its vault over to a principal the merchant controls (BRE-79).
///
/// Core is the only controller of every shop it creates and of the shop's vault. A handover makes
/// another principal their controller instead, in two steps so a mistyped principal can't lock
/// anyone out:
///
/// 1. `start`: the shop's owner names the new controller. Core adds it as a controller of the vault
///    and the shop, next to core. The owner (or the new controller) can `cancel` until step 2.
/// 2. `confirm`: the new controller itself calls core, which proves the principal is real and in the
///    merchant's hands. Core then makes it the only controller of the vault, then of the shop, and
///    records the shop as self-managed. Core never upgrades, restores or starts a self-managed shop
///    or vault again.
///
/// `handBack` undoes it: once the merchant has made core a controller of both canisters again, core
/// manages the shop again.
///
/// Every step that calls the management canister locks the shop and the vault in `busy`, the set
/// `api/upgrades` uses, so a handover and an upgrade of the same canister never overlap.
module {
    public type Pending = {
        controller : Principal;
        vaultId : Principal;
        startedAt : Int;
        /// `confirm` already made `controller` the vault's only controller, but the shop's update
        /// failed. A retried `confirm` skips the vault, and `cancel` is refused: core can't take the
        /// vault back.
        vaultReleased : Bool;
    };

    public type SelfManaged = {
        controller : Principal;
        vaultId : Principal;
        since : Int;
    };

    public type State = {
        /// Handovers started and not yet confirmed or cancelled, by shop canister ID.
        pending : Map.Map<Principal, Pending>;
        /// Shops (by shop canister ID) whose shop and vault core handed over.
        selfManaged : Map.Map<Principal, SelfManaged>;
    };

    /// Who controls a registered shop and its vault.
    public type ControlStatus = {
        /// Core (the normal case).
        #Managed;
        /// The owner started a handover to `controller`, which hasn't confirmed it yet. Core and
        /// `controller` both control the canisters.
        #HandoverPending : Pending;
        /// `controller` confirmed the handover: core no longer controls the shop or its vault.
        #SelfManaged : SelfManaged;
    };

    public type HandoverError = {
        /// The caller isn't the shop's owner (or, for `confirm`, the pending controller).
        #Unauthorized;
        /// Not a registered shop.
        #NotFound;
        /// Core doesn't know the shop's vault, so it can't hand both over together. An admin can link
        /// it (`linkShopVault`).
        #VaultUnknown;
        #InvalidController : Text;
        #AlreadyPending : { controller : Principal };
        #NoHandoverPending;
        #SelfManaged;
        #NotSelfManaged;
        /// An upgrade, restore, start or handover step of the shop or its vault hasn't finished.
        #UpgradeInProgress;
        /// The management canister refused to change the controllers.
        #UpdateFailed : Text;
        /// `handBack`: core isn't a controller of the shop or the vault yet.
        #CoreNotController : Text;
    };

    /// The management canister calls a handover makes, so tests can replace them.
    public type Ops = {
        setControllers : (canisterId : Principal, controllers : [Principal]) -> async ();
        controllers : (canisterId : Principal) -> async [Principal];
    };

    public type Deps = {
        state : State;
        /// Core's own principal.
        core : Principal;
        /// Shared with `api/upgrades`.
        busy : Set.Set<Principal>;
        /// The registry owner of a registered shop, or null if it isn't registered.
        ownerOf : (Principal) -> ?Principal;
        /// The vault core recorded for a shop.
        vaultOf : (Principal) -> ?Principal;
        /// Called once the handover is confirmed or handed back: core no longer knows (or, after a
        /// hand-back, can't be sure of) the wasm the canister runs.
        forgetVersion : (Principal) -> ();
        now : () -> Int;
        ops : Ops;
    };

    public func newState() : State {
        {
            pending = Map.empty<Principal, Pending>();
            selfManaged = Map.empty<Principal, SelfManaged>();
        };
    };

    public func status(state : State, shopId : Principal) : ControlStatus {
        switch (Map.get(state.selfManaged, Principal.compare, shopId)) {
            case (?s) { return #SelfManaged(s) };
            case (null) {};
        };
        switch (Map.get(state.pending, Principal.compare, shopId)) {
            case (?p) { #HandoverPending(p) };
            case (null) { #Managed };
        };
    };

    /// Whether core handed `canisterId` (a shop or a vault) over: `api/upgrades` must leave it alone.
    public func isSelfManaged(state : State, canisterId : Principal) : Bool {
        if (Map.containsKey(state.selfManaged, Principal.compare, canisterId)) {
            return true;
        };
        for (s in Map.values(state.selfManaged)) {
            if (s.vaultId == canisterId) { return true };
        };
        // A vault `confirm` already released, while the shop's update failed.
        for (p in Map.values(state.pending)) {
            if (p.vaultReleased and p.vaultId == canisterId) { return true };
        };
        false;
    };

    func lock(deps : Deps, ids : [Principal]) : Bool {
        for (id in ids.vals()) {
            if (Set.contains(deps.busy, Principal.compare, id)) { return false };
        };
        for (id in ids.vals()) { Set.add(deps.busy, Principal.compare, id) };
        true;
    };

    func unlock(deps : Deps, ids : [Principal]) {
        for (id in ids.vals()) { Set.remove(deps.busy, Principal.compare, id) };
    };

    func isOwner(deps : Deps, caller : Principal, shopId : Principal) : Result<(), HandoverError> {
        switch (deps.ownerOf(shopId)) {
            case (null) { #err(#NotFound) };
            case (?owner) {
                if (Principal.isAnonymous(caller) or caller != owner) {
                    #err(#Unauthorized);
                } else { #ok };
            };
        };
    };

    /// Step 1: adds `controller` as a controller of the shop's vault and the shop, next to core.
    /// Shop owner only. `controller` can't be the anonymous principal, core, the management
    /// canister, the shop or its vault, or the owner's own (Breeze sign-in) principal, which only
    /// works on the marketplace's frontend.
    public func start(deps : Deps, caller : Principal, shopId : Principal, controller : Principal) : async Result<(), HandoverError> {
        switch (isOwner(deps, caller, shopId)) {
            case (#err(e)) { return #err(e) };
            case (#ok) {};
        };
        switch (status(deps.state, shopId)) {
            case (#SelfManaged(_)) { return #err(#SelfManaged) };
            case (#HandoverPending(p)) {
                return #err(#AlreadyPending({ controller = p.controller }));
            };
            case (#Managed) {};
        };
        let vaultId = switch (deps.vaultOf(shopId)) {
            case (?v) { v };
            case (null) { return #err(#VaultUnknown) };
        };
        if (Principal.isAnonymous(controller)) {
            return #err(#InvalidController("The anonymous principal can't control a canister."));
        };
        if (controller == caller) {
            return #err(#InvalidController("That's the principal you sign in to Breeze with. It only works on the Breeze website, so you couldn't use it to manage your canisters. Use an icp identity or a wallet principal."));
        };
        if (
            controller == deps.core or controller == shopId or controller == vaultId or Principal.toText(controller) == "aaaaa-aa"
        ) {
            return #err(#InvalidController("Pick a principal you control, not one of the marketplace's canisters."));
        };
        if (not lock(deps, [shopId, vaultId])) {
            return #err(#UpgradeInProgress);
        };
        try {
            let both = [deps.core, controller];
            try {
                await deps.ops.setControllers(vaultId, both);
            } catch (e) {
                return #err(#UpdateFailed("vault: " # Error.message(e)));
            };
            try {
                await deps.ops.setControllers(shopId, both);
            } catch (e) {
                // Don't leave the vault handed over without its shop.
                try { await deps.ops.setControllers(vaultId, [deps.core]) } catch (_) {};
                return #err(#UpdateFailed("shop: " # Error.message(e)));
            };
            Map.add(
                deps.state.pending,
                Principal.compare,
                shopId,
                {
                    controller;
                    vaultId;
                    startedAt = deps.now();
                    vaultReleased = false;
                },
            );
            #ok;
        } finally {
            unlock(deps, [shopId, vaultId]);
        };
    };

    /// Step 2: the pending controller confirms. Core makes it the only controller of the vault, then
    /// of the shop, and marks the shop self-managed. Safe to retry after an `#UpdateFailed`.
    public func confirm(deps : Deps, caller : Principal, shopId : Principal) : async Result<SelfManaged, HandoverError> {
        let pending = switch (Map.get(deps.state.pending, Principal.compare, shopId)) {
            case (?p) { p };
            case (null) {
                return #err(if (Map.containsKey(deps.state.selfManaged, Principal.compare, shopId)) { #SelfManaged } else { #NoHandoverPending });
            };
        };
        if (Principal.isAnonymous(caller) or caller != pending.controller) {
            return #err(#Unauthorized);
        };
        let { vaultId; controller } = pending;
        if (not lock(deps, [shopId, vaultId])) {
            return #err(#UpgradeInProgress);
        };
        try {
            if (not pending.vaultReleased) {
                try {
                    await deps.ops.setControllers(vaultId, [controller]);
                } catch (e) {
                    return #err(#UpdateFailed("vault: " # Error.message(e)));
                };
                // The lock keeps `cancel` and other confirms out, so the entry is still ours.
                Map.add(deps.state.pending, Principal.compare, shopId, { pending with vaultReleased = true });
            };
            try {
                await deps.ops.setControllers(shopId, [controller]);
            } catch (e) {
                return #err(#UpdateFailed("shop: " # Error.message(e) # " The vault is already handed over; call confirmShopHandover again to finish."));
            };
            let done : SelfManaged = { controller; vaultId; since = deps.now() };
            Map.remove(deps.state.pending, Principal.compare, shopId);
            Map.add(deps.state.selfManaged, Principal.compare, shopId, done);
            deps.forgetVersion(shopId);
            deps.forgetVersion(vaultId);
            #ok(done);
        } finally {
            unlock(deps, [shopId, vaultId]);
        };
    };

    /// Cancels a pending handover: core becomes the only controller of the shop and the vault again.
    /// The shop owner or the pending controller. Refused once `confirm` released the vault.
    public func cancel(deps : Deps, caller : Principal, shopId : Principal) : async Result<(), HandoverError> {
        let pending = switch (Map.get(deps.state.pending, Principal.compare, shopId)) {
            case (?p) { p };
            case (null) { return #err(#NoHandoverPending) };
        };
        let isPendingController = caller == pending.controller and not Principal.isAnonymous(caller);
        if (not isPendingController) {
            switch (isOwner(deps, caller, shopId)) {
                case (#err(e)) { return #err(e) };
                case (#ok) {};
            };
        };
        if (pending.vaultReleased) {
            return #err(#UpdateFailed("The vault is already handed over. The new controller must call confirmShopHandover to finish."));
        };
        let { vaultId } = pending;
        if (not lock(deps, [shopId, vaultId])) {
            return #err(#UpgradeInProgress);
        };
        try {
            // Shop first: should the vault's update then fail, a retry still finds the entry.
            try {
                await deps.ops.setControllers(shopId, [deps.core]);
                await deps.ops.setControllers(vaultId, [deps.core]);
            } catch (e) {
                return #err(#UpdateFailed(Error.message(e)));
            };
            Map.remove(deps.state.pending, Principal.compare, shopId);
            #ok;
        } finally {
            unlock(deps, [shopId, vaultId]);
        };
    };

    /// Hands a self-managed shop back to core, once the merchant has added core as a controller of
    /// both the shop and its vault (core checks with `canister_status`). The merchant's principal
    /// stays a controller until they remove it. The shop owner or the self-managed controller.
    public func handBack(deps : Deps, caller : Principal, shopId : Principal) : async Result<(), HandoverError> {
        let managed = switch (Map.get(deps.state.selfManaged, Principal.compare, shopId)) {
            case (?s) { s };
            case (null) { return #err(#NotSelfManaged) };
        };
        let isController = caller == managed.controller and not Principal.isAnonymous(caller);
        if (not isController) {
            switch (isOwner(deps, caller, shopId)) {
                case (#err(e)) { return #err(e) };
                case (#ok) {};
            };
        };
        let { vaultId } = managed;
        if (not lock(deps, [shopId, vaultId])) {
            return #err(#UpgradeInProgress);
        };
        try {
            for ((which, id) in [("shop", shopId), ("vault", vaultId)].vals()) {
                let controllers = try { await deps.ops.controllers(id) } catch (e) {
                    return #err(#CoreNotController(which # ": " # Error.message(e)));
                };
                if (not hasPrincipal(controllers, deps.core)) {
                    return #err(#CoreNotController(which # ": add core as a controller first."));
                };
            };
            Map.remove(deps.state.selfManaged, Principal.compare, shopId);
            deps.forgetVersion(shopId);
            deps.forgetVersion(vaultId);
            #ok;
        } finally {
            unlock(deps, [shopId, vaultId]);
        };
    };

    func hasPrincipal(ps : [Principal], p : Principal) : Bool {
        for (x in ps.vals()) { if (x == p) { return true } };
        false;
    };

    /// `update_settings` with an awaited reply (the shared `Management` interface declares it
    /// one-way), and the controllers from `canister_status`.
    public func managementOps() : Ops {
        let ic = actor "aaaaa-aa" : actor {
            update_settings : ({
                canister_id : Principal;
                settings : Management.CanisterSettings;
                sender_canister_version : ?Nat64;
            }) -> async ();
            canister_status : ({ canister_id : Principal }) -> async ({
                settings : { controllers : [Principal] };
            });
        };
        {
            setControllers = func(canister_id : Principal, controllers : [Principal]) : async () {
                await ic.update_settings({
                    canister_id;
                    settings = {
                        controllers = ?controllers;
                        compute_allocation = null;
                        memory_allocation = null;
                        freezing_threshold = null;
                    };
                    sender_canister_version = null;
                });
            };
            controllers = func(canister_id : Principal) : async [Principal] {
                (await ic.canister_status({ canister_id })).settings.controllers;
            };
        };
    };
};
