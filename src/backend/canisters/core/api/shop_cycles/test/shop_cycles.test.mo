import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Array "mo:core/Array";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import ShopCyclesAPI "../lib";

let shop = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let vault = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let broken = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");

let T = 1_000_000_000_000;
let hour : Int = 3_600_000_000_000;
let day : Int = 24 * hour;

// 0.1T a day idle for 30 days: a 3T freezing threshold.
func raw(cycles : Nat) : ShopCyclesAPI.RawStatus {
    {
        cycles;
        idleCyclesBurnedPerDay = T / 10;
        freezingThresholdSeconds = 2_592_000;
    };
};

func runwayOf(state : ShopCyclesAPI.State, id : Principal) : ShopCyclesAPI.Runway {
    switch (ShopCyclesAPI.get(state, #shop, id, false).runway) {
        case (?r) r;
        case null { assert false; loop {} };
    };
};

suite(
    "ShopCyclesAPI",
    func() : async () {
        await test(
            "a canister never read has no runway",
            func() : async () {
                let state = ShopCyclesAPI.emptyState();
                assert ShopCyclesAPI.get(state, #vault, vault, false).runway == null;
                assert ShopCyclesAPI.isStale(state, vault, 0);
            },
        );

        await test(
            "the first reading estimates from the idle burn",
            func() : async () {
                let state = ShopCyclesAPI.emptyState();
                ShopCyclesAPI.record(state, shop, raw(10 * T), 0);
                let r = runwayOf(state, shop);
                expect.nat(r.freezingThresholdCycles).equal(3 * T);
                expect.nat(r.burnPerDay).equal(T / 10);
                expect.bool(r.burnMeasured).equal(false);
                // (10T - 3T) / 0.1T a day
                assert r.daysLeft == ?70;
            },
        );

        await test(
            "a rate is measured once samples are 12 hours apart",
            func() : async () {
                let state = ShopCyclesAPI.emptyState();
                ShopCyclesAPI.record(state, shop, raw(10 * T), 0);
                // Too soon: still the idle burn.
                ShopCyclesAPI.record(state, shop, raw(10 * T - T / 10), hour);
                expect.bool(runwayOf(state, shop).burnMeasured).equal(false);
                // A day after the first sample, 1T burned.
                ShopCyclesAPI.record(state, shop, raw(9 * T), day);
                let r = runwayOf(state, shop);
                expect.bool(r.burnMeasured).equal(true);
                expect.nat(r.burnPerDay).equal(T);
                assert r.daysLeft == ?6;
                // The next day burns 0.5T: the estimate averages the two.
                ShopCyclesAPI.record(state, shop, raw(9 * T - T / 2), 2 * day);
                expect.nat(runwayOf(state, shop).burnPerDay).equal(3 * T / 4);
            },
        );

        await test(
            "a top-up restarts measuring and keeps the previous rate",
            func() : async () {
                let state = ShopCyclesAPI.emptyState();
                ShopCyclesAPI.record(state, shop, raw(10 * T), 0);
                ShopCyclesAPI.record(state, shop, raw(9 * T), day);
                ShopCyclesAPI.record(state, shop, raw(20 * T), day + hour);
                let r = runwayOf(state, shop);
                expect.nat(r.burnPerDay).equal(T);
                assert r.daysLeft == ?17;
                // A day after the top-up, measured from the top-up rather than across it.
                ShopCyclesAPI.record(state, shop, raw(18 * T), 2 * day + hour);
                expect.nat(runwayOf(state, shop).burnPerDay).equal(3 * T / 2);
            },
        );

        await test(
            "the idle burn is the floor and a frozen canister has no days left",
            func() : async () {
                let state = ShopCyclesAPI.emptyState();
                ShopCyclesAPI.record(state, shop, raw(4 * T), 0);
                ShopCyclesAPI.record(state, shop, raw(4 * T), day);
                let r = runwayOf(state, shop);
                expect.nat(r.burnPerDay).equal(T / 10);
                expect.bool(r.burnMeasured).equal(true);
                ShopCyclesAPI.record(state, shop, raw(2 * T), 2 * day);
                assert runwayOf(state, shop).daysLeft == ?0;
            },
        );

        await test(
            "a self-managed canister has no runway, even with an old reading",
            func() : async () {
                let state = ShopCyclesAPI.emptyState();
                ShopCyclesAPI.record(state, shop, raw(10 * T), 0);
                let row = ShopCyclesAPI.get(state, #shop, shop, true);
                expect.bool(row.selfManaged).equal(true);
                assert row.runway == null;
            },
        );

        await test(
            "a reading goes stale after 5 minutes",
            func() : async () {
                let state = ShopCyclesAPI.emptyState();
                ShopCyclesAPI.record(state, shop, raw(10 * T), 0);
                expect.bool(ShopCyclesAPI.isStale(state, shop, 60_000_000_000)).equal(false);
                expect.bool(ShopCyclesAPI.isStale(state, shop, 300_000_000_000)).equal(true);
            },
        );

        await test(
            "sample records every canister and reports the ones that fail",
            func() : async () {
                let state = ShopCyclesAPI.emptyState();
                let ops : ShopCyclesAPI.Operations = {
                    canisterStatuses = func(ids : [Principal]) : async* [Result<ShopCyclesAPI.RawStatus, Text>] {
                        assert ids.size() <= ShopCyclesAPI.batchSize;
                        Array.map<Principal, Result<ShopCyclesAPI.RawStatus, Text>>(
                            ids,
                            func(id) = if (id == broken) #err("not a controller") else #ok(raw(5 * T)),
                        );
                    };
                    now = func() : Int { 42 };
                };
                let failures = await* ShopCyclesAPI.sample(state, ops, [shop, broken, vault]);
                expect.nat(failures.size()).equal(1);
                assert failures[0].0 == broken;
                expect.nat(runwayOf(state, shop).cycles).equal(5 * T);
                expect.nat(runwayOf(state, vault).cycles).equal(5 * T);
                assert ShopCyclesAPI.get(state, #shop, broken, false).runway == null;
            },
        );

        await test(
            "sample reads at most batchSize canisters at once",
            func() : async () {
                let state = ShopCyclesAPI.emptyState();
                var batches = 0;
                let ops : ShopCyclesAPI.Operations = {
                    canisterStatuses = func(ids : [Principal]) : async* [Result<ShopCyclesAPI.RawStatus, Text>] {
                        assert ids.size() <= ShopCyclesAPI.batchSize;
                        batches += 1;
                        Array.map<Principal, Result<ShopCyclesAPI.RawStatus, Text>>(ids, func(_) = #ok(raw(5 * T)));
                    };
                    now = func() : Int { 42 };
                };
                let ids = Array.tabulate<Principal>(ShopCyclesAPI.batchSize * 2 + 1, func(i) = if (i % 2 == 0) shop else vault);
                let failures = await* ShopCyclesAPI.sample(state, ops, ids);
                expect.nat(failures.size()).equal(0);
                expect.nat(batches).equal(3);
            },
        );
    },
);
