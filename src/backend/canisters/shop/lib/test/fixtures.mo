import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Set "mo:core/Set";

import Permissions "../../../../lib/Permissions";
import AuthService "../auth";
import ShopPermissions "../permissions";

/// A shop's access setup for tests: an Owner and an "Admin" role holding every permission, as the
/// migration seeds it, plus helpers that hand out access as the Owner.
module {
    public let ADMIN_ROLE : Permissions.RoleId = 1;

    public func newAuthService(owner : Principal) : AuthService.AuthService {
        let team = Permissions.newStore();
        ignore Permissions.seedRole(team, "Admin", ShopPermissions.catalog.map(func d = d.id));
        AuthService.AuthService({
            ownership = { var owner = ?owner };
            marketplacePrincipals = Set.empty();
            team;
        });
    };

    func ownerOf(authService : AuthService.AuthService) : Principal {
        authService.ownership.owner ?? Principal.anonymous();
    };

    public func grantAdmin(authService : AuthService.AuthService, principal : Principal) {
        ignore authService.team.assign(ownerOf(authService), principal, ADMIN_ROLE);
    };

    public func revokeAdmin(authService : AuthService.AuthService, principal : Principal) {
        ignore authService.team.unassign(ownerOf(authService), principal, ADMIN_ROLE);
    };

    /// Creates a role named `name` with `permissions` and assigns it to `principal`.
    public func grantRole(authService : AuthService.AuthService, principal : Principal, name : Text, permissions : [Permissions.PermissionId]) {
        switch (authService.team.createRole(ownerOf(authService), name, permissions)) {
            case (#ok(id)) ignore authService.team.assign(ownerOf(authService), principal, id);
            case (#err(_)) {};
        };
    };

    public func grantMarketplace(authService : AuthService.AuthService, principal : Principal) {
        ignore AuthService.grantMarketplace(authService, ownerOf(authService), principal);
    };

    public func revokeMarketplace(authService : AuthService.AuthService, principal : Principal) {
        ignore AuthService.revokeMarketplace(authService, ownerOf(authService), principal);
    };
};
