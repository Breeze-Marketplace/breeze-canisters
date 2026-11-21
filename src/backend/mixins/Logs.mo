import { type Result } "mo:core/Result";

import Logger "../lib/Logger";

/// Public `getLogs` endpoint over the including canister's in-memory logger. The canister decides
/// who may read its logs through `isAuthorized` (core: marketplace admins; shop: controllers and
/// its Owner and Admins).
mixin (logState : Logger.Logger, isAuthorized : (caller : Principal) -> Bool) {
    /// This canister's recent log entries, newest first (at most `limit`, capped at
    /// `Logger.MAX_LOGS`). Whether they survive an upgrade depends on the canister: shop keeps its
    /// log in stable state, core's is transient and an upgrade clears it. Authorized callers only.
    public query ({ caller }) func getLogs(limit : ?Nat) : async Result<[Logger.Log], { #Unauthorized }> {
        if (not isAuthorized(caller)) {
            return #err(#Unauthorized);
        };
        #ok(Logger.recent(logState, limit));
    };
};
