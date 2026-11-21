import Map "mo:core/Map";

// Adds core's sampled shop and vault cycle balances (BRE-13). Empty: the first sample runs a minute
// after the upgrade.
module {
    type Sample = {
        time : Int;
        cycles : Nat;
    };

    type Tracker = {
        latest : Sample;
        freezingThresholdCycles : Nat;
        idleBurnPerDay : Nat;
        base : Sample;
        measuredBurnPerDay : ?Nat;
    };

    type OldActor = {};

    type NewActor = {
        shopCyclesState : { trackers : Map.Map<Principal, Tracker> };
    };

    public func migration(_ : OldActor) : NewActor {
        { shopCyclesState = { trackers = Map.empty<Principal, Tracker>() } };
    };
};
