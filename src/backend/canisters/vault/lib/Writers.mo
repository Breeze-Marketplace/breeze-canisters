import Iter "mo:core/Iter";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Set "mo:core/Set";

/// Who may write to the vault. `mo:assets` can't remove a principal from its own list, so the vault
/// keeps this set, checks it, and calls `mo:assets` as itself.
module {
    public type Writers = Set.Set<Principal>;

    public func isWriter(writers : Writers, p : Principal) : Bool = writers.contains(Principal.compare, p);

    /// Traps with the same message as `mo:assets`, which the frontend recognizes.
    public func require(writers : Writers, caller : Principal) {
        if (not isWriter(writers, caller)) {
            Runtime.trap("not authorized");
        };
    };

    public func add(writers : Writers, other : Principal) {
        if (other.isAnonymous()) {
            Runtime.trap("the anonymous principal can't be authorized");
        };
        writers.add(Principal.compare, other);
    };

    public type RemoveError = { #creator; #last };

    /// Refuses to remove the creator (core) or to leave nobody able to write.
    public func remove(writers : Writers, creator : Principal, other : Principal) : {
        #ok;
        #err : RemoveError;
    } {
        if (other == creator) return #err(#creator);
        if (isWriter(writers, other) and writers.size() == 1) return #err(#last);
        writers.remove(Principal.compare, other);
        #ok;
    };

    public func toArray(writers : Writers) : [Principal] = writers.values().toArray();
};
