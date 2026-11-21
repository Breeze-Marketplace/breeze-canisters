import { expect; suite; test } "mo:test";

import Principal "mo:core/Principal";
import Set "mo:core/Set";

import Writers "../lib/Writers";

let core = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
let owner = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let admin = Principal.fromText("r7inp-6aaaa-aaaaa-aaabq-cai");

func fresh() : Writers.Writers {
    let writers = Set.empty<Principal>();
    Writers.add(writers, core);
    writers;
};

suite(
    "Writers",
    func() {
        test(
            "adding twice keeps one entry",
            func() {
                let writers = fresh();
                Writers.add(writers, owner);
                Writers.add(writers, owner);
                expect.nat(writers.size()).equal(2);
            },
        );

        test(
            "removes a writer, who is then refused",
            func() {
                let writers = fresh();
                Writers.add(writers, owner);
                Writers.add(writers, admin);
                assert Writers.remove(writers, core, admin) == #ok;
                expect.bool(Writers.isWriter(writers, admin)).isFalse();
                expect.bool(Writers.isWriter(writers, owner)).isTrue();
            },
        );

        test(
            "refuses to remove the creator",
            func() {
                let writers = fresh();
                Writers.add(writers, owner);
                assert Writers.remove(writers, core, core) == #err(#creator);
                expect.bool(Writers.isWriter(writers, core)).isTrue();
            },
        );

        test(
            "refuses to remove the last writer",
            func() {
                let writers = Set.empty<Principal>();
                Writers.add(writers, owner);
                assert Writers.remove(writers, core, owner) == #err(#last);
                expect.bool(Writers.isWriter(writers, owner)).isTrue();
            },
        );

        test(
            "removing someone who isn't a writer is a no-op",
            func() {
                let writers = fresh();
                assert Writers.remove(writers, core, admin) == #ok;
                expect.nat(writers.size()).equal(1);
            },
        );
    },
);
