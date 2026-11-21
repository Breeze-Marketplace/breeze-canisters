import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Principal "mo:core/Principal";

import Permissions "../../../../../lib/Permissions";
import PlatformPermissions "../../../../../lib/PlatformPermissions";
import AdminAPI "../lib";

let controller = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let moderator = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let stranger = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let anonymous = Principal.anonymous();
let productIndex = Principal.fromText("qhbym-qaaaa-aaaaa-aaafq-cai");
let trustSafety = Principal.fromText("qsgjb-riaaa-aaaaa-aaaga-cai");
let trusted = [productIndex, trustSafety];

func newApi() : AdminAPI.API {
    AdminAPI.API({
        team = Permissions.newStore();
        isController = func(p : Principal) : Bool { p == controller };
    });
};

/// An API where `moderator` holds a role with only `Moderation.HideProducts`, assigned by the controller.
func withModerator() : AdminAPI.API {
    let api = newApi();
    let roleId = switch (api.access.createRole(controller, "Moderator", [PlatformPermissions.moderationHideProducts])) {
        case (#ok(id)) id;
        case (#err(_)) { assert false; 0 };
    };
    assert api.access.assign(controller, moderator, roleId) == #ok;
    api;
};

suite(
    "AdminAPI",
    func() : async () {
        await test(
            "the platform catalog is valid",
            func() : async () {
                expect.array<Text>(Permissions.catalogProblems(PlatformPermissions.catalog), func t = t, func(a, b) = a == b).size(0);
            },
        );

        await test(
            "controllers hold every permission, strangers and anonymous none",
            func() : async () {
                let api = newApi();
                for (def in PlatformPermissions.catalog.values()) {
                    expect.bool(AdminAPI.has(api, controller, def.id)).isTrue();
                    expect.bool(AdminAPI.has(api, stranger, def.id)).isFalse();
                    expect.bool(AdminAPI.has(api, anonymous, def.id)).isFalse();
                };
                expect.bool(AdminAPI.has(api, controller, "Not.InCatalog")).isFalse();
            },
        );

        await test(
            "a member holds only its roles' permissions and their includes",
            func() : async () {
                let api = withModerator();
                expect.bool(AdminAPI.has(api, moderator, PlatformPermissions.moderationHideProducts)).isTrue();
                expect.bool(AdminAPI.has(api, moderator, PlatformPermissions.moderationView)).isTrue();
                expect.bool(AdminAPI.has(api, moderator, PlatformPermissions.moderationCategorize)).isFalse();
                expect.bool(AdminAPI.has(api, moderator, PlatformPermissions.upgradesApprove)).isFalse();
                expect.bool(AdminAPI.has(api, moderator, PlatformPermissions.shopsView)).isFalse();
            },
        );

        await test(
            "a member without team permissions can't grant itself more",
            func() : async () {
                let api = withModerator();
                expect.bool(api.access.createRole(moderator, "Everything", [PlatformPermissions.upgradesApprove]) == #err(#Unauthorized("Requires Team.EditRoles"))).isTrue();
                expect.bool(api.access.assign(moderator, moderator, 1) == #err(#Unauthorized("Requires Team.AssignRoles"))).isTrue();
            },
        );

        await test(
            "only the trusted canisters learn whether a principal holds a permission",
            func() : async () {
                let api = withModerator();
                let hide = PlatformPermissions.moderationHideProducts;
                expect.bool(AdminAPI.hasForCanister(api, productIndex, trusted, moderator, hide)).isTrue();
                expect.bool(AdminAPI.hasForCanister(api, trustSafety, trusted, moderator, hide)).isTrue();
                expect.bool(AdminAPI.hasForCanister(api, trustSafety, trusted, moderator, PlatformPermissions.policiesPublish)).isFalse();
                expect.bool(AdminAPI.hasForCanister(api, productIndex, trusted, controller, hide)).isTrue();
                expect.bool(AdminAPI.hasForCanister(api, productIndex, trusted, stranger, hide)).isFalse();
                expect.bool(AdminAPI.hasForCanister(api, productIndex, trusted, anonymous, hide)).isFalse();
                expect.bool(AdminAPI.hasForCanister(api, stranger, trusted, moderator, hide)).isFalse();
                expect.bool(AdminAPI.hasForCanister(api, productIndex, [], moderator, hide)).isFalse();
            },
        );
    },
);
