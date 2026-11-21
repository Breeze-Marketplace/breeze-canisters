import { expect } "mo:test";
import { suite; test } "mo:test";

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Result "mo:core/Result";

import Map "mo:map/Map";

import AuthService "../auth";
import Fixtures "fixtures";
import ShopPermissions "../permissions";
import Subscriptions "../subscriptions";

let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let admin = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let marketplace = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
let controller = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let stranger = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");
let anonymous = Principal.anonymous();

let max = Subscriptions.MAX_SUBSCRIBERS_PER_EVENT;

let makeAuthService = func() : AuthService.AuthService {
    let authService = Fixtures.newAuthService(owner);
    Fixtures.grantAdmin(authService, admin);
    Fixtures.grantMarketplace(authService, marketplace);
    authService;
};

/// The rule main.mo uses, with `controller` standing in for `Principal.isController`.
let isAllowedBy = func(authService : AuthService.AuthService) : Principal -> Bool {
    func(p : Principal) : Bool {
        p == controller or AuthService.isMarketplace(authService, p) or AuthService.hasPermission(authService, p, ShopPermissions.eventsManage);
    };
};

// Listeners are plain values here: these tests cover who may subscribe, not delivery.
let subscribe = func(subscribers : Map.Map<Principal, Nat>, isAllowed : Principal -> Bool, caller : Principal) : Result.Result<(), Subscriptions.SubscribeError> {
    Subscriptions.subscribe(subscribers, isAllowed, "OrderUpdated", caller, 0);
};

let isUnauthorized = func(r : Result.Result<(), Subscriptions.SubscribeError>) : Bool {
    switch (r) { case (#err(#Unauthorized(_))) true; case _ false };
};

let isTooMany = func(r : Result.Result<(), Subscriptions.SubscribeError>) : Bool {
    switch (r) { case (#err(#TooManySubscribers(_))) true; case _ false };
};

/// `n` distinct principals, each granted `#Admin` so it may subscribe.
let grantAdmins = func(authService : AuthService.AuthService, n : Nat) : [Principal] {
    Array.tabulate<Principal>(
        n,
        func(i) {
            let p = Principal.fromBlob(Blob.fromArray([Nat8.fromNat(i), 0x01]));
            Fixtures.grantAdmin(authService, p);
            p;
        },
    );
};

suite(
    "who may subscribe",
    func() {
        test(
            "an unknown caller can't subscribe",
            func() {
                let subscribers = Map.new<Principal, Nat>();
                expect.bool(isUnauthorized(subscribe(subscribers, isAllowedBy(makeAuthService()), stranger))).isTrue();
                expect.nat(Map.size(subscribers)).equal(0);
            },
        );
        test(
            "the anonymous principal can't subscribe, even if isAllowed says yes",
            func() {
                let subscribers = Map.new<Principal, Nat>();
                expect.bool(isUnauthorized(subscribe(subscribers, func(_) = true, anonymous))).isTrue();
            },
        );
        test(
            "the Owner, Admins, Marketplace and controllers can subscribe",
            func() {
                let subscribers = Map.new<Principal, Nat>();
                let isAllowed = isAllowedBy(makeAuthService());
                for (p in [owner, admin, marketplace, controller].vals()) {
                    expect.bool(Result.isOk(subscribe(subscribers, isAllowed, p))).isTrue();
                };
                expect.nat(Map.size(subscribers)).equal(4);
            },
        );
    },
);

suite(
    "who is notified",
    func() {
        test(
            "a subscriber that lost its role, or never had one, is removed instead of notified",
            func() {
                let authService = makeAuthService();
                let isAllowed = isAllowedBy(authService);
                let subscribers = Map.new<Principal, Nat>();
                ignore subscribe(subscribers, isAllowed, marketplace);
                ignore subscribe(subscribers, isAllowed, admin);
                // As if it had subscribed before subscriptions were checked.
                Map.set(subscribers, Map.phash, stranger, 0);
                Fixtures.revokeMarketplace(authService, marketplace);

                var logged = 0;
                let kept = Subscriptions.allowed(subscribers, isAllowed, "OrderUpdated", func(_ : Text) { logged += 1 });

                expect.nat(kept.size()).equal(1);
                expect.principal(kept[0].0).equal(admin);
                expect.nat(Map.size(subscribers)).equal(1);
                expect.nat(logged).equal(2);
            },
        );
    },
);

suite(
    "whether a principal is subscribed (BRE-195)",
    func() {
        test(
            "a subscriber is subscribed until it unsubscribes or loses its role",
            func() {
                let authService = makeAuthService();
                let isAllowed = isAllowedBy(authService);
                let subscribers = Map.new<Principal, Nat>();
                expect.bool(Subscriptions.isSubscribed(subscribers, isAllowed, marketplace)).isFalse();

                ignore subscribe(subscribers, isAllowed, marketplace);
                expect.bool(Subscriptions.isSubscribed(subscribers, isAllowed, marketplace)).isTrue();
                expect.bool(Subscriptions.isSubscribed(subscribers, isAllowed, admin)).isFalse();

                // Still in the map until the next notification removes it, but no longer notified.
                Fixtures.revokeMarketplace(authService, marketplace);
                expect.bool(Subscriptions.isSubscribed(subscribers, isAllowed, marketplace)).isFalse();
            },
        );
        test(
            "a removed subscriber isn't subscribed",
            func() {
                let isAllowed = isAllowedBy(makeAuthService());
                let subscribers = Map.new<Principal, Nat>();
                ignore subscribe(subscribers, isAllowed, controller);
                Map.delete(subscribers, Map.phash, controller);
                expect.bool(Subscriptions.isSubscribed(subscribers, isAllowed, controller)).isFalse();
            },
        );
    },
);

suite(
    "subscriber cap",
    func() {
        test(
            "an event takes at most MAX_SUBSCRIBERS_PER_EVENT subscribers",
            func() {
                let authService = makeAuthService();
                let isAllowed = isAllowedBy(authService);
                let subscribers = Map.new<Principal, Nat>();
                let admins = grantAdmins(authService, max + 1);
                var i = 0;
                while (i < max) {
                    expect.bool(Result.isOk(subscribe(subscribers, isAllowed, admins[i]))).isTrue();
                    i += 1;
                };
                expect.bool(isTooMany(subscribe(subscribers, isAllowed, admins[max]))).isTrue();
                expect.nat(Map.size(subscribers)).equal(max);

                // Subscribing again replaces the listener without taking a new slot.
                expect.bool(Result.isOk(subscribe(subscribers, isAllowed, admins[0]))).isTrue();

                // Removing one frees a slot.
                Map.delete(subscribers, Map.phash, admins[0]);
                expect.bool(Result.isOk(subscribe(subscribers, isAllowed, admins[max]))).isTrue();
            },
        );
    },
);
