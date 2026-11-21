import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import ShopFees "../../../lib/ShopCallFees";
import ShopCallFeesAPI "../api/shop_call_fees";
import HistoryAPI "../api/history";

/// Whether shops core doesn't host must attach cycles to their events (BRE-116).
mixin (callFees : ShopCallFeesAPI.State, history : HistoryAPI.State) {
    /// Turns the fees on or off. Controllers only. Turn them on once the shop version that attaches
    /// cycles is published and self-managed merchants have had time to install it: until then core
    /// refuses their events, so their products and orders stop syncing.
    public shared ({ caller }) func setShopCallFeesEnforced(enforced : Bool) : async Result<(), { #Unauthorized }> {
        if (not Principal.isController(caller)) {
            return #err(#Unauthorized);
        };
        callFees.enforced := enforced;
        ignore HistoryAPI.record(history, caller, null, #shopCallFeesEnforcedSet({ enforced }));
        #ok;
    };

    /// Whether the fees are on, and the cycles each event from a shop core doesn't host must carry.
    public query func getShopCallFees() : async {
        enforced : Bool;
        eventCycles : Nat;
    } {
        { enforced = callFees.enforced; eventCycles = ShopFees.EVENT_CYCLES };
    };
};
