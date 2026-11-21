import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import Map "mo:map/Map";

/// Who may subscribe to a shop's events, and how many may (BRE-67). Generic over the listener type
/// so `pubsub.mo` uses it for every event; kept apart from it so tests needn't import `../types`.
module Subscriptions {
    public type SubscribeError = {
        /// The caller isn't allowed to receive this shop's events.
        #Unauthorized : Text;
        /// The event already has `MAX_SUBSCRIBERS_PER_EVENT` subscribers.
        #TooManySubscribers : Text;
    };

    /// Every event sends one call to each subscriber, paid in the shop's cycles, so the count is
    /// capped. Core takes one slot per event.
    public let MAX_SUBSCRIBERS_PER_EVENT : Nat = 10;

    /// `isAllowed`, except that the anonymous principal never is.
    public func canSubscribe(isAllowed : Principal -> Bool, principal : Principal) : Bool {
        not Principal.isAnonymous(principal) and isAllowed(principal);
    };

    /// Adds or replaces `caller`'s listener. Replacing one doesn't count against the cap.
    public func subscribe<L>(
        subscribers : Map.Map<Principal, L>,
        isAllowed : Principal -> Bool,
        event : Text,
        caller : Principal,
        listener : L,
    ) : Result<(), SubscribeError> {
        if (not canSubscribe(isAllowed, caller)) {
            return #err(#Unauthorized("Only the shop's controllers, Owner, Admins or Marketplace may subscribe to its events"));
        };
        if (not Map.has(subscribers, Map.phash, caller) and Map.size(subscribers) >= MAX_SUBSCRIBERS_PER_EVENT) {
            return #err(#TooManySubscribers(event # " already has " # Nat.toText(MAX_SUBSCRIBERS_PER_EVENT) # " subscribers"));
        };
        Map.set(subscribers, Map.phash, caller, listener);
        #ok;
    };

    /// Whether `principal` is subscribed and still allowed: one that isn't would be removed, not
    /// notified, at the next event.
    public func isSubscribed<L>(
        subscribers : Map.Map<Principal, L>,
        isAllowed : Principal -> Bool,
        principal : Principal,
    ) : Bool {
        Map.has(subscribers, Map.phash, principal) and canSubscribe(isAllowed, principal);
    };

    /// The subscribers still allowed to receive events. Removes the others and logs each removal,
    /// so a subscriber that lost its role (or one added before BRE-67) is never notified.
    public func allowed<L>(
        subscribers : Map.Map<Principal, L>,
        isAllowed : Principal -> Bool,
        event : Text,
        log : Text -> (),
    ) : [(Principal, L)] {
        let all = Map.toArray(subscribers);
        let kept = Array.filter<(Principal, L)>(all, func((p, _)) = canSubscribe(isAllowed, p));
        if (kept.size() < all.size()) {
            for ((p, _) in all.vals()) {
                if (not canSubscribe(isAllowed, p)) {
                    Map.delete(subscribers, Map.phash, p);
                    log("Removed " # event # " subscriber " # Principal.toText(p) # ": no longer allowed");
                };
            };
        };
        kept;
    };
};
