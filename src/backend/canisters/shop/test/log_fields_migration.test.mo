import { expect; suite; test } "mo:test";

import Principal "mo:core/Principal";
import Queue "mo:core/Queue";

import LogFields "../migrations/20261113_212012_LogFields";

suite(
    "Shop migration LogFields",
    func() {
        test(
            "keeps every entry, in order, with no fields",
            func() {
                let logs = Queue.empty<{ timestamp : Int; level : { #Info; #Warning; #Error }; message : Text }>();
                Queue.pushBack(logs, { timestamp = 1; level = #Info; message = "first" });
                Queue.pushBack(logs, { timestamp = 2; level = #Error; message = "second" });
                let migrated = LogFields.migration({
                    var logState = {
                        canisterId = Principal.anonymous();
                        logs;
                        settings = { printToConsole = false };
                    };
                });
                let entries = Queue.toArray(migrated.logState.logs);
                expect.nat(entries.size()).equal(2);
                expect.text(entries[0].message).equal("first");
                expect.text(entries[1].message).equal("second");
                expect.nat(entries[0].fields.size() + entries[1].fields.size()).equal(0);
            },
        );
    },
);
