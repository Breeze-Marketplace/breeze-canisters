import Array "mo:core/Array";
import Iter "mo:core/Iter";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Text "mo:core/Text";

import Pagination "Pagination";

/// Role-based permissions shared by every canister with a team (shop now, core next, BRE-151/152).
/// A permission is a `"<Resource>.<Action>"` id from the canister's fixed catalog. Roles are named
/// sets of permissions; members hold roles. The superuser (shop: its Owner) holds every permission
/// whatever its roles; roles it holds take effect once it stops being the superuser (an owner who
/// hands the shop over and stays on the team). Nobody but the superuser can hand out, edit or take away a permission they
/// don't hold themselves, so the team permissions can't be used to escalate.
module Permissions {
    public type PermissionId = Text;
    public type RoleId = Nat;

    /// A catalog entry. `includes` names permissions of the same resource that come with this one
    /// (`Orders.Fulfill` includes `Orders.View`); includes don't chain.
    public type PermissionDef = { id : PermissionId; includes : [PermissionId] };

    public type Role = { name : Text; permissions : [PermissionId] };
    public type RoleView = {
        id : RoleId;
        name : Text;
        permissions : [PermissionId];
    };
    public type Member = { principal : Principal; roleIds : [RoleId] };

    /// Stable state: keep one per canister as a stable field.
    public type Store = {
        roles : Map.Map<RoleId, Role>;
        members : Map.Map<Principal, [RoleId]>;
        counter : { var nextRoleId : RoleId };
    };

    public type Limits = {
        maxRoles : Nat;
        maxMembers : Nat;
        maxRolesPerMember : Nat;
        maxNameLength : Nat;
    };

    public type Error = {
        #Unauthorized : Text;
        #NotFound : Text;
        #InputError : Text;
    };

