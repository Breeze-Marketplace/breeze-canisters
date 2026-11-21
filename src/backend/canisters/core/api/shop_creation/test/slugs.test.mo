import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Runtime "mo:core/Runtime";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Time "mo:core/Time";

import MockLogger "../../../../../lib/Logger/mock";
import TimeUtil "../../../../../lib/Time";

import ShopCreationAPI "../lib";
import { mockLedgers } "../mock";

// Slugs reserved with shop creation quotes (BRE-71).

let core = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
let alice = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let bob = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let shopId = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");

let FEE = 10_000;
let PRICE = 5_000_000;

type Setup = {
    api : ShopCreationAPI.API;
    clock : { var now : Time.Time };
    /// Slugs registered shops have or had.
    shopSlugs : Set.Set<Text>;
};

func setup(balance : Nat) : Setup {
    let mocked = mockLedgers(balance, FEE);
    let clock = { var now : Time.Time = 1_000_000_000_000 };
    let shopSlugs = Set.empty<Text>();
    let api = ShopCreationAPI.API({
        state = ShopCreationAPI.newState();
        self = core;
        ledgers = mocked.ledgers;
        shopNameTaken = func(_ : Text) : Bool { false };
        shopSlugTaken = func(slug : Text) : Bool {
            Set.contains(shopSlugs, Text.compare, slug);
        };
        findShop = func(_ : Text, _ : Principal) : ?Principal { null };
        now = func() : Time.Time { clock.now };
        logger = MockLogger.bind(MockLogger.new(core));
    });
    { api; clock; shopSlugs };
};

func request(name : Text, slug : Text) : ShopCreationAPI.CreateQuoteRequest {
    {
        name;
        description = "";
        normalizedName = name;
        slug;
        currency = #ICP;
        amount = PRICE;
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

await suite(
    "Quote slugs",
    func() : async () {
        await test(
            "a quote reserves its slug against other users' quotes",
            func() : async () {
                let { api } = setup(0);
                let id = quoteId(api, alice, request("one", "heron"));
                switch (ShopCreationAPI.getQuote(api, alice, id)) {
                    case (?view) { expect.text(view.slug).equal("heron") };
                    case null { assert false };
                };
                expect.bool(ShopCreationAPI.createQuote(api, bob, request("two", "heron")) == #err(#ShopSlugConflict)).isTrue();
                expect.bool(ShopCreationAPI.slugUnavailable(api, "heron", bob)).isTrue();
                // The same user may ask again for their own slug.
                expect.bool(ShopCreationAPI.slugUnavailable(api, "heron", alice)).isFalse();
                expect.bool(ShopCreationAPI.slugReserved(api.state, "heron", api.now())).isTrue();
            },
        );

        await test(
            "a slug a shop has or had isn't free for a quote",
            func() : async () {
                let { api; shopSlugs } = setup(0);
                Set.add(shopSlugs, Text.compare, "heron");
                expect.bool(ShopCreationAPI.createQuote(api, alice, request("one", "heron")) == #err(#ShopSlugConflict)).isTrue();
            },
        );

        await test(
            "an expired unpaid quote no longer holds its slug",
            func() : async () {
                let { api; clock } = setup(0);
                ignore quoteId(api, alice, request("one", "heron"));
                clock.now += TimeUtil.fromMinutes(ShopCreationAPI.QUOTE_TTL_MINUTES + 1);
                expect.bool(ShopCreationAPI.slugReserved(api.state, "heron", api.now())).isFalse();
                ignore quoteId(api, bob, request("two", "heron"));
            },
        );

        await test(
            "a refund releases the slug",
            func() : async () {
                let { api } = setup(PRICE);
                let id = quoteId(api, alice, request("one", "heron"));
                switch (await ShopCreationAPI.refund(api, alice, id, { owner = alice; subaccount = null })) {
                    case (#ok(_)) {};
                    case (#err(e)) { Runtime.trap(debug_show (e)) };
                };
                expect.bool(ShopCreationAPI.slugReserved(api.state, "heron", api.now())).isFalse();
                ignore quoteId(api, bob, request("two", "heron"));
            },
        );

        await test(
            "creating the shop releases the reservation",
            func() : async () {
                let { api; shopSlugs } = setup(PRICE);
                let id = quoteId(api, alice, request("one", "heron"));
                let res = await ShopCreationAPI.claim(
                    api,
                    alice,
                    id,
                    func(q : ShopCreationAPI.Quote) : async Result<Principal, Text> {
                        // What core does: the new shop records its slug.
                        Set.add(shopSlugs, Text.compare, q.slug);
                        await createsShop(q);
                    },
                );
                expect.bool(res == #ok(shopId)).isTrue();
                expect.bool(ShopCreationAPI.slugReserved(api.state, "heron", api.now())).isFalse();
                // The shop has it now, so it's still not free.
                expect.bool(ShopCreationAPI.slugUnavailable(api, "heron", bob)).isTrue();
            },
        );

        await test(
            "a claim fails if its slug went to a shop meanwhile",
            func() : async () {
                let { api; clock; shopSlugs } = setup(PRICE);
                let id = quoteId(api, alice, request("one", "heron"));
                // The quote expired unpaid and someone else's shop took the slug; then alice paid within the grace period.
                clock.now += TimeUtil.fromMinutes(ShopCreationAPI.QUOTE_TTL_MINUTES + 1);
                Set.add(shopSlugs, Text.compare, "heron");
                expect.bool((await ShopCreationAPI.claim(api, alice, id, createsShop)) == #err(#ShopSlugConflict)).isTrue();
            },
        );
    },
);
