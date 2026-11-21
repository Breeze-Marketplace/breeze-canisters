import Principal "mo:core/Principal";
import Map "mo:map/Map";

/// Moderator authorization (BRE-27, BRE-152), shared by product_index and trust_safety. A canister's own
/// list (its `initArgs.moderators` plus the deployer) may do every moderation action; anyone else needs the
/// platform permission (`PlatformPermissions`) according to core. Core stays the only source of truth for
/// its team, so a role change there takes effect in every canister without any sync.
module {
    /// Asks core whether a principal holds a platform permission.
    public type AskCore = (Principal, Text) -> async* Bool;

    type CoreTeamActor = actor {
        hasPlatformPermission : shared (Principal, Text) -> async Bool;
    };

    /// Core's `hasPlatformPermission`. Core answers only the canisters it trusts (product_index, trust_safety).
    public func askCore(coreId : Principal) : AskCore {
        let core : CoreTeamActor = actor (coreId.toText());
        func(p : Principal, permission : Text) : async* Bool {
            // Bounded wait, so a stuck core can't block upgrades of the calling canister.
            await (with timeout = 30) core.hasPlatformPermission(p, permission);
        };
    };

    /// Whether `caller` is on the local moderator list or holds `permission` in core.
    public func isModerator(moderators : Map.Map<Principal, ()>, caller : Principal, permission : Text, askCore : ?AskCore) : async* Bool {
        if (Principal.isAnonymous(caller)) {
            return false;
        };
        if (Map.has(moderators, Map.phash, caller)) {
            return true;
        };
        await* hasPlatformPermission(caller, permission, askCore);
    };

    /// Whether core says `caller` holds `permission`, ignoring any local moderator list.
    public func hasPlatformPermission(caller : Principal, permission : Text, askCore : ?AskCore) : async* Bool {
        if (Principal.isAnonymous(caller)) {
            return false;
        };
        switch (askCore) {
            case null { false };
            // Fail closed: if core can't answer, the caller holds nothing.
            case (?ask) {
                try { await* ask(caller, permission) } catch (_) { false };
            };
        };
    };
};
