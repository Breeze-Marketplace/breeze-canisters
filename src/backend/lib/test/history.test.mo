import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import History "../History";

// A history keyed by principal (a shop, as core's will be), to check the library isn't tied to orders.
type Event = { seq : Nat; shop : Principal; what : Text };

let shopA = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let shopB = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");

func record(log : History.Log<Principal, Event>, shop : Principal, what : Text) : Event {
    History.append<Principal, Event>(log, Principal.compare, shop, func seq = { seq; shop; what });
};

func whats(events : [Event]) : [Text] = events.map(func e = e.what);

suite(
    "History",
    func() {
        test(
            "numbers events in append order",
            func() {
                let log = History.empty<Principal, Event>();
                expect.nat(record(log, shopA, "created").seq).equal(0);
                expect.nat(record(log, shopB, "created").seq).equal(1);
                expect.nat(record(log, shopA, "upgraded").seq).equal(2);
                expect.nat(log.nextSeq).equal(3);
            },
        );

        test(
            "reads one subject's events in order, and nothing for an unknown subject",
            func() {
                let log = History.empty<Principal, Event>();
                ignore record(log, shopA, "created");
                ignore record(log, shopB, "created");
                ignore record(log, shopA, "upgraded");
                ignore record(log, shopB, "hidden");
                ignore record(log, shopA, "handed over");
                let ofA = History.ofSubject(log, Principal.compare, shopA);
                expect.array<Text>(whats(ofA), func t = t, func(a, b) = a == b).equal(["created", "upgraded", "handed over"]);
                let ofB = History.ofSubject(log, Principal.compare, shopB);
                expect.array<Text>(whats(ofB), func t = t, func(a, b) = a == b).equal(["created", "hidden"]);
                let other = Principal.fromText("aaaaa-aa");
                expect.nat(History.ofSubject(log, Principal.compare, other).size()).equal(0);
            },
        );

        test(
            "reads one subject's latest event, and nothing for an unknown subject",
            func() {
                let log = History.empty<Principal, Event>();
                expect.bool(History.lastOfSubject(log, Principal.compare, shopA) == null).isTrue();
                ignore record(log, shopA, "created");
                ignore record(log, shopB, "created");
                ignore record(log, shopA, "upgraded");
                ignore record(log, shopB, "hidden");
                switch (History.lastOfSubject(log, Principal.compare, shopA)) {
                    case (?e) expect.text(e.what).equal("upgraded");
                    case null assert false;
                };
                switch (History.lastOfSubject(log, Principal.compare, shopB)) {
                    case (?e) expect.text(e.what).equal("hidden");
                    case null assert false;
                };
                expect.bool(History.lastOfSubject(log, Principal.compare, Principal.fromText("aaaaa-aa")) == null).isTrue();
            },
        );

        test(
            "pages the whole log after a sequence number",
            func() {
                let log = History.empty<Principal, Event>();
                for (i in [0, 1, 2, 3, 4].values()) {
                    ignore record(log, if (i % 2 == 0) shopA else shopB, "e" # debug_show i);
                };
                let first = History.listAfter(log, null, ?2);
                expect.array<Text>(whats(first.items), func t = t, func(a, b) = a == b).equal(["e0", "e1"]);
                expect.bool(first.next == ?1).isTrue();
                let rest = History.listAfter(log, first.next, ?10);
                expect.array<Text>(whats(rest.items), func t = t, func(a, b) = a == b).equal(["e2", "e3", "e4"]);
                expect.bool(rest.next == null).isTrue();
                expect.nat(History.listAfter(log, ?4, null).items.size()).equal(0);
            },
        );
    },
);
