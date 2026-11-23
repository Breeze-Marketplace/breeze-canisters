import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Time "mo:core/Time";
import Map "mo:map/Map";

import RateLimit "../../../lib/RateLimit";
import Types "../types";

mixin (
    userRegistry : Map.Map<Principal, Types.UserRegistryItem>,
    registrationBudget : RateLimit.Global,
    maxUsers : Nat,
    onUserRegistered : Principal -> (),
) {
    /// Registers the caller as a user in the system. Required before creating or managing shops.
    /// A principal costs nothing to make, so new registrations come out of a budget shared by all
    /// callers and stop at a hard cap (`#RateLimited`, BRE-120); an existing user is never refused.
    public shared ({ caller }) func createUser() : async Result<(), { #Unauthenticated; #UserAlreadyExists; #AnonymousOwner; #InsufficientCycles : Text; #RateLimited }> {
        if (caller.isAnonymous()) {
            return #err(#Unauthenticated);
        };
        if (Map.has(userRegistry, Map.phash, caller)) {
            return #err(#UserAlreadyExists);
        };
        let now = Time.now();
        if (Map.size(userRegistry) >= maxUsers or not RateLimit.takeGlobal(registrationBudget, now)) {
            return #err(#RateLimited);
        };
        Map.set(userRegistry, Map.phash, caller, { registrationDate = now });
        onUserRegistered(caller);
        #ok;
    };
};
