import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import Logger "../lib/Logger";
import Pagination "../lib/Pagination";
import Permissions "../lib/Permissions";

/// Public team endpoints over the including canister's `Permissions.Access`: its permission catalog,
/// the caller's own permissions, and roles and members. The engine checks `Team.View`,
/// `Team.AssignRoles` and `Team.EditRoles`, and that nobody but the superuser hands out, edits or
/// takes away permissions they don't hold.
/// `onChange` hears about every change that succeeds, after it's made.
mixin (team : Permissions.Access, logger : Logger.BoundLogger, onChange : (caller : Principal, change : Permissions.TeamChange) -> ()) {
    /// The permissions roles can be made of, with what each includes. Public: it's the same for every caller.
    public query func getPermissionCatalog() : async [Permissions.PermissionDef] {
        team.permissionCatalog();
    };

    /// The caller's own roles and effective permissions. Needs no permission: it shows only the caller's own.
    public query ({ caller }) func getMyPermissions() : async Permissions.MyPermissions {
        team.myPermissions(caller);
    };

    /// Roles in ID order. Needs `Team.View`.
    public query ({ caller }) func listRoles(after : ?Permissions.RoleId, limit : ?Nat) : async Result<Pagination.Page<Permissions.RoleView, Permissions.RoleId>, Permissions.Error> {
        team.pageRoles(caller, after, limit);
    };

    /// Members (principals with at least one role) in principal order. Needs `Team.View`.
    public query ({ caller }) func listMembers(after : ?Principal, limit : ?Nat) : async Result<Pagination.Page<Permissions.Member, Principal>, Permissions.Error> {
        team.pageMembers(caller, after, limit);
    };

    /// Needs `Team.EditRoles` and every permission in the role.
    public shared ({ caller }) func createRole(name : Text, permissions : [Permissions.PermissionId]) : async Result<Permissions.RoleId, Permissions.Error> {
        let result = team.createRole(caller, name, permissions);
        switch (result) {
            case (#ok(id)) {
                logger.info("Created role " # debug_show (id) # " \"" # name # "\" with " # debug_show (permissions) # " (by " # caller.toText() # ")");
                onChange(caller, #roleCreated({ roleId = id; name; permissions }));
            };
            case (#err(_)) {};
        };
        result;
    };

    /// Needs `Team.EditRoles` and every permission in the role before and after.
    public shared ({ caller }) func updateRole(id : Permissions.RoleId, name : Text, permissions : [Permissions.PermissionId]) : async Result<(), Permissions.Error> {
        let result = team.updateRole(caller, id, name, permissions);
        if (result == #ok) {
            logger.info("Updated role " # debug_show (id) # " to \"" # name # "\" with " # debug_show (permissions) # " (by " # caller.toText() # ")");
            onChange(caller, #roleUpdated({ roleId = id; name; permissions }));
        };
        result;
    };

    /// Deletes the role and takes it from its members. Needs `Team.EditRoles` and every permission in the role.
    public shared ({ caller }) func deleteRole(id : Permissions.RoleId) : async Result<(), Permissions.Error> {
        let result = team.deleteRole(caller, id);
        if (result == #ok) {
            logger.info("Deleted role " # debug_show (id) # " (by " # caller.toText() # ")");
            onChange(caller, #roleDeleted({ roleId = id }));
        };
        result;
    };

    /// Needs `Team.AssignRoles` and every permission in the role.
    public shared ({ caller }) func assignRole(principal : Principal, id : Permissions.RoleId) : async Result<(), Permissions.Error> {
        let result = team.assign(caller, principal, id);
        if (result == #ok) {
            logger.info("Assigned role " # debug_show (id) # " to " # principal.toText() # " (by " # caller.toText() # ")");
            onChange(caller, #roleAssigned({ principal; roleId = id }));
        };
        result;
    };

    /// Needs `Team.AssignRoles` and every permission in the role.
    public shared ({ caller }) func unassignRole(principal : Principal, id : Permissions.RoleId) : async Result<(), Permissions.Error> {
        let result = team.unassign(caller, principal, id);
        if (result == #ok) {
            logger.info("Unassigned role " # debug_show (id) # " from " # principal.toText() # " (by " # caller.toText() # ")");
            onChange(caller, #roleUnassigned({ principal; roleId = id }));
        };
        result;
    };
};
