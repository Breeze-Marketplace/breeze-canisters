import { expect } "mo:test";
import { suite; test } "mo:test";

import Array "mo:core/Array";
import Iter "mo:core/Iter";
import Principal "mo:core/Principal";

import Map "mo:map/Map";

import AuthService "../auth";
import Fixtures "fixtures";
import OrderAccess "../order_access";

let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let admin = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let marketplace = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
let buyer = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let stranger = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");
let anonymous = Principal.anonymous();

let makeAuthService = func() : AuthService.AuthService {
    let authService = Fixtures.newAuthService(owner);
    Fixtures.grantAdmin(authService, admin);
    Fixtures.grantMarketplace(authService, marketplace);
    authService;
};

let order = { buyer = buyer };
let anonymousOrder = { buyer = anonymous };

suite(
    "OrderAccess.canPlaceOrder",
    func() {
        test(
            "allows signed-in callers",
            func() {
                expect.bool(OrderAccess.canPlaceOrder(buyer)).isTrue();
                expect.bool(OrderAccess.canPlaceOrder(stranger)).isTrue();
            },
        );
        test(
            "rejects the anonymous principal",
            func() {
                expect.bool(OrderAccess.canPlaceOrder(anonymous)).isFalse();
            },
        );
    },
);

suite(
    "OrderAccess.isBuyer",
    func() {
        test(
            "matches the order's buyer",
            func() {
                expect.bool(OrderAccess.isBuyer(buyer, order)).isTrue();
            },
        );
        test(
            "rejects any other principal",
            func() {
                expect.bool(OrderAccess.isBuyer(stranger, order)).isFalse();
                expect.bool(OrderAccess.isBuyer(owner, order)).isFalse();
            },
        );
        test(
            "never treats the anonymous principal as a buyer",
            func() {
                expect.bool(OrderAccess.isBuyer(anonymous, anonymousOrder)).isFalse();
                expect.bool(OrderAccess.isBuyer(anonymous, order)).isFalse();
            },
        );
    },
);

suite(
    "OrderAccess.canViewAllOrders",
    func() {
        let authService = makeAuthService();
        test(
            "allows Owner and Admin",
            func() {
                expect.bool(OrderAccess.canViewAllOrders(authService, owner)).isTrue();
                expect.bool(OrderAccess.canViewAllOrders(authService, admin)).isTrue();
            },
        );
        test(
            "rejects Marketplace, buyers, strangers and anonymous",
            func() {
                expect.bool(OrderAccess.canViewAllOrders(authService, marketplace)).isFalse();
                expect.bool(OrderAccess.canViewAllOrders(authService, buyer)).isFalse();
                expect.bool(OrderAccess.canViewAllOrders(authService, stranger)).isFalse();
                expect.bool(OrderAccess.canViewAllOrders(authService, anonymous)).isFalse();
            },
        );
        test(
            "stops allowing an Admin once the role is revoked",
            func() {
                Fixtures.revokeAdmin(authService, admin);
                expect.bool(OrderAccess.canViewAllOrders(authService, admin)).isFalse();
            },
        );
    },
);

suite(
    "OrderAccess.canViewOrder",
    func() {
        let authService = makeAuthService();
        test(
            "allows the buyer, Owner and Admin",
            func() {
                expect.bool(OrderAccess.canViewOrder(authService, buyer, order)).isTrue();
                expect.bool(OrderAccess.canViewOrder(authService, owner, order)).isTrue();
                expect.bool(OrderAccess.canViewOrder(authService, admin, order)).isTrue();
            },
        );
        test(
            "rejects Marketplace and other principals",
            func() {
                expect.bool(OrderAccess.canViewOrder(authService, marketplace, order)).isFalse();
                expect.bool(OrderAccess.canViewOrder(authService, stranger, order)).isFalse();
                expect.bool(OrderAccess.canViewOrder(authService, anonymous, order)).isFalse();
            },
        );
        test(
            "keeps an anonymously placed order away from anonymous callers",
            func() {
                expect.bool(OrderAccess.canViewOrder(authService, anonymous, anonymousOrder)).isFalse();
                expect.bool(OrderAccess.canViewOrder(authService, owner, anonymousOrder)).isTrue();
            },
        );
    },
);

suite(
    "OrderAccess with narrow roles",
    func() {
        let authService = makeAuthService();
        let packer = Principal.fromText("aaaaa-aa");
        let support = Principal.fromText("qoctq-giaaa-aaaaa-aaaea-cai");
        Fixtures.grantRole(authService, packer, "Packer", ["Orders.Fulfill"]);
        Fixtures.grantRole(authService, support, "Support", ["Orders.Cancel"]);
        test(
            "Orders.Fulfill includes seeing orders but not cancelling them",
            func() {
                expect.bool(OrderAccess.canViewOrder(authService, packer, order)).isTrue();
                expect.bool(OrderAccess.canCancelOrder(authService, packer, order)).isFalse();
                expect.bool(OrderAccess.canCancelAllOrders(authService, packer)).isFalse();
            },
        );
        test(
            "Orders.Cancel allows cancelling any order",
            func() {
                expect.bool(OrderAccess.canCancelOrder(authService, support, order)).isTrue();
                expect.bool(OrderAccess.canViewAllOrders(authService, support)).isTrue();
            },
        );
        test(
            "the buyer may cancel their own order; Marketplace may not",
            func() {
                expect.bool(OrderAccess.canCancelOrder(authService, buyer, order)).isTrue();
                expect.bool(OrderAccess.canCancelOrder(authService, marketplace, order)).isFalse();
                expect.bool(OrderAccess.canCancelOrder(authService, anonymous, anonymousOrder)).isFalse();
            },
        );
    },
);

suite(
    "OrderAccess.hasRoomForUnpaidOrder",
    func() {
        let unpaid = func(buyers : [Principal]) : Iter.Iter<{ buyer : Principal }> = Iter.map<Principal, { buyer : Principal }>(buyers.values(), func(b) = { buyer = b });
        let max = OrderAccess.MAX_UNPAID_ORDERS_PER_BUYER;

        test(
            "allows a buyer below the limit",
            func() {
                expect.bool(OrderAccess.hasRoomForUnpaidOrder(buyer, unpaid([]))).isTrue();
                expect.bool(OrderAccess.hasRoomForUnpaidOrder(buyer, unpaid(Array.repeat(buyer, max - 1 : Nat)))).isTrue();
            },
        );

        test(
            "rejects a buyer at the limit",
            func() {
                expect.bool(OrderAccess.hasRoomForUnpaidOrder(buyer, unpaid(Array.repeat(buyer, max)))).isFalse();
            },
        );

        test(
            "counts only the caller's own orders",
            func() {
                let others = Array.repeat(stranger, max * 2);
                expect.bool(OrderAccess.hasRoomForUnpaidOrder(buyer, unpaid(others))).isTrue();
                expect.bool(OrderAccess.hasRoomForUnpaidOrder(stranger, unpaid(others))).isFalse();
            },
        );
    },
);
