import Array "mo:core/Array";
import Principal "mo:core/Principal";

import Permissions "../../../../lib/Permissions";
import PlatformPermissions "../../../../lib/PlatformPermissions";

/// Platform staff (BRE-152): core's controllers are the superuser and hold every permission; everyone
/// else holds what their team roles give them (`PlatformPermissions`).
module {
    public type Dependencies = {
        team : Permissions.Store;
        isController : (Principal) -> Bool;
    };

    public class API(dependencies : Dependencies) {
        public let access = Permissions.Access(
            dependencies.team,
            PlatformPermissions.catalog,
            dependencies.isController,
            PlatformPermissions.limits,
        );
    };

    /// Whether `principal` holds `permission` (false for anonymous and for ids outside the catalog).
    public func has(api : API, principal : Principal, permission : Permissions.PermissionId) : Bool {
        api.access.has(principal, permission);
    };

    /// Answers whether `principal` holds `permission`, for the moderator and policy checks of
    /// product_index and trust_safety (BRE-27, BRE-48, BRE-152). Only `trustedCallers` get an answer,
    /// so who holds what stays as private as `listMembers` keeps it.
    public func hasForCanister(
        api : API,
        caller : Principal,
        trustedCallers : [Principal],
        principal : Principal,
        permission : Permissions.PermissionId,
    ) : Bool {
        if (not trustedCallers.any(func(p : Principal) : Bool = p == caller)) {
            return false;
        };
        has(api, principal, permission);
    };
};
