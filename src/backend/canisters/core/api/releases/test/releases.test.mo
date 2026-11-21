import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import WasmVersion "../../../../../lib/WasmVersion";
import ReleasesAPI "../lib";

let factory = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let hash : Blob = "\01\02\03";

let v1 = 1;
let v2 = 2;
let missing = 9009009;
let yanked = 3;

func getWasmInfo(_ : WasmVersion.WasmName, version : WasmVersion.Version) : async ?ReleasesAPI.WasmInfo {
    if (version == missing) { null } else {
        ?{
            interface = if (version == v2) 1 else 0;
            breaking = version == v2;
            sha256 = hash;
            size = 8;
            yanked = version == yanked;
        };
    };
};

func repeat(x : Text, n : Nat) : [Text] {
    Array.tabulate<Text>(n, func(_) = x);
};

suite(
    "ReleasesAPI",
    func() : async () {
        await test(
            "publishes a release with the factory's hash and size",
            func() : async () {
                let state = ReleasesAPI.newState();
                switch (await ReleasesAPI.publish(state, #shop, v1, "Fixes", factory, getWasmInfo, 1)) {
                    case (#ok(r)) {
                        expect.bool(r.sha256 == hash).isTrue();
                        expect.nat(r.size).equal(8);
                        expect.principal(r.source).equal(factory);
                        expect.bool(r.interface == 0 and not r.breaking).isTrue();
                    };
                    case (#err(_)) { expect.bool(false).isTrue() };
                };
                switch (await ReleasesAPI.publish(state, #shop, v2, "Breaks", factory, getWasmInfo, 2)) {
                    case (#ok(r)) {
                        expect.bool(r.interface == 1 and r.breaking).isTrue();
                    };
                    case (#err(_)) { expect.bool(false).isTrue() };
                };
                expect.bool(ReleasesAPI.get(state, #shop, v1) != null).isTrue();
                expect.bool(ReleasesAPI.get(state, #vault, v1) == null).isTrue();
            },
        );

        await test(
            "refuses long notes, missing wasms and yanked versions",
            func() : async () {
                let state = ReleasesAPI.newState();
                let long = Text.join(repeat("x", ReleasesAPI.MAX_NOTES + 1).vals(), "");
                expect.bool((await ReleasesAPI.publish(state, #shop, v1, long, factory, getWasmInfo, 1)) == #err(#NotesTooLong)).isTrue();
                expect.bool((await ReleasesAPI.publish(state, #shop, missing, "", factory, getWasmInfo, 1)) == #err(#WasmNotFound)).isTrue();
                expect.bool((await ReleasesAPI.publish(state, #shop, yanked, "", factory, getWasmInfo, 1)) == #err(#WasmYanked)).isTrue();
                expect.nat(ReleasesAPI.list(state).size()).equal(0);
            },
        );

        await test(
            "lists releases newest first",
            func() : async () {
                let state = ReleasesAPI.newState();
                ignore await ReleasesAPI.publish(state, #shop, v1, "", factory, getWasmInfo, 1);
                ignore await ReleasesAPI.publish(state, #vault, v1, "", factory, getWasmInfo, 3);
                ignore await ReleasesAPI.publish(state, #shop, v2, "", factory, getWasmInfo, 2);
                let versions = ReleasesAPI.list(state).map(func(r : ReleasesAPI.Release) : Text = WasmVersion.key(r.name, r.version));
                expect.text(Text.join(versions.vals(), ",")).equal("vault@1,shop@2,shop@1");
            },
        );
    },
);
