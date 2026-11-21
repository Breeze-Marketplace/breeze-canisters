import Set "mo:core/Set";

// Adds the IDs of settled shop creation quotes whose deposit account the admin balances view
// found empty, so it stops reading them (BRE-101). Starts empty: the first read after the upgrade
// fills it.
module {
    type OldActor = {};

    type NewActor = {
        emptyQuoteDeposits : Set.Set<Nat>;
    };

    public func migration(_ : OldActor) : NewActor {
        { emptyQuoteDeposits = Set.empty<Nat>() };
    };
};
