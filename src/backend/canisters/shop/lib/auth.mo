import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Set "mo:core/Set";

import Permissions "../../../lib/Permissions";
import ShopPermissions "permissions";

/// Who may do what in a shop (BRE-151). The Owner holds every permission and alone may move money,
/// set payment and delivery secrets, hand over ownership and grant Marketplace access. Everyone else
/// gets permissions through team roles (`lib/Permissions`). Marketplace principals (core) may
/// subscribe to events and see a private location; that's a system grant, not a role.
module AuthService {
    public type Ownership = { var owner : ?Principal };

    public class AuthService(
        args : {
            ownership : Ownership;
            marketplacePrincipals : Set.Set<Principal>;
            team : Permissions.Store;
        }
    ) {
        public let ownership = args.ownership;
        public let marketplacePrincipals = args.marketplacePrincipals;
        public let team = Permissions.Access(
            args.team,
            ShopPermissions.catalog,
            func p = ownership.owner == ?p,
            ShopPermissions.limits,
        );
    };

    public func isOwner(authService : AuthService, principal : Principal) : Bool {
        not principal.isAnonymous() and authService.ownership.owner == ?principal;
    };

    public func isMarketplace(authService : AuthService, principal : Principal) : Bool {
        authService.marketplacePrincipals.contains(principal);
    };

    /// Whether `principal` holds `permission` (the Owner holds them all). Use `ShopPermissions` constants.
    public func hasPermission(authService : AuthService, principal : Principal, permission : Permissions.PermissionId) : Bool {
        authService.team.has(principal, permission);
    };

    /// Makes `principal` the Owner while there is none (first install). A no-op afterwards.
    public func initOwner(authService : AuthService, principal : Principal) {
        if (authService.ownership.owner == null) {
            authService.ownership.owner := ?principal;
        };
    };

    /// Hands ownership to `principal`: the caller stops being Owner, and `principal` loses its team
    /// roles (the Owner holds every permission anyway). Only the Owner may call.
    public func setOwner(authService : AuthService, caller : Principal, principal : Principal) : Result<(), { #Unauthorized : Text }> {
        if (not isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop's Owner can hand over ownership"));
        };
        if (principal.isAnonymous()) {
            return #err(#Unauthorized("The anonymous principal can't own a shop"));
        };
        authService.team.removeMember(principal);
        authService.ownership.owner := ?principal;
        #ok;
    };

    /// Lets `principal` (core) subscribe to events and see a private location. Owner only.
    public func grantMarketplace(authService : AuthService, caller : Principal, principal : Principal) : Result<(), { #Unauthorized : Text }> {
        if (not isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop's Owner can grant Marketplace access"));
        };
        if (principal.isAnonymous()) {
            return #err(#Unauthorized("The anonymous principal can't have Marketplace access"));
        };
        authService.marketplacePrincipals.add(principal);
        #ok;
    };

    public func revokeMarketplace(authService : AuthService, caller : Principal, principal : Principal) : Result<(), { #Unauthorized : Text }> {
        if (not isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop's Owner can revoke Marketplace access"));
        };
        authService.marketplacePrincipals.remove(principal);
        #ok;
    };
};
