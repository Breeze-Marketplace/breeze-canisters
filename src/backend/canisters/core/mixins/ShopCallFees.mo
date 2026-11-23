import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import ShopFees "../../../lib/ShopCallFees";
import ShopCallFeesAPI "../api/shop_call_fees";
import HistoryAPI "../api/history";

/// Whether shops must attach cycles to the events they send core (BRE-116).
mixin (callFees : ShopCallFeesAPI.State, history : HistoryAPI.State) {
    /// Turns the fees on or off. Controllers only. Turn them on once the shop version that attaches
    /// cycles is published, every hosted shop runs it and self-managed merchants have had time to install it:
    /// core refuses events from older shops, so their products and orders stop syncing.
    public shared ({ caller }) func setShopCallFeesEnforced(enforced : Bool) : async Result<(), { #Unauthorized }> {
        if (not Principal.isController(caller)) {
            return #err(#Unauthorized);
        };
        callFees.enforced := enforced;
        ignore HistoryAPI.record(history, caller, null, #shopCallFeesEnforcedSet({ enforced }));
        #ok;
    };

    /// Whether the fees are on, and the cycles each event from a shop must carry.
    public query func getShopCallFees() : async {
        enforced : Bool;
        eventCycles : Nat;
    } {
        { enforced = callFees.enforced; eventCycles = ShopFees.EVENT_CYCLES };
    };
};
