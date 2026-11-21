import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Set "mo:core/Set";
import Time "mo:core/Time";
import Map "mo:map/Map";

import HandoverAPI "../api/handover";
import ShopAPI "../api/shop";
import ShopCanistersAPI "../api/shop_canisters";
import HistoryAPI "../api/history";

/// Merchants taking control of their shop and vault canisters (BRE-79; see `api/handover`).
mixin (
    handoverState : HandoverAPI.State,
    shopCanistersState : ShopCanistersAPI.State,
    shopRegistry : Map.Map<Principal, ShopAPI.ShopRegistryItem>,
    upgradesBusy : Set.Set<Principal>,
    history : HistoryAPI.State,
    coreId : Principal,
) {
    func handoverDeps() : HandoverAPI.Deps {
        {
            state = handoverState;
            core = coreId;
            busy = upgradesBusy;
            ownerOf = func(shopId : Principal) : ?Principal {
                switch (Map.get(shopRegistry, Map.phash, shopId)) {
                    case (?item) { ?item.owner };
                    case (null) { null };
                };
            };
            vaultOf = func(shopId : Principal) : ?Principal {
                Map.get(shopCanistersState.vaultsByShop, Map.phash, shopId);
            };
            forgetVersion = func(id : Principal) {
                ShopCanistersAPI.forgetVersion(shopCanistersState, id);
            };
            now = Time.now;
            ops = HandoverAPI.managementOps();
        };
    };

    /// Who controls a registered shop and its vault: core, core and a pending new controller, or
    /// the merchant's own principal. Public: a canister's controllers are public on the IC anyway.
    public query func getShopControl(shopId : Principal) : async Result<HandoverAPI.ControlStatus, { #NotFound }> {
        if (not Map.has(shopRegistry, Map.phash, shopId)) {
            return #err(#NotFound);
        };
        #ok(HandoverAPI.status(handoverState, shopId));
    };

    /// Starts handing the shop and its vault over to `controller`, a principal the merchant
    /// controls (an `icp identity` or a wallet; not their Breeze sign-in). Core adds it as a
    /// controller of both, next to core, and nothing more happens until `controller` itself calls
    /// `confirmShopHandover`. Shop owner only.
    public shared ({ caller }) func startShopHandover(shopId : Principal, controller : Principal) : async Result<(), HandoverAPI.HandoverError> {
        let result = await HandoverAPI.start(handoverDeps(), caller, shopId, controller);
        if (result == #ok) ignore HistoryAPI.record(history, caller, ?shopId, #handoverStarted({ controller }));
        result;
    };

    /// Finishes a handover: called by the new controller itself, which proves the principal is in
    /// the merchant's hands. Core removes itself as a controller of the vault and the shop, and
    /// stops upgrading them. Retry after `#UpdateFailed`.
    public shared ({ caller }) func confirmShopHandover(shopId : Principal) : async Result<HandoverAPI.SelfManaged, HandoverAPI.HandoverError> {
        let result = await HandoverAPI.confirm(handoverDeps(), caller, shopId);
        switch (result) {
            case (#ok(_)) ignore HistoryAPI.record(history, caller, ?shopId, #handoverConfirmed);
            case (#err(_)) {};
        };
        result;
    };

    /// Cancels a pending handover: core is again the only controller of the shop and its vault.
    /// The shop owner or the pending controller.
    public shared ({ caller }) func cancelShopHandover(shopId : Principal) : async Result<(), HandoverAPI.HandoverError> {
        let result = await HandoverAPI.cancel(handoverDeps(), caller, shopId);
        if (result == #ok) ignore HistoryAPI.record(history, caller, ?shopId, #handoverCancelled);
        result;
    };

    /// Lets core manage a self-managed shop again, once the merchant has added core back as a
    /// controller of the shop and its vault. The shop owner or the self-managed controller.
    public shared ({ caller }) func handBackShop(shopId : Principal) : async Result<(), HandoverAPI.HandoverError> {
        let result = await HandoverAPI.handBack(handoverDeps(), caller, shopId);
        if (result == #ok) ignore HistoryAPI.record(history, caller, ?shopId, #handedBack);
        result;
    };
};
