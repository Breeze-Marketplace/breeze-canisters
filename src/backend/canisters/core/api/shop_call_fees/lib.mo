import Cycles "mo:core/Cycles";
import Map "mo:map/Map";

import ShopFees "../../../../lib/ShopCallFees";
import HandoverAPI "../handover";
import ShopCanistersAPI "../shop_canisters";

/// Charging shops that core doesn't host for the events they send it (BRE-116). A hosted shop runs
/// our code and core funds it, so charging it only moves cycles between our balances; any other
/// shop (handed over to its merchant, or registered with `registerShop`) runs code core can't vouch
/// for and could otherwise make core spend cycles without limit.
module {
    public type State = {
        /// Off until shops core doesn't host run a version that attaches cycles, so deploying core
        /// doesn't cut them off.
        var enforced : Bool;
    };

    public func newState() : State { { var enforced = false } };

    /// Whether core created and still controls `shopId`: it recorded an install or a vault for it
    /// and hasn't handed it over.
    public func isHosted(canisters : ShopCanistersAPI.State, handover : HandoverAPI.State, shopId : Principal) : Bool {
        let recorded = Map.has(canisters.wasmVersions, Map.phash, shopId) or Map.has(canisters.vaultsByShop, Map.phash, shopId);
        recorded and not HandoverAPI.isSelfManaged(handover, shopId);
    };

    /// The cycles core takes with an event from `shopId`: nothing for a hosted shop or while the
    /// fees aren't enforced.
    public func required(state : State, hosted : Bool) : Nat {
        if (state.enforced and not hosted) ShopFees.EVENT_CYCLES else 0;
    };

    public type ChargeError = { #CyclesRequired : Nat };

    /// Takes the cycles `required` for an event from the call being served, or refuses it when
    /// the caller attached fewer. Cycles beyond that go back to the caller.
    public func charge<system>(state : State, hosted : Bool) : { #ok; #err : ChargeError } {
        let amount = required(state, hosted);
        if (amount == 0) {
            return #ok;
        };
        if (Cycles.available() < amount) {
            return #err(#CyclesRequired(amount));
        };
        ignore Cycles.accept<system>(amount);
        #ok;
    };
};
