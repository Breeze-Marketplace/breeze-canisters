import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import Flush "../Internal/Flush";
import Metrics "../Internal/Metrics";
import Outbox "../Internal/Outbox";
import Types "../Types";

let staff = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let HOUR : Int = 3_600_000_000_000;
let CAPACITY = 1_000_000;

func notification(body : Text, expiresAt : Int) : Types.Notification = {
    title = "New shop";
    body;
    url = null;
    key = ?"alert-shopCreated";
    urgency = null;
    expiresAt = ?expiresAt;
    funnel = null;
};

func send(state : Outbox.State, body : Text, expiresAt : Int, capacity : Nat, now : Int) : ?Nat64 {
    state.add(staff, notification(body, expiresAt), now + HOUR, capacity, now);
};

/// Hands every ready entry to II and has II accept them all.
func acceptAll(state : Outbox.State, now : Int) {
    let pipeline = Metrics.empty();
    Flush.apply(state, pipeline, state.take(100), #answered([]), now);
};

suite(
    "Notification outbox (vendored, BRE-211 fixes)",
    func() {
        test(
            "replacing an accepted notification keeps the replacement past the old deadline",
            func() {
                let state = Outbox.empty();
                let start = 10 * HOUR;
                let ?id = send(state, "first", start + HOUR, CAPACITY, start) else return expect.bool(false).isTrue();
                acceptAll(state, start);
                ignore send(state, "second", start + 2 * HOUR, CAPACITY, start + 1);
                acceptAll(state, start + 1);
                ignore state.sweep(start + HOUR + 1);
                expect.bool(state.holds(id)).isTrue();
                expect.bool(state.contentOf(id) == ?{ title = "New shop"; body = "second"; url = null }).isTrue();
                ignore state.sweep(start + 2 * HOUR + 1);
                expect.bool(state.holds(id)).isFalse();
                expect.nat(state.bytes).equal(0);
            },
        );

        test(
            "a refused replacement keeps the old content and its byte count",
            func() {
                let state = Outbox.empty();
                let start = 10 * HOUR;
                let ?id = send(state, "short", start + HOUR, 200, start) else return expect.bool(false).isTrue();
                acceptAll(state, start);
                let held = state.bytes;
                let long = Text.join(Array.repeat("x", 300).values(), "");
                expect.bool(send(state, long, start + HOUR, 200, start + 1) == null).isTrue();
                expect.bool(state.holds(id)).isTrue();
                expect.nat(state.bytes).equal(held);
                ignore state.sweep(start + HOUR + 1);
                expect.nat(state.bytes).equal(0);
            },
        );

        test(
            "resend puts an accepted notification back in line",
            func() {
                let state = Outbox.empty();
                let start = 10 * HOUR;
                let ?id = send(state, "first", start + HOUR, CAPACITY, start) else return expect.bool(false).isTrue();
                acceptAll(state, start);
                expect.nat(state.backlog()).equal(0);
                let ?entry = state.entryOf(id) else return expect.bool(false).isTrue();
                state.resend(entry, start + 1);
                expect.nat(state.backlog()).equal(1);
                expect.nat(state.take(100).size()).equal(1);
            },
        );

        test(
            "an idle outbox wakes for its earliest accepted expiry, and expired ones aren't served",
            func() {
                let state = Outbox.empty();
                let start = 10 * HOUR;
                let ?id = send(state, "first", start + HOUR, CAPACITY, start) else return expect.bool(false).isTrue();
                acceptAll(state, start);
                expect.bool(state.nextDue() == ?(start + HOUR)).isTrue();
                expect.bool(state.expired(id, start + HOUR - 1)).isFalse();
                expect.bool(state.expired(id, start + HOUR)).isTrue();
                ignore state.sweep(start + HOUR);
                expect.bool(state.nextDue() == null).isTrue();
            },
        );

        test(
            "discard drops a queued notification and its content",
            func() {
                let state = Outbox.empty();
                let start = 10 * HOUR;
                let ?id = send(state, "first", start + HOUR, CAPACITY, start) else return expect.bool(false).isTrue();
                state.discard(id);
                expect.bool(state.holds(id)).isFalse();
                expect.nat(state.backlog()).equal(0);
                expect.nat(state.bytes).equal(0);
            },
        );

        test(
            "NoSuchSender parks a batch once, then drops it",
            func() {
                let state = Outbox.empty();
                let pipeline = Metrics.empty();
                let start = 10 * HOUR;
                ignore send(state, "first", start + HOUR, CAPACITY, start);
                Flush.apply(state, pipeline, state.take(100), #notAuthorized, start);
                expect.nat(state.take(100).size()).equal(0);
                expect.nat(state.backlog()).equal(1);
                let retryAt = start + HOUR * 2 / 3;
                state.promote(retryAt);
                Flush.apply(state, pipeline, state.take(100), #notAuthorized, retryAt);
                expect.nat(state.backlog()).equal(0);
            },
        );
    },
);
