import List "mo:core/List";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";

import AdminAPI "../api/admin";
import Permissions "../../../lib/Permissions";

mixin (adminApi : AdminAPI.API) {
    /// Whether `principal` holds platform `permission` (`PlatformPermissions`). product_index,
    /// trust_safety and cycles_dispenser call this to authorize moderators, policy editors and cycles
    /// viewers (BRE-27, BRE-48, BRE-152, BRE-177); any other caller gets `false`.
    public shared ({ caller }) func hasPlatformPermission(principal : Principal, permission : Permissions.PermissionId) : async Bool {
        let trusted = List.empty<Principal>();
        switch (Runtime.envVar<system>("PUBLIC_CANISTER_ID:product_index")) {
            case (?id) trusted.add(Principal.fromText(id));
            case null {};
        };
        switch (Runtime.envVar<system>("PUBLIC_CANISTER_ID:trust_safety")) {
            case (?id) trusted.add(Principal.fromText(id));
            case null {};
        };
        switch (Runtime.envVar<system>("PUBLIC_CANISTER_ID:cycles_dispenser")) {
            case (?id) trusted.add(Principal.fromText(id));
            case null {};
        };
        AdminAPI.hasForCanister(adminApi, caller, trusted.toArray(), principal, permission);
    };
};
