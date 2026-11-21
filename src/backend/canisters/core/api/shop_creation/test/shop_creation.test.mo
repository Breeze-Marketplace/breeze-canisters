import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Blob "mo:core/Blob";
import Error "mo:core/Error";
import List "mo:core/List";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Runtime "mo:core/Runtime";
import Time "mo:core/Time";

import MockLogger "../../../../../lib/Logger/mock";
import TimeUtil "../../../../../lib/Time";

import ShopCreationAPI "../lib";
import { mockLedgers; type MockedTransfer } "../mock";

let core = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
let alice = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let bob = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let shopId = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");
let logger = MockLogger.bind(MockLogger.new(core));

let FEE = 10_000;
let PRICE = 5_000_000;

type Setup = {
    api : ShopCreationAPI.API;
    ledger : {
        var balance : Nat;
        var failTransfers : Bool;
        var trapTransfers : Bool;
        fee : Nat;
        transfers : List.List<MockedTransfer>;
    };
    clock : { var now : Time.Time };
};

func setup(balance : Nat, takenNames : [Text]) : Setup {
    let mocked = mockLedgers(balance, FEE);
    let clock = { var now : Time.Time = 1_000_000_000_000 };
    let api = ShopCreationAPI.API({
        state = ShopCreationAPI.newState();
        self = core;
        ledgers = mocked.ledgers;
        shopNameTaken = func(name : Text) : Bool {
            for (taken in takenNames.vals()) { if (taken == name) return true };
            false;
        };
        shopSlugTaken = func(_ : Text) : Bool { false };
        findShop = func(_ : Text, _ : Principal) : ?Principal { null };
        now = func() : Time.Time { clock.now };
        logger;
    });
    { api; ledger = mocked.state; clock };
};

func request(name : Text, amount : Nat) : ShopCreationAPI.CreateQuoteRequest {
    {
        name;
        description = "";
        normalizedName = name;
        slug = name;
        currency = #ICP;
        amount;
    };
};

