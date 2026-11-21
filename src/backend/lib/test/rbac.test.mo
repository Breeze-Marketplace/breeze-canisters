import { expect } "mo:test";
import { suite; test } "mo:test";
import Principal "mo:core/Principal";
import Map "mo:map/Map";

import Rbac "../Rbac";

let alice = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let bob = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");

type Role = { #Owner; #Admin; #Marketplace };

func newRbac() : (Rbac.Roles<Role>, Rbac.Rbac<Role>) {
    let roles = Map.new<Principal, [Role]>();
    (roles, Rbac.Rbac<Role>(roles, func(a, b) = a == b, #Owner));
};

suite(
    "Rbac",
    func() {
        test(
            "#Owner implies every other role",
            func() {
                let (_, rbac) = newRbac();
                rbac.add(alice, #Owner);
                expect.bool(rbac.hasRole(alice, #Admin)).isTrue();
                expect.bool(rbac.hasRole(alice, #Marketplace)).isTrue();
                expect.bool(rbac.hasRole(bob, #Admin)).isFalse();
            },
        );
        test(
            "add is idempotent and remove drops an emptied entry",
            func() {
                let (roles, rbac) = newRbac();
                rbac.add(bob, #Admin);
                rbac.add(bob, #Admin);
                expect.nat(rbac.rolesOf(bob).size()).equal(1);
                rbac.remove(bob, #Admin);
                expect.bool(Map.has(roles, Map.phash, bob)).isFalse();
            },
        );
        test(
            "hasAnyRole and ownerIsSet",
            func() {
                let (_, rbac) = newRbac();
                expect.bool(rbac.ownerIsSet()).isFalse();
                rbac.add(bob, #Admin);
                expect.bool(rbac.hasAnyRole(bob, [#Owner, #Admin])).isTrue();
                expect.bool(rbac.hasAnyRole(bob, [#Owner])).isFalse();
                rbac.add(alice, #Owner);
                expect.bool(rbac.ownerIsSet()).isTrue();
            },
        );
    },
);