    /// A change to the team, for a canister that keeps a history of them (core, BRE-153).
    public type TeamChange = {
        #roleCreated : {
            roleId : RoleId;
            name : Text;
            permissions : [PermissionId];
        };
        #roleUpdated : {
            roleId : RoleId;
            name : Text;
            permissions : [PermissionId];
        };
        #roleDeleted : { roleId : RoleId };
        #roleAssigned : { principal : Principal; roleId : RoleId };
        #roleUnassigned : { principal : Principal; roleId : RoleId };
    };

    /// The caller's own access, for the frontend to decide what to show.
    public type MyPermissions = {
        isSuperuser : Bool;
        roleIds : [RoleId];
        /// Effective permissions: roles' permissions plus their includes (every permission for the superuser).
        permissions : [PermissionId];
    };

    /// The team permissions every catalog must contain; the engine checks them itself.
    public let TEAM_VIEW = "Team.View";
    public let TEAM_ASSIGN_ROLES = "Team.AssignRoles";
    public let TEAM_EDIT_ROLES = "Team.EditRoles";

    public let teamCatalog : [PermissionDef] = [
        { id = TEAM_VIEW; includes = [] },
        { id = TEAM_ASSIGN_ROLES; includes = [TEAM_VIEW] },
        { id = TEAM_EDIT_ROLES; includes = [TEAM_VIEW] },
    ];

    public func newStore() : Store {
        {
            roles = Map.empty();
            members = Map.empty();
            counter = { var nextRoleId = 1 };
        };
    };

    /// Adds a role without any checks, for migrations and first install. Returns its ID.
    public func seedRole(store : Store, name : Text, permissions : [PermissionId]) : RoleId {
        let id = store.counter.nextRoleId;
        store.counter.nextRoleId += 1;
        store.roles.add(id, { name; permissions });
        id;
    };

    /// Assigns a role without any checks, for migrations.
    public func seedMember(store : Store, principal : Principal, roleId : RoleId) {
        let held = store.members.get(principal) ?? [];
        if (not held.contains(roleId)) {
            store.members.add(principal, held.concat([roleId]));
        };
    };

    /// The resource part of a permission id (`"Orders"` for `"Orders.Fulfill"`).
    public func resourceOf(id : PermissionId) : Text {
        id.split(#char '.').next() ?? id;
    };

    /// Problems with a catalog: duplicate ids, ids without a resource and action, missing team
    /// permissions, includes that are unknown, cross resources, or themselves include something.
    /// Empty when the catalog is valid; each canister's tests assert that.
    public func catalogProblems(catalog : [PermissionDef]) : [Text] {
        var problems : [Text] = [];
        func report(problem : Text) { problems := problems.concat([problem]) };
        func find(id : PermissionId) : ?PermissionDef = catalog.find(func d = d.id == id);

        for ((i, def) in catalog.enumerate()) {
            if (catalog.sliceToArray(0, i).any(func d = d.id == def.id)) {
                report("duplicate " # def.id);
            };
            let parts = def.id.split(#char '.').toArray();
            if (parts.size() != 2 or parts[0] == "" or parts[1] == "") {
                report(def.id # " is not <Resource>.<Action>");
            };
            for (inc in def.includes.values()) {
                switch (find(inc)) {
                    case null { report(def.id # " includes unknown " # inc) };
                    case (?included) {
                        if (resourceOf(inc) != resourceOf(def.id)) {
                            report(def.id # " includes " # inc # " from another resource");
                        };
                        if (included.includes.size() > 0) {
                            report(def.id # " includes " # inc # ", which includes more");
                        };
                    };
                };
            };
        };
        for (team in teamCatalog.values()) {
            if (find(team.id) == null) { report("missing " # team.id) };
        };
        problems;
    };

    public class Access(
        store : Store,
        catalog : [PermissionDef],
        isSuperuser : Principal -> Bool,
        limits : Limits,
    ) {
        public func permissionCatalog() : [PermissionDef] = catalog;

        func definition(id : PermissionId) : ?PermissionDef = catalog.find(func d = d.id == id);

        /// `ids` that are in the catalog plus what they include, without duplicates. Unknown ids (one a
        /// later version removed, say) grant nothing.
        func expand(ids : [PermissionId]) : [PermissionId] {
            var out : [PermissionId] = [];
            func add(id : PermissionId) {
                if (not out.contains(id)) { out := out.concat([id]) };
            };
            for (id in ids.values()) {
                switch (definition(id)) {
                    case (?def) {
                        add(id);
                        for (inc in def.includes.values()) { add(inc) };
                    };
                    case null {};
                };
            };
            out;
        };

        public func rolesOf(principal : Principal) : [RoleId] {
            store.members.get(principal) ?? [];
        };

        public func effectivePermissions(principal : Principal) : [PermissionId] {
            if (principal.isAnonymous()) return [];
            if (isSuperuser(principal)) return catalog.map(func d = d.id);
            var granted : [PermissionId] = [];
            for (roleId in rolesOf(principal).values()) {
                switch (store.roles.get(roleId)) {
                    case (?role) { granted := granted.concat(role.permissions) };
                    case null {};
                };
            };
            expand(granted);
        };

        public func has(principal : Principal, permission : PermissionId) : Bool {
            if (principal.isAnonymous()) return false;
            if (isSuperuser(principal)) return definition(permission) != null;
            effectivePermissions(principal).contains(permission);
        };

        public func myPermissions(principal : Principal) : MyPermissions {
            {
                isSuperuser = not principal.isAnonymous() and isSuperuser(principal);
                roleIds = rolesOf(principal);
                permissions = effectivePermissions(principal);
            };
        };

        /// Whether `caller` holds every permission in `ids` (with their includes).
        func holdsAll(caller : Principal, ids : [PermissionId]) : Bool {
            if (isSuperuser(caller)) return true;
            let held = effectivePermissions(caller);
            expand(ids).all(func id = held.contains(id));
        };

        func require(caller : Principal, permission : PermissionId) : Result<(), Error> {
            if (has(caller, permission)) #ok else #err(#Unauthorized("Requires " # permission));
        };

        func requireHolds(caller : Principal, ids : [PermissionId]) : Result<(), Error> {
            if (holdsAll(caller, ids)) #ok else #err(#Unauthorized("You can only manage roles with permissions you hold yourself"));
        };

        func getRole(id : RoleId) : Result<Role, Error> {
            switch (store.roles.get(id)) {
                case (?role) #ok(role);
                case null #err(#NotFound("No role " # id.toText()));
            };
        };

        /// The role with its name trimmed and its permissions de-duplicated, or why it's invalid.
        func validRole(name : Text, permissions : [PermissionId], self : ?RoleId) : Result<Role, Error> {
            let trimmed = name.trim(#char ' ');
            if (trimmed.size() == 0 or trimmed.size() > limits.maxNameLength) {
                return #err(#InputError("A role name has 1 to " # limits.maxNameLength.toText() # " characters"));
            };
            for ((id, role) in store.roles.entries()) {
                if (?id != self and role.name.toLower() == trimmed.toLower()) {
                    return #err(#InputError("A role named " # trimmed # " already exists"));
                };
            };
            var unique : [PermissionId] = [];
            for (p in permissions.values()) {
                if (definition(p) == null) return #err(#InputError("Unknown permission " # p));
                if (not unique.contains(p)) { unique := unique.concat([p]) };
            };
            #ok({ name = trimmed; permissions = unique });
        };

        public func createRole(caller : Principal, name : Text, permissions : [PermissionId]) : Result<RoleId, Error> {
            switch (require(caller, TEAM_EDIT_ROLES)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            let role = switch (validRole(name, permissions, null)) {
                case (#ok(r)) r;
                case (#err(e)) return #err(e);
            };
            switch (requireHolds(caller, role.permissions)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            if (store.roles.size() >= limits.maxRoles) {
                return #err(#InputError("A team has at most " # limits.maxRoles.toText() # " roles"));
            };
            #ok(seedRole(store, role.name, role.permissions));
        };

        public func updateRole(caller : Principal, id : RoleId, name : Text, permissions : [PermissionId]) : Result<(), Error> {
            switch (require(caller, TEAM_EDIT_ROLES)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            let old = switch (getRole(id)) {
                case (#ok(r)) r;
                case (#err(e)) return #err(e);
            };
            let role = switch (validRole(name, permissions, ?id)) {
                case (#ok(r)) r;
                case (#err(e)) return #err(e);
            };
            switch (requireHolds(caller, old.permissions.concat(role.permissions))) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            store.roles.add(id, role);
            #ok;
        };

        /// Deletes the role and takes it away from every member who holds it.
        public func deleteRole(caller : Principal, id : RoleId) : Result<(), Error> {
            switch (require(caller, TEAM_EDIT_ROLES)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            let old = switch (getRole(id)) {
                case (#ok(r)) r;
                case (#err(e)) return #err(e);
            };
            switch (requireHolds(caller, old.permissions)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            store.roles.remove(id);
            let holders = store.members.entries().filter(func(_, ids) = ids.contains(id)).map(func(p, _) = p).toArray();
            for (p in holders.values()) {
                setMemberRoles(p, rolesOf(p).filter(func r = r != id));
            };
            #ok;
        };

        public func assign(caller : Principal, principal : Principal, roleId : RoleId) : Result<(), Error> {
            switch (require(caller, TEAM_ASSIGN_ROLES)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            if (principal.isAnonymous()) return #err(#InputError("The anonymous principal can't be a member"));
            let role = switch (getRole(roleId)) {
                case (#ok(r)) r;
                case (#err(e)) return #err(e);
            };
            switch (requireHolds(caller, role.permissions)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            let held = rolesOf(principal);
            if (held.contains(roleId)) return #ok;
            if (held.size() == 0 and store.members.size() >= limits.maxMembers) {
                return #err(#InputError("A team has at most " # limits.maxMembers.toText() # " members"));
            };
            if (held.size() >= limits.maxRolesPerMember) {
                return #err(#InputError("A member has at most " # limits.maxRolesPerMember.toText() # " roles"));
            };
            store.members.add(principal, held.concat([roleId]));
            #ok;
        };

        public func unassign(caller : Principal, principal : Principal, roleId : RoleId) : Result<(), Error> {
            switch (require(caller, TEAM_ASSIGN_ROLES)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            // A role deleted meanwhile is already gone from every member.
            let permissions = switch (store.roles.get(roleId)) {
                case (?r) r.permissions;
                case null [];
            };
            switch (requireHolds(caller, permissions)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            setMemberRoles(principal, rolesOf(principal).filter(func r = r != roleId));
            #ok;
        };

        /// Drops all of `principal`'s roles without any checks (when it becomes the superuser, say).
        public func removeMember(principal : Principal) {
            store.members.remove(principal);
        };

        func setMemberRoles(principal : Principal, roleIds : [RoleId]) {
            if (roleIds.size() == 0) { store.members.remove(principal) } else {
                store.members.add(principal, roleIds);
            };
        };

        public func pageRoles(caller : Principal, after : ?RoleId, limit : ?Nat) : Result<Pagination.Page<RoleView, RoleId>, Error> {
            switch (require(caller, TEAM_VIEW)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            let entries = switch (after) {
                case (?a) store.roles.entriesFrom(a);
                case null store.roles.entries();
            };
            #ok(
                Pagination.scan<(RoleId, Role), RoleView, RoleId>(
                    entries,
                    func(id, _) = id,
                    Nat.compare,
                    after,
                    func(id, role) = ?{
                        id;
                        name = role.name;
                        permissions = role.permissions;
                    },
                    limit,
                )
            );
        };

        public func pageMembers(caller : Principal, after : ?Principal, limit : ?Nat) : Result<Pagination.Page<Member, Principal>, Error> {
            switch (require(caller, TEAM_VIEW)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            let entries = switch (after) {
                case (?a) store.members.entriesFrom(a);
                case null store.members.entries();
            };
            #ok(
                Pagination.scan<(Principal, [RoleId]), Member, Principal>(
                    entries,
                    func(p, _) = p,
                    Principal.compare,
                    after,
                    func(principal, roleIds) = ?{ principal; roleIds },
                    limit,
                )
            );
        };
    };
};
