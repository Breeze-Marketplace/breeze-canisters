import { expect } "mo:test";
import { suite; test } "mo:test";
import Array "mo:core/Array";
import Map "mo:core/Map";
import Principal "mo:core/Principal";

import Permissions "../Permissions";

let owner = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let manager = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let clerk = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
let stranger = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");

let catalog : [Permissions.PermissionDef] = Permissions.teamCatalog.concat([
    { id = "Orders.View"; includes = [] },
    { id = "Orders.Fulfill"; includes = ["Orders.View"] },
    { id = "Orders.Cancel"; includes = ["Orders.View"] },
    { id = "Products.Edit"; includes = [] },
]);

let limits : Permissions.Limits = {
    maxRoles = 4;
    maxMembers = 3;
    maxRolesPerMember = 2;
    maxNameLength = 20;
};

func newAccess() : (Permissions.Store, Permissions.Access) {
    let store = Permissions.newStore();
    (store, Permissions.Access(store, catalog, func p = p == owner, limits));
};

func ok<T>(r : { #ok : T; #err : Permissions.Error }) : T {
    switch (r) {
        case (#ok(v)) v;
        case (#err(e)) { expect.text(debug_show e).equal("ok"); loop {} };
    };
};

func isUnauthorized<T>(r : { #ok : T; #err : Permissions.Error }) : Bool {
    switch (r) { case (#err(#Unauthorized(_))) true; case _ false };
};

func isInputError<T>(r : { #ok : T; #err : Permissions.Error }) : Bool {
    switch (r) { case (#err(#InputError(_))) true; case _ false };
};

suite(
    "Permissions",
    func() {
        test(
            "the test catalog is valid",
            func() {
                expect.nat(Permissions.catalogProblems(catalog).size()).equal(0);
            },
        );

        test(
            "catalogProblems reports cross-resource, chained and unknown includes, and missing team permissions",
            func() {
                let bad : [Permissions.PermissionDef] = [
                    { id = "Orders.View"; includes = [] },
                    { id = "Orders.Fulfill"; includes = ["Products.Edit"] },
                    { id = "Orders.Cancel"; includes = ["Orders.Fulfill"] },
                    { id = "Orders.Refund"; includes = ["Orders.Nope"] },
                    { id = "Products.Edit"; includes = [] },
                    { id = "Bad"; includes = [] },
                ];
                // cross-resource, chained, unknown, bad id, 3 missing team permissions
                expect.nat(Permissions.catalogProblems(bad).size()).equal(7);
            },
        );

        test(
            "the superuser holds every catalog permission and nothing else",
            func() {
                let (_, access) = newAccess();
                expect.bool(access.has(owner, "Orders.Cancel")).isTrue();
                expect.bool(access.has(owner, "Team.EditRoles")).isTrue();
                expect.bool(access.has(owner, "Funds.Withdraw")).isFalse();
                expect.bool(access.myPermissions(owner).isSuperuser).isTrue();
            },
        );

        test(
            "members get the union of their roles plus includes",
            func() {
                let (_, access) = newAccess();
                let fulfil = ok(access.createRole(owner, "Fulfil", ["Orders.Fulfill"]));
                let catalogRole = ok(access.createRole(owner, "Catalog", ["Products.Edit"]));
                ok(access.assign(owner, clerk, fulfil));
                ok(access.assign(owner, clerk, catalogRole));
                expect.bool(access.has(clerk, "Orders.Fulfill")).isTrue();
                expect.bool(access.has(clerk, "Orders.View")).isTrue();
                expect.bool(access.has(clerk, "Products.Edit")).isTrue();
                expect.bool(access.has(clerk, "Orders.Cancel")).isFalse();
                expect.bool(access.has(stranger, "Orders.View")).isFalse();
                expect.bool(access.has(Principal.anonymous(), "Orders.View")).isFalse();
            },
        );

        test(
            "unknown permissions in a stored role grant nothing",
            func() {
                let (store, access) = newAccess();
                let id = Permissions.seedRole(store, "Old", ["Removed.Thing", "Orders.View"]);
                Permissions.seedMember(store, clerk, id);
                expect.bool(access.has(clerk, "Removed.Thing")).isFalse();
                expect.bool(access.has(clerk, "Orders.View")).isTrue();
            },
        );

        test(
            "team actions need their permission",
            func() {
                let (_, access) = newAccess();
                let fulfil = ok(access.createRole(owner, "Fulfil", ["Orders.Fulfill"]));
                expect.bool(isUnauthorized(access.createRole(stranger, "X", []))).isTrue();
                expect.bool(isUnauthorized(access.assign(stranger, clerk, fulfil))).isTrue();
                expect.bool(isUnauthorized(access.pageRoles(stranger, null, null))).isTrue();

                let viewer = ok(access.createRole(owner, "Viewer", ["Team.View"]));
                ok(access.assign(owner, manager, viewer));
                expect.nat(ok(access.pageRoles(manager, null, null)).items.size()).equal(2);
                expect.bool(isUnauthorized(access.assign(manager, clerk, fulfil))).isTrue();
            },
        );

        test(
            "a member can't hand out, edit or remove permissions they don't hold",
            func() {
                let (_, access) = newAccess();
                let assigner = ok(access.createRole(owner, "Assigner", ["Team.AssignRoles", "Team.EditRoles", "Orders.Fulfill"]));
                let full = ok(access.createRole(owner, "Full", ["Orders.Cancel"]));
                let fulfil = ok(access.createRole(owner, "Fulfil", ["Orders.Fulfill"]));
                ok(access.assign(owner, manager, assigner));

                // Assigning or creating beyond their own permissions is refused, including to themselves.
                expect.bool(isUnauthorized(access.assign(manager, manager, full))).isTrue();
                expect.bool(isUnauthorized(access.assign(manager, clerk, full))).isTrue();
                expect.bool(isUnauthorized(access.createRole(manager, "Mine", ["Orders.Cancel"]))).isTrue();
                // Widening a role they hold, or editing or deleting one with more, is refused.
                expect.bool(isUnauthorized(access.updateRole(manager, fulfil, "Fulfil", ["Orders.Cancel"]))).isTrue();
                expect.bool(isUnauthorized(access.updateRole(manager, full, "Full", []))).isTrue();
                expect.bool(isUnauthorized(access.deleteRole(manager, full))).isTrue();

                // Within their permissions it works; included permissions count as held.
                ok(access.assign(manager, clerk, fulfil));
                ignore ok(access.createRole(manager, "Viewer", ["Orders.View"]));
                ok(access.unassign(manager, clerk, fulfil));
                expect.bool(access.has(clerk, "Orders.Fulfill")).isFalse();
            },
        );

        test(
            "deleting a role takes it from its members",
            func() {
                let (store, access) = newAccess();
                let fulfil = ok(access.createRole(owner, "Fulfil", ["Orders.Fulfill"]));
                ok(access.assign(owner, clerk, fulfil));
                ok(access.deleteRole(owner, fulfil));
                expect.bool(access.has(clerk, "Orders.View")).isFalse();
                expect.nat(store.members.size()).equal(0);
                expect.bool(isUnauthorized(access.pageMembers(clerk, null, null))).isTrue();
            },
        );

        test(
            "validates names and permissions",
            func() {
                let (_, access) = newAccess();
                ignore ok(access.createRole(owner, " Fulfil ", ["Orders.View", "Orders.View"]));
                let roles = ok(access.pageRoles(owner, null, null)).items;
                expect.text(roles[0].name).equal("Fulfil");
                expect.nat(roles[0].permissions.size()).equal(1);
                expect.bool(isInputError(access.createRole(owner, "fulfil", []))).isTrue();
                expect.bool(isInputError(access.createRole(owner, "", []))).isTrue();
                expect.bool(isInputError(access.createRole(owner, "a name that is far too long", []))).isTrue();
                expect.bool(isInputError(access.createRole(owner, "X", ["Funds.Withdraw"]))).isTrue();
            },
        );

        test(
            "enforces limits and refuses the anonymous principal as a member",
            func() {
                let (_, access) = newAccess();
                let a = ok(access.createRole(owner, "A", []));
                let b = ok(access.createRole(owner, "B", []));
                let c = ok(access.createRole(owner, "C", []));
                ignore ok(access.createRole(owner, "D", []));
                expect.bool(isInputError(access.createRole(owner, "E", []))).isTrue();

                expect.bool(isInputError(access.assign(owner, Principal.anonymous(), a))).isTrue();

                ok(access.assign(owner, clerk, a));
                ok(access.assign(owner, clerk, b));
                expect.bool(isInputError(access.assign(owner, clerk, c))).isTrue();

                ok(access.assign(owner, manager, a));
                ok(access.assign(owner, stranger, a));
                expect.bool(isInputError(access.assign(owner, Principal.fromText("aaaaa-aa"), a))).isTrue();
                // An existing member can still get another role.
                ok(access.assign(owner, manager, b));
            },
        );

        test(
            "the superuser may hold roles, which take effect once it stops being the superuser",
            func() {
                let store = Permissions.newStore();
                var superuser = owner;
                let access = Permissions.Access(store, catalog, func p = p == superuser, limits);
                let fulfil = ok(access.createRole(owner, "Fulfil", ["Orders.Fulfill"]));
                ok(access.assign(owner, owner, fulfil));
                expect.bool(access.has(owner, "Products.Edit")).isTrue();
                superuser := manager;
                expect.bool(access.has(owner, "Orders.Fulfill")).isTrue();
                expect.bool(access.has(owner, "Products.Edit")).isFalse();
            },
        );

        test(
            "pages members in principal order",
            func() {
                let (_, access) = newAccess();
                let a = ok(access.createRole(owner, "A", []));
                ok(access.assign(owner, clerk, a));
                ok(access.assign(owner, manager, a));
                let first = ok(access.pageMembers(owner, null, ?1));
                expect.nat(first.items.size()).equal(1);
                let rest = ok(access.pageMembers(owner, first.next, ?10));
                expect.nat(rest.items.size()).equal(1);
                expect.bool(rest.next == null).isTrue();
            },
        );
    },
);
