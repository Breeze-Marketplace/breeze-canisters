import Array "mo:core/Array";
import Map "mo:map/Map";

/// Role storage and checks shared by shop and canister_factory. Each canister keeps its own role variant
/// (its stable `rolesByPrincipal` type) and its own policy for who may grant or revoke a role: shop hands
/// `#Owner` over to the new owner, while the factory can have several owners.
module {
    public type Roles<R> = Map.Map<Principal, [R]>;

    /// Checks and updates over `roles`. `ownerRole` implies every other role. Build it as a `transient let`.
    public class Rbac<R>(roles : Roles<R>, equal : (R, R) -> Bool, ownerRole : R) {
        public func rolesOf(principal : Principal) : [R] {
            Map.get(roles, Map.phash, principal) ?? [];
        };

        public func hasRole(principal : Principal, role : R) : Bool {
            rolesOf(principal).any(func r = equal(r, role) or equal(r, ownerRole));
        };

        public func hasAnyRole(principal : Principal, allowed : [R]) : Bool {
            allowed.any(func role = hasRole(principal, role));
        };

        /// Whether any principal holds `ownerRole`.
        public func ownerIsSet() : Bool {
            for ((_, held) in Map.entries(roles)) {
                if (held.any(func r = equal(r, ownerRole))) {
                    return true;
                };
            };
            false;
        };

        /// Adds `role` to the principal's roles; a no-op when it is already held.
        public func add(principal : Principal, role : R) {
            let held = rolesOf(principal);
            if (held.any(func r = equal(r, role))) {
                return;
            };
            Map.set(roles, Map.phash, principal, held.concat([role]));
        };

        /// Replaces the principal's roles with `held`, dropping the entry when it is empty.
        public func set(principal : Principal, held : [R]) {
            if (held.size() == 0) {
                Map.delete(roles, Map.phash, principal);
            } else {
                Map.set(roles, Map.phash, principal, held);
            };
        };

        public func remove(principal : Principal, role : R) {
            set(principal, rolesOf(principal).filter(func r = not equal(r, role)));
        };
    };
};
