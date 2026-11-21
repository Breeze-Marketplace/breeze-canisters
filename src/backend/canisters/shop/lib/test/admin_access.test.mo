import { expect } "mo:test";
import { suite; test } "mo:test";

import Principal "mo:core/Principal";

import AdminAccess "../admin_access";
import Fixtures "fixtures";

let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let admin = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let marketplace = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
let clerk = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let stranger = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");

let authService = Fixtures.newAuthService(owner);
Fixtures.grantAdmin(authService, admin);
Fixtures.grantMarketplace(authService, marketplace);
Fixtures.grantRole(authService, clerk, "Stock", ["Inventory.Edit"]);

suite(
    "AdminAccess",
    func() {
        test(
            "allows the Owner and Admins everything",
            func() {
                for (p in [owner, admin].values()) {
                    expect.bool(AdminAccess.canViewDashboard(authService, p)).isTrue();
                    expect.bool(AdminAccess.canViewInventory(authService, p)).isTrue();
                    expect.bool(AdminAccess.canViewDigitalAssets(authService, p)).isTrue();
                };
            },
        );
        test(
            "allows a member only what their role grants, with includes",
            func() {
                expect.bool(AdminAccess.canViewInventory(authService, clerk)).isTrue();
                expect.bool(AdminAccess.canViewDashboard(authService, clerk)).isFalse();
                expect.bool(AdminAccess.canViewDigitalAssets(authService, clerk)).isFalse();
            },
        );
        test(
            "rejects Marketplace, outsiders and the anonymous principal",
            func() {
                for (p in [marketplace, stranger, Principal.anonymous()].values()) {
                    expect.bool(AdminAccess.canViewDashboard(authService, p)).isFalse();
                    expect.bool(AdminAccess.canViewInventory(authService, p)).isFalse();
                };
            },
        );
        test(
            "rejects an Admin whose role was taken away",
            func() {
                Fixtures.revokeAdmin(authService, admin);
                expect.bool(AdminAccess.canViewDashboard(authService, admin)).isFalse();
            },
        );
    },
);
