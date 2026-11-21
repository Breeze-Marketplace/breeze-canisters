// @testmode replica
// Replica mode: each async call is a real message, so a trap rolls back only the code since the
// last `await` and runs `finally`, as on mainnet (BRE-68). The interpreter stops at the first trap.
import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Error "mo:core/Error";
import List "mo:core/List";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Runtime "mo:core/Runtime";
import Time "mo:core/Time";

import Map "mo:map/Map";

import ShopCreationAPI "../lib";
import { mockLedgers; type MockLedgerState } "../mock";
import Logger "../../../../../lib/Logger";

persistent actor {
    let core = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
    let alice = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
    let shopId = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");
    let FEE = 10_000;
    let PRICE = 5_000_000;
    let refundTo = { owner = alice; subaccount = null };

    type Setup = {
        api : ShopCreationAPI.API;
        ledger : MockLedgerState;
        clock : { var now : Time.Time };
        /// Makes the logger trap, to stand in for any trap in claim's or refund's own code after an await.
        traps : { var onError : Bool; var onInfo : Bool };
        /// What `findShop` returns: the shop registry as core would see it.
        registry : { var shop : ?Principal };
    };

    func setup(balance : Nat) : Setup {
        let mocked = mockLedgers(balance, FEE);
        let clock = { var now : Time.Time = 1_000_000_000_000 };
        let traps = { var onError = false; var onInfo = false };
        let registry : { var shop : ?Principal } = { var shop = null };
        let api = ShopCreationAPI.API({
            state = ShopCreationAPI.newState();
            self = core;
            ledgers = mocked.ledgers;
            shopNameTaken = func(_ : Text) : Bool { false };
            shopSlugTaken = func(_ : Text) : Bool { false };
            findShop = func(_ : Text, _ : Principal) : ?Principal {
                registry.shop;
            };
            now = func() : Time.Time { clock.now };
            logger = {
                info = func(_ : Text) {
                    if (traps.onInfo) Runtime.trap("info trapped");
                };
                warning = func(_ : Text) {};
                error = func(_ : Text) {
                    if (traps.onError) Runtime.trap("error trapped");
                };
                infoWith = func(_ : Text, _ : [Logger.Field]) {
                    if (traps.onInfo) Runtime.trap("info trapped");
                };
                warningWith = func(_ : Text, _ : [Logger.Field]) {};
                errorWith = func(_ : Text, _ : [Logger.Field]) {
                    if (traps.onError) Runtime.trap("error trapped");
                };
            };
        });
        { api; ledger = mocked.state; clock; traps; registry };
    };

    func newQuote(api : ShopCreationAPI.API) : Nat {
        let req = {
            name = "shop";
            description = "";
            normalizedName = "shop";
            slug = "shop";
            currency = #ICP;
            amount = PRICE;
        };
        switch (ShopCreationAPI.createQuote(api, alice, req)) {
            case (#ok(view)) { view.id };
            case (#err(e)) {
                Runtime.trap("createQuote failed: " # debug_show (e));
            };
        };
    };

    func status(api : ShopCreationAPI.API, id : Nat) : ShopCreationAPI.QuoteStatus {
        switch (ShopCreationAPI.getQuote(api, alice, id)) {
            case (?view) { view.status };
            case (null) { Runtime.trap("quote not found") };
        };
    };

    /// Puts a quote in the state a pre-BRE-68 trap left it in.
    func strand(api : ShopCreationAPI.API, id : Nat, stuck : ShopCreationAPI.QuoteStatus) {
        let ?quote = Map.get(api.state.quotes, Map.nhash, id) else Runtime.trap("no quote");
        Map.set(api.state.quotes, Map.nhash, id, { quote with status = stuck });
    };

    func createsShop(_ : ShopCreationAPI.Quote) : async Result<Principal, Text> {
        #ok(shopId);
    };

    func failsToCreate(_ : ShopCreationAPI.Quote) : async Result<Principal, Text> {
        #err("out of cycles");
    };

    /// Runs `call` and reports whether it trapped (the caller sees a trap as a rejected call).
    func trapped(call : () -> async ()) : async Bool {
        try { await call(); false } catch (_) { true };
    };

    public func runTests() : async () {
        await suite(
            "claim",
            func() : async () {
                await test(
                    "a trap after createShop returns leaves the quote paid and retryable",
                    func() : async () {
                        let { api; traps } = setup(PRICE);
                        let id = newQuote(api);
                        traps.onError := true;
                        let didTrap = await trapped(func() : async () { ignore await ShopCreationAPI.claim(api, alice, id, failsToCreate) });
                        expect.bool(didTrap).isTrue();
                        // The deposit was confirmed before the trap, so the quote is paid, not pending.
                        expect.bool(status(api, id) == #Paid).isTrue();
                        expect.nat(ShopCreationAPI.listStuck(api).size()).equal(0);

                        traps.onError := false;
                        expect.bool((await ShopCreationAPI.claim(api, alice, id, createsShop)) == #ok(shopId)).isTrue();
                    },
                );

                await test(
                    "a createShop that traps leaves the quote paid",
                    func() : async () {
                        let { api } = setup(PRICE);
                        let id = newQuote(api);
                        let res = await ShopCreationAPI.claim(
                            api,
                            alice,
                            id,
                            func(_ : ShopCreationAPI.Quote) : async Result<Principal, Text> {
                                Runtime.trap("install trapped");
                            },
                        );
                        switch (res) {
                            case (#err(#CreationFailed(_))) {};
                            case (_) {
                                Runtime.trap("expected #CreationFailed, got " # debug_show (res));
                            };
                        };
                        expect.bool(status(api, id) == #Paid).isTrue();
                    },
                );

                await test(
                    "a creation that fails after registering its shop marks the quote created",
                    func() : async () {
                        let { api; registry } = setup(PRICE);
                        let id = newQuote(api);
                        let res = await ShopCreationAPI.claim(
                            api,
                            alice,
                            id,
                            func(_ : ShopCreationAPI.Quote) : async Result<Principal, Text> {
                                registry.shop := ?shopId;
                                throw Error.reject("setOwner failed");
                            },
                        );
                        expect.bool(res == #ok(shopId)).isTrue();
                        expect.bool(status(api, id) == #Created(shopId)).isTrue();
                        // A retry returns the same shop instead of creating a second one.
                        expect.bool((await ShopCreationAPI.claim(api, alice, id, failsToCreate)) == #ok(shopId)).isTrue();
                    },
                );
            },
        );

        await suite(
            "refund",
            func() : async () {
                await test(
                    "a ledger transfer that traps leaves the quote open, and a retry sends once",
                    func() : async () {
                        let { api; ledger } = setup(PRICE);
                        let id = newQuote(api);
                        ledger.trapTransfers := true;
                        switch (await ShopCreationAPI.refund(api, alice, id, refundTo)) {
                            case (#err(#LedgerError(_))) {};
                            case (other) {
                                Runtime.trap("expected #LedgerError, got " # debug_show (other));
                            };
                        };
                        expect.bool(status(api, id) == #Pending).isTrue();

                        ledger.trapTransfers := false;
                        expect.bool((await ShopCreationAPI.refund(api, alice, id, refundTo)) == #ok(PRICE - FEE)).isTrue();
                        expect.nat(List.size(ledger.transfers)).equal(1);
                        expect.bool(status(api, id) == #Refunded).isTrue();
                    },
                );

                await test(
                    "a trap after the transfer went out unlocks the quote without refunding twice",
                    func() : async () {
                        let { api; ledger; clock; traps } = setup(PRICE);
                        let id = newQuote(api);
                        // Paid but not claimed, as after a failed creation.
                        ignore await ShopCreationAPI.claim(api, alice, id, failsToCreate);
                        expect.bool(status(api, id) == #Paid).isTrue();

                        traps.onInfo := true;
                        let didTrap = await trapped(func() : async () { ignore await ShopCreationAPI.refund(api, alice, id, refundTo) });
                        expect.bool(didTrap).isTrue();
                        expect.nat(List.size(ledger.transfers)).equal(1);
                        let ?sent = List.get(ledger.transfers, 0) else Runtime.trap("no transfer");
                        expect.nat64(sent.createdAtTime).equal(Nat64.fromIntWrap(clock.now));

                        // Unlocked, but back to #Pending: the deposit is gone, so it must be checked again.
                        expect.bool(status(api, id) == #Pending).isTrue();
                        expect.nat(ShopCreationAPI.listStuck(api).size()).equal(0);
                        traps.onInfo := false;
                        expect.bool((await ShopCreationAPI.refund(api, alice, id, refundTo)) == #err(#NothingToRefund)).isTrue();
                        expect.bool((await ShopCreationAPI.claim(api, alice, id, createsShop)) == #err(#NotPaid({ required = PRICE; received = 0 }))).isTrue();
                        expect.nat(List.size(ledger.transfers)).equal(1);
                    },
                );
            },
        );

        await suite(
            "releaseStuck",
            func() : async () {
                await test(
                    "lists a stuck quote and releases it as paid when the deposit covers it",
                    func() : async () {
                        let { api } = setup(PRICE);
                        let id = newQuote(api);
                        strand(api, id, #Creating);
                        expect.nat(ShopCreationAPI.listStuck(api).size()).equal(1);
                        expect.bool((await ShopCreationAPI.claim(api, alice, id, createsShop)) == #err(#InProgress)).isTrue();

                        expect.bool((await ShopCreationAPI.releaseStuck(api, id)) == #ok(#Paid)).isTrue();
                        expect.nat(ShopCreationAPI.listStuck(api).size()).equal(0);
                        expect.bool((await ShopCreationAPI.releaseStuck(api, id)) == #err(#NotStuck)).isTrue();
                        expect.bool((await ShopCreationAPI.claim(api, alice, id, createsShop)) == #ok(shopId)).isTrue();
                    },
                );

                await test(
                    "releases a stuck refund with an empty deposit as pending",
                    func() : async () {
                        let { api; ledger } = setup(PRICE);
                        let id = newQuote(api);
                        strand(api, id, #Refunding);
                        ledger.balance := 0;
                        expect.bool((await ShopCreationAPI.releaseStuck(api, id)) == #ok(#Pending)).isTrue();
                    },
                );

                await test(
                    "marks a stuck quote created when its shop is registered",
                    func() : async () {
                        let { api; registry } = setup(PRICE);
                        let id = newQuote(api);
                        strand(api, id, #Creating);
                        registry.shop := ?shopId;
                        expect.bool((await ShopCreationAPI.releaseStuck(api, id)) == #ok(#Created(shopId))).isTrue();
                        expect.bool(ShopCreationAPI.nameUnavailable(api, "shop", core)).isFalse();
                    },
                );

                await test(
                    "refuses a quote whose claim is still running",
                    func() : async () {
                        let { api } = setup(PRICE);
                        let id = newQuote(api);
                        var nested : ?Result<ShopCreationAPI.QuoteStatus, ShopCreationAPI.ReleaseError> = null;
                        let res = await ShopCreationAPI.claim(
                            api,
                            alice,
                            id,
                            func(_ : ShopCreationAPI.Quote) : async Result<Principal, Text> {
                                expect.nat(ShopCreationAPI.listStuck(api).size()).equal(0);
                                nested := ?(await ShopCreationAPI.releaseStuck(api, id));
                                #ok(shopId);
                            },
                        );
                        expect.bool(res == #ok(shopId)).isTrue();
                        expect.bool(nested == ?#err(#InProgress)).isTrue();
                    },
                );
            },
        );
    };
};
