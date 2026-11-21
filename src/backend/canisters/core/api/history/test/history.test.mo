import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import HistoryAPI "../lib";

let staff = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let shopA = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let shopB = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");

func seqs(events : [HistoryAPI.Event]) : [Nat] = events.map(func e = e.seq);

func showNat(n : Nat) : Text = debug_show n;

suite(
    "Marketplace history",
    func() {
        test(
            "records who did what, numbered across the marketplace",
            func() {
                let state = HistoryAPI.empty();
                let first = HistoryAPI.record(state, staff, null, #shopCreationPriceSet({ usdCents = 500 }));
                let second = HistoryAPI.record(state, staff, ?shopA, #shopUnregistered);
                expect.nat(first.seq).equal(0);
                expect.nat(second.seq).equal(1);
                expect.principal(second.by).equal(staff);
                expect.bool(second.shop == ?shopA).isTrue();
                expect.bool(second.at > 0).isTrue();
            },
        );

        test(
            "a shop's timeline holds only its own events, in order, paged",
            func() {
                let state = HistoryAPI.empty();
                ignore HistoryAPI.record(state, shopA, ?shopA, #shopRegistered({ owner = shopA }));
                ignore HistoryAPI.record(state, staff, null, #wasmYanked({ name = #shop; version = 7 }));
                ignore HistoryAPI.record(state, staff, ?shopB, #canaryEligibilitySet({ eligible = true }));
                ignore HistoryAPI.record(state, staff, ?shopA, #canaryEligibilitySet({ eligible = true }));
                ignore HistoryAPI.record(state, staff, ?shopA, #upgraded({ canister = shopA; name = #shop; version = 8; outcome = #ok }));

                let all = HistoryAPI.pageShop(state, shopA, null, null);
                expect.array<Nat>(seqs(all.items), showNat, func(a, b) = a == b).equal([0, 3, 4]);
                expect.bool(all.next == null).isTrue();

                let firstTwo = HistoryAPI.pageShop(state, shopA, null, ?2);
                expect.array<Nat>(seqs(firstTwo.items), showNat, func(a, b) = a == b).equal([0, 3]);
                let rest = HistoryAPI.pageShop(state, shopA, firstTwo.next, ?2);
                expect.array<Nat>(seqs(rest.items), showNat, func(a, b) = a == b).equal([4]);
                expect.bool(rest.next == null).isTrue();

                expect.array<Nat>(seqs(HistoryAPI.pageShop(state, shopB, null, null).items), showNat, func(a, b) = a == b).equal([2]);
                expect.array<Nat>(seqs(HistoryAPI.page(state, ?1, null).items), showNat, func(a, b) = a == b).equal([2, 3, 4]);
            },
        );

        test(
            "outcomes keep the error",
            func() {
                let failed : { #ok : (); #err : Text } = #err("boom");
                expect.bool(HistoryAPI.outcome(failed, func(e : Text) : Text = e) == #err("boom")).isTrue();
                let ok : { #ok : (); #err : Text } = #ok;
                expect.bool(HistoryAPI.outcome(ok, func(e : Text) : Text = e) == #ok).isTrue();
            },
        );
    },
);