func quoteId(api : ShopCreationAPI.API, caller : Principal, req : ShopCreationAPI.CreateQuoteRequest) : Nat {
    switch (ShopCreationAPI.createQuote(api, caller, req)) {
        case (#ok(view)) { view.id };
        case (#err(e)) { Runtime.trap("createQuote failed: " # debug_show (e)) };
    };
};

func createsShop(_ : ShopCreationAPI.Quote) : async Result<Principal, Text> {
    #ok(shopId);
};

func failsToCreate(_ : ShopCreationAPI.Quote) : async Result<Principal, Text> {
    #err("out of cycles");
};

func status(api : ShopCreationAPI.API, caller : Principal, id : Nat) : ShopCreationAPI.QuoteStatus {
    switch (ShopCreationAPI.getQuote(api, caller, id)) {
        case (?view) { view.status };
        case (null) { Runtime.trap("quote not found") };
    };
};

suite(
    "ShopCreationAPI",
    func() : async () {
        await test(
            "usdCentsToE8s rounds up",
            func() : async () {
                // 0.25 ICP per USD with 9 rate decimals: $10 -> 2.5 ICP.
                expect.nat(ShopCreationAPI.usdCentsToE8s(1_000, 250_000_000, 9)).equal(250_000_000);
                // 1/3 ICP per USD: $1 -> 0.33333334 ICP.
                expect.nat(ShopCreationAPI.usdCentsToE8s(100, 333_333_333, 9)).equal(33_333_334);
                expect.nat(ShopCreationAPI.usdCentsToCkusdc(1_000)).equal(10_000_000);
            },
        );

        await test(
            "deposit subaccounts are distinct and tagged",
            func() : async () {
                let a = Blob.toArray(ShopCreationAPI.depositSubaccount(1));
                let b = Blob.toArray(ShopCreationAPI.depositSubaccount(256));
                expect.nat(a.size()).equal(32);
                expect.nat8(a[0]).equal(0x53);
                expect.nat8(a[9]).equal(1);
                expect.nat8(b[8]).equal(1);
                expect.nat8(b[9]).equal(0);
            },
        );

        await suite(
            "createQuote",
            func() : async () {
                await test(
                    "rejects a name a shop already uses",
                    func() : async () {
                        let { api } = setup(0, ["taken"]);
                        expect.bool(ShopCreationAPI.createQuote(api, alice, request("taken", PRICE)) == #err(#ShopNameConflict)).isTrue();
                    },
                );

                await test(
                    "reserves the name against other users until the quote expires",
                    func() : async () {
                        let { api; clock } = setup(0, []);
                        ignore quoteId(api, alice, request("shop", PRICE));
                        expect.bool(ShopCreationAPI.createQuote(api, bob, request("shop", PRICE)) == #err(#ShopNameConflict)).isTrue();
                        // The same user may quote the name again (e.g. in another currency).
                        ignore quoteId(api, alice, request("shop", PRICE));

                        clock.now += TimeUtil.fromMinutes(ShopCreationAPI.QUOTE_TTL_MINUTES + 1);
                        ignore quoteId(api, bob, request("shop", PRICE));
                    },
                );

                await test(
                    "caps open unpaid quotes per user",
                    func() : async () {
                        let { api } = setup(0, []);
                        ignore quoteId(api, alice, request("a", PRICE));
                        ignore quoteId(api, alice, request("b", PRICE));
                        ignore quoteId(api, alice, request("c", PRICE));
                        expect.bool(ShopCreationAPI.createQuote(api, alice, request("d", PRICE)) == #err(#TooManyOpenQuotes)).isTrue();
                    },
                );

                await test(
                    "a free quote starts out paid",
                    func() : async () {
                        let { api } = setup(0, []);
                        let id = quoteId(api, alice, request("free", 0));
                        expect.bool(status(api, alice, id) == #Paid).isTrue();
                    },
                );

                await test(
                    "quotes are private to their owner",
                    func() : async () {
                        let { api } = setup(0, []);
                        let id = quoteId(api, alice, request("shop", PRICE));
                        expect.bool(ShopCreationAPI.getQuote(api, bob, id) == null).isTrue();
                        expect.nat(ShopCreationAPI.listQuotes(api, bob).size()).equal(0);
                        expect.nat(ShopCreationAPI.listQuotes(api, alice).size()).equal(1);
                    },
                );
            },
        );

        await suite(
            "claim",
            func() : async () {
                await test(
                    "refuses an underpaid quote and keeps it pending",
                    func() : async () {
                        let { api } = setup(PRICE - 1, []);
                        let id = quoteId(api, alice, request("shop", PRICE));
                        let res = await ShopCreationAPI.claim(api, alice, id, createsShop);
                        expect.bool(res == #err(#NotPaid({ required = PRICE; received = PRICE - 1 }))).isTrue();
                        expect.bool(status(api, alice, id) == #Pending).isTrue();
                    },
                );

                await test(
                    "creates the shop, sweeps the deposit to core and is idempotent",
                    func() : async () {
                        let { api; ledger } = setup(PRICE + 500, []);
                        let id = quoteId(api, alice, request("shop", PRICE));
                        expect.bool((await ShopCreationAPI.claim(api, alice, id, createsShop)) == #ok(shopId)).isTrue();
                        expect.bool(status(api, alice, id) == #Created(shopId)).isTrue();

                        expect.nat(List.size(ledger.transfers)).equal(1);
                        let ?sweep = List.get(ledger.transfers, 0) else Runtime.trap("no sweep");
                        expect.nat(sweep.amount).equal(PRICE + 500 - FEE);
                        expect.principal(sweep.to.owner).equal(core);
                        expect.bool(sweep.to.subaccount == null).isTrue();

                        // A second claim returns the same shop without creating another one.
                        expect.bool((await ShopCreationAPI.claim(api, alice, id, failsToCreate)) == #ok(shopId)).isTrue();
                        // The name now belongs to the shop registry, not the quote.
                        expect.bool(ShopCreationAPI.nameUnavailable(api, "shop", bob)).isFalse();
                    },
                );

                await test(
                    "a failed creation leaves the quote paid and retryable without paying again",
                    func() : async () {
                        let { api; ledger } = setup(PRICE, []);
                        let id = quoteId(api, alice, request("shop", PRICE));
                        expect.bool((await ShopCreationAPI.claim(api, alice, id, failsToCreate)) == #err(#CreationFailed("out of cycles"))).isTrue();
                        expect.bool(status(api, alice, id) == #Paid).isTrue();
                        // The name stays reserved for alice.
                        expect.bool(ShopCreationAPI.nameUnavailable(api, "shop", bob)).isTrue();

                        ledger.balance := 0; // a paid quote doesn't look at the balance again
                        expect.bool((await ShopCreationAPI.claim(api, alice, id, createsShop)) == #ok(shopId)).isTrue();
                    },
                );

                await test(
                    "a rejected call during creation also leaves the quote paid",
                    func() : async () {
                        let { api } = setup(PRICE, []);
                        let id = quoteId(api, alice, request("shop", PRICE));
                        let res = await ShopCreationAPI.claim(
                            api,
                            alice,
                            id,
                            func(_ : ShopCreationAPI.Quote) : async Result<Principal, Text> {
                                throw Error.reject("install_code failed");
                            },
                        );
                        switch (res) {
                            case (#err(#CreationFailed(_))) {};
                            case (_) {
                                Runtime.trap("expected #CreationFailed, got " # debug_show (res));
                            };
                        };
                        expect.bool(status(api, alice, id) == #Paid).isTrue();
                    },
                );

                await test(
                    "rejects a concurrent claim while one is running",
                    func() : async () {
                        let { api } = setup(PRICE, []);
                        let id = quoteId(api, alice, request("shop", PRICE));
                        var nested : ?Result<Principal, ShopCreationAPI.ClaimError> = null;
                        let res = await ShopCreationAPI.claim(
                            api,
                            alice,
                            id,
                            func(_ : ShopCreationAPI.Quote) : async Result<Principal, Text> {
                                nested := ?(await ShopCreationAPI.claim(api, alice, id, createsShop));
                                #ok(shopId);
                            },
                        );
                        expect.bool(res == #ok(shopId)).isTrue();
                        expect.bool(nested == ?#err(#InProgress)).isTrue();
                    },
                );

                await test(
                    "only the owner can claim",
                    func() : async () {
                        let { api } = setup(PRICE, []);
                        let id = quoteId(api, alice, request("shop", PRICE));
                        expect.bool((await ShopCreationAPI.claim(api, bob, id, createsShop)) == #err(#NotFound)).isTrue();
                    },
                );

                await test(
                    "honors a late payment within the grace period, not after",
                    func() : async () {
                        let { api; clock } = setup(PRICE, []);
                        let late = quoteId(api, alice, request("late", PRICE));
                        let tooLate = quoteId(api, alice, request("toolate", PRICE));

                        clock.now += TimeUtil.fromHours(ShopCreationAPI.CLAIM_GRACE_HOURS);
                        expect.bool((await ShopCreationAPI.claim(api, alice, late, createsShop)) == #ok(shopId)).isTrue();

                        clock.now += TimeUtil.fromMinutes(ShopCreationAPI.QUOTE_TTL_MINUTES + 1);
                        expect.bool((await ShopCreationAPI.claim(api, alice, tooLate, createsShop)) == #err(#Expired)).isTrue();
                    },
                );

                await test(
                    "fails when someone else took the name after the quote expired",
                    func() : async () {
                        let { api; clock } = setup(PRICE, []);
                        let id = quoteId(api, alice, request("shop", PRICE));
                        clock.now += TimeUtil.fromMinutes(ShopCreationAPI.QUOTE_TTL_MINUTES + 1);
                        ignore quoteId(api, bob, request("shop", PRICE));
                        expect.bool((await ShopCreationAPI.claim(api, alice, id, createsShop)) == #err(#ShopNameConflict)).isTrue();
                    },
                );
            },
        );

        await suite(
            "refund",
            func() : async () {
                let refundTo = { owner = alice; subaccount = null };

                await test(
                    "returns the deposit less the fee and releases the name",
                    func() : async () {
                        let { api; ledger } = setup(PRICE, []);
                        let id = quoteId(api, alice, request("shop", PRICE));
                        expect.bool((await ShopCreationAPI.refund(api, alice, id, refundTo)) == #ok(PRICE - FEE)).isTrue();
                        expect.bool(status(api, alice, id) == #Refunded).isTrue();
                        let ?sent = List.get(ledger.transfers, 0) else Runtime.trap("no refund");
                        expect.principal(sent.to.owner).equal(alice);
                        expect.bool(ShopCreationAPI.nameUnavailable(api, "shop", bob)).isFalse();
                        expect.bool((await ShopCreationAPI.claim(api, alice, id, createsShop)) == #err(#Refunded)).isTrue();
                    },
                );

                await test(
                    "refuses an empty deposit and a claimed quote",
                    func() : async () {
                        let { api; ledger } = setup(0, []);
                        let id = quoteId(api, alice, request("shop", PRICE));
                        expect.bool((await ShopCreationAPI.refund(api, alice, id, refundTo)) == #err(#NothingToRefund)).isTrue();
                        expect.bool(status(api, alice, id) == #Pending).isTrue();

                        ledger.balance := PRICE;
                        ignore await ShopCreationAPI.claim(api, alice, id, createsShop);
                        expect.bool((await ShopCreationAPI.refund(api, alice, id, refundTo)) == #err(#AlreadyClaimed)).isTrue();
                    },
                );

                await test(
                    "keeps the quote open when the transfer fails",
                    func() : async () {
                        let { api; ledger } = setup(PRICE, []);
                        let id = quoteId(api, alice, request("shop", PRICE));
                        ledger.failTransfers := true;
                        expect.bool((await ShopCreationAPI.refund(api, alice, id, refundTo)) == #err(#LedgerError("transfer rejected"))).isTrue();
                        expect.bool(status(api, alice, id) == #Pending).isTrue();
                    },
                );
            },
        );

        await test(
            "a deposit is settled once the shop exists, after a refund, or when an unpaid quote's grace period is over (BRE-101)",
            func() : async () {
                let quote : ShopCreationAPI.Quote = {
                    id = 0;
                    owner = alice;
                    name = "shop";
                    description = "";
                    normalizedName = "shop";
                    slug = "shop";
                    currency = #ICP;
                    amount = PRICE;
                    createdAt = 0;
                    expiresAt = 1_000;
                    status = #Pending;
                    lastError = null;
                };
                let graceOver = 1_000 + TimeUtil.fromHours(ShopCreationAPI.CLAIM_GRACE_HOURS) + 1;
                expect.bool(ShopCreationAPI.depositSettled(quote, 1_001)).isFalse();
                expect.bool(ShopCreationAPI.depositSettled(quote, graceOver)).isTrue();
                expect.bool(ShopCreationAPI.depositSettled({ quote with status = #Paid }, graceOver)).isFalse();
                expect.bool(ShopCreationAPI.depositSettled({ quote with status = #Refunding }, graceOver)).isFalse();
                expect.bool(ShopCreationAPI.depositSettled({ quote with status = #Refunded }, 0)).isTrue();
                expect.bool(ShopCreationAPI.depositSettled({ quote with status = #Created(shopId) }, 0)).isTrue();
            },
        );
    },
);
