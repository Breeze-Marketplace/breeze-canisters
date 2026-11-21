import Map "mo:core/Map";
import Set "mo:core/Set";

// Order catch-up (BRE-203): how far core has read each shop's order log, and the orders it found
// there but couldn't read yet. Every shop starts with no cursor, so its first catch-up reads its
// whole log; applying events core already has is harmless.
module {
    type CatchUpState = {
        cursors : Map.Map<Principal, { last : ?{ seq : Nat; at : Int }; notified : ?{ seq : Nat; at : Int } }>;
        pending : Map.Map<Principal, Set.Set<Nat32>>;
    };

    public func migration(_ : {}) : { orderCatchUp : CatchUpState } {
        { orderCatchUp = { cursors = Map.empty(); pending = Map.empty() } };
    };
};
