import { expect; suite; test } "mo:test";

import Principal "mo:core/Principal";
import Set "mo:core/Set";

import Visibility "../lib/Visibility";
import Writers "../lib/Writers";

let writer = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let stranger = Principal.fromText("r7inp-6aaaa-aaaaa-aaabq-cai");

func writers() : Writers.Writers {
    let set = Set.empty<Principal>();
    Writers.add(set, writer);
    set;
};

func showOpt(t : ?Text) : Text = switch t { case (?v) v; case null "null" };

suite(
    "Visibility.isPrivate",
    func() {
        test(
            "keys under /private/ are private, with or without the leading slash",
            func() {
                expect.bool(Visibility.isPrivate("/private/docs/a.pdf")).isTrue();
                expect.bool(Visibility.isPrivate("private/docs/a.pdf")).isTrue();
            },
        );
        test(
            "every other key is public",
            func() {
                expect.bool(Visibility.isPrivate("/public/docs/a.pdf")).isFalse();
                expect.bool(Visibility.isPrivate("/images/logo.png")).isFalse();
                expect.bool(Visibility.isPrivate("/privateer.png")).isFalse();
                expect.bool(Visibility.isPrivate("/private")).isFalse();
            },
        );
    },
);

suite(
    "Visibility.canRead",
    func() {
        test(
            "writers read private keys; others read public keys only",
            func() {
                let set = writers();
                expect.bool(Visibility.canRead(set, writer, "/private/a.pdf")).isTrue();
                expect.bool(Visibility.canRead(set, stranger, "/private/a.pdf")).isFalse();
                expect.bool(Visibility.canRead(set, Principal.anonymous(), "/private/a.pdf")).isFalse();
                expect.bool(Visibility.canRead(set, stranger, "/public/a.png")).isTrue();
            },
        );
    },
);

suite(
    "Visibility.decodePath",
    func() {
        test(
            "decodes percent escapes the way mo:assets does, so an encoded /private/ is still private",
            func() {
                expect.text(showOpt(Visibility.decodePath("/%70rivate/a.pdf"))).equal("/private/a.pdf");
                expect.text(showOpt(Visibility.decodePath("/%70%52ivate/a"))).equal("/pRivate/a");
                expect.text(showOpt(Visibility.decodePath("/a%%b"))).equal("/a%b");
                expect.text(showOpt(Visibility.decodePath("/plain/path.png"))).equal("/plain/path.png");
                expect.bool(Visibility.isPrivate(showOpt(Visibility.decodePath("/%70rivate/a.pdf")))).isTrue();
            },
        );
        test(
            "rejects malformed escapes",
            func() {
                expect.text(showOpt(Visibility.decodePath("/a%"))).equal("null");
                expect.text(showOpt(Visibility.decodePath("/a%7"))).equal("null");
                expect.text(showOpt(Visibility.decodePath("/a%zz"))).equal("null");
            },
        );
    },
);

suite(
    "Visibility ticket keys",
    func() {
        test(
            "a streaming key round-trips its ticket",
            func() {
                let (key, ticket) = Visibility.splitTicketKey(Visibility.keyWithTicket("/private/a.pdf", "abc_-"));
                expect.text(key).equal("/private/a.pdf");
                expect.text(showOpt(ticket)).equal("abc_-");
            },
        );
        test(
            "a plain key has no ticket",
            func() {
                let (key, ticket) = Visibility.splitTicketKey("/private/a.pdf");
                expect.text(key).equal("/private/a.pdf");
                expect.text(showOpt(ticket)).equal("null");
            },
        );
    },
);
