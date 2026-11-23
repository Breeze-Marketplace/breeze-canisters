import Cycles "mo:core/Cycles";
import Error "mo:core/Error";

import ShopFees "../../../../lib/ShopCallFees";

/// Charging for the events shops send core (BRE-116). Anyone can call the event endpoints, so every
/// caller pays, hosted shops included: otherwise a shop, or a canister posing as one, could make core
/// spend cycles without limit.
module {
    public type State = {
        /// Off until every shop runs a version that attaches cycles, so deploying core doesn't cut
        /// older shops off.
        var enforced : Bool;
    };

    public func newState() : State { { var enforced = false } };

    /// The cycles core takes with each event: nothing while the fees aren't enforced.
    public func required(state : State) : Nat {
        if (state.enforced) ShopFees.EVENT_CYCLES else 0;
    };

    public type ChargeError = { #CyclesRequired : Nat };

    /// Takes the cycles `required` for an event from the call being served, or refuses it when
    /// the caller attached fewer. Cycles beyond that go back to the caller.
    public func charge<system>(state : State) : { #ok; #err : ChargeError } {
        let amount = required(state);
        if (amount == 0) {
            return #ok;
        };
        if (Cycles.available() < amount) {
            return #err(#CyclesRequired(amount));
        };
        ignore Cycles.accept<system>(amount);
        #ok;
    };

    /// Takes the cycles for an event, or throws so the shop logs that its event wasn't taken.
    public func chargeOrReject<system>(state : State) : async* () {
        switch (charge<system>(state)) {
            case (#ok) {};
            case (#err(#CyclesRequired(amount))) {
                throw Error.reject("Events sent to core must carry " # debug_show amount # " cycles");
            };
        };
    };
};
