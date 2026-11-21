import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Error "mo:core/Error";
import Principal "mo:core/Principal";

import Map "mo:map/Map";

import Moderation "../Moderation";

let localModerator = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let coreModerator = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let stranger = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let anonymous = Principal.anonymous();

func moderators() : Map.Map<Principal, ()> {
    let m = Map.new<Principal, ()>();
    Map.set(m, Map.phash, localModerator, ());
    // A misconfigured list must not let the anonymous principal through.
    Map.set(m, Map.phash, anonymous, ());
    m;
};

let hide = "Moderation.HideProducts";

// Core as seen through `hasPlatformPermission`: `coreModerator` holds only `Moderation.HideProducts`.
func core(p : Principal, permission : Text) : async* Bool {
    p == coreModerator and permission == hide;
};

suite(
    "Moderation.isModerator",
    func() : async () {
        await test(
            "local moderators pass without asking core",
            func() : async () {
                var asked = false;
                let ask = func(_ : Principal, _ : Text) : async* Bool {
                    asked := true;
                    false;
                };
                expect.bool(await* Moderation.isModerator(moderators(), localModerator, hide, ?ask)).isTrue();
                expect.bool(asked).isFalse();
            },
        );

        await test(
            "holders of the permission in core are moderators, strangers are not",
            func() : async () {
                expect.bool(await* Moderation.isModerator(moderators(), coreModerator, hide, ?core)).isTrue();
                expect.bool(await* Moderation.isModerator(moderators(), stranger, hide, ?core)).isFalse();
            },
        );

        await test(
            "core is asked for the permission the action needs",
            func() : async () {
                expect.bool(await* Moderation.isModerator(moderators(), coreModerator, "Moderation.Categorize", ?core)).isFalse();
                expect.bool(await* Moderation.hasPlatformPermission(coreModerator, hide, ?core)).isTrue();
                expect.bool(await* Moderation.hasPlatformPermission(coreModerator, "Policies.Publish", ?core)).isFalse();
            },
        );

        await test(
            "local moderators hold no platform permission of their own",
            func() : async () {
                expect.bool(await* Moderation.hasPlatformPermission(localModerator, hide, ?core)).isFalse();
            },
        );

        await test(
            "the anonymous principal is never a moderator",
            func() : async () {
                let ask = func(_ : Principal, _ : Text) : async* Bool { true };
                expect.bool(await* Moderation.isModerator(moderators(), anonymous, hide, ?ask)).isFalse();
            },
        );

        await test(
            "without core, only local moderators pass",
            func() : async () {
                expect.bool(await* Moderation.isModerator(moderators(), localModerator, hide, null)).isTrue();
                expect.bool(await* Moderation.isModerator(moderators(), coreModerator, hide, null)).isFalse();
            },
        );

        await test(
            "fails closed when the call to core fails",
            func() : async () {
                let ask = func(_ : Principal, _ : Text) : async* Bool {
                    throw Error.reject("core unavailable");
                };
                expect.bool(await* Moderation.isModerator(moderators(), coreModerator, hide, ?ask)).isFalse();
            },
        );
    },
);
