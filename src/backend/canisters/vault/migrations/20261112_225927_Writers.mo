import Principal "mo:core/Principal";
import Set "mo:core/Set";
import Assets "mo:assets";

module {
    type OldActor = {
        var entries : Assets.SerializedEntries;
    };

    type NewActor = {
        var entries : Assets.SerializedEntries;
        writers : Set.Set<Principal>;
    };

    /// Moves the authorized list out of `mo:assets` into `writers`, without its repeats. The actor
    /// then gives `mo:assets` only its own principal.
    public func migration(old : OldActor) : NewActor {
        {
            var entries = old.entries;
            writers = Set.fromIter(old.entries.1.values(), Principal.compare);
        };
    };
};
