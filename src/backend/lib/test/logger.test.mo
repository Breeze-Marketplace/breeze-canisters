import { expect; suite; test } "mo:test";

import Principal "mo:core/Principal";

import Logger "../Logger";

let shop = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");

suite(
    "Logger fields",
    func() {
        test(
            "stores fields with the entry, and none for plain messages",
            func() {
                let logger = Logger.new(shop, null);
                Logger.info(logger, "plain");
                Logger.errorWith(logger, "Sync failed", [("shop", #principal shop), ("batch", #nat 3)]);
                let logs = Logger.recent(logger, null);
                expect.nat(logs.size()).equal(2);
                expect.nat(logs[0].fields.size()).equal(2);
                expect.nat(logs[1].fields.size()).equal(0);
            },
        );
        test(
            "formats fields as key=value after the message",
            func() {
                let log = {
                    timestamp = 0;
                    level = #Warning;
                    message = "Released stuck quote";
                    fields = [("quote", #nat 7), ("refunded", #bool false), ("delta", #int(-2)), ("shop", #principal shop), ("status", #text "paid")];
                };
                expect.text(Logger.format(log)).equal(
                    "[WARN] Released stuck quote quote=7 refunded=false delta=-2 shop=rdmx6-jaaaa-aaaaa-aaadq-cai status=paid"
                );
                expect.text(Logger.format({ log with fields = [] })).equal("[WARN] Released stuck quote");
            },
        );
    },
);
