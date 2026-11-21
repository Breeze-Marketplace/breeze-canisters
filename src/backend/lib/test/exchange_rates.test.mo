import { expect; suite; test } "mo:test";
import Nat "mo:core/Nat";
import Map "mo:map/Map";

import ExchangeRates "../ExchangeRates";
import XRC "../../interfaces/xrc";

let usd : XRC.Asset = { class_ = #FiatCurrency; symbol = "USD" };
let icp : XRC.Asset = { class_ = #Cryptocurrency; symbol = "ICP" };
let pair = (usd, icp);
let minute : Int = 60_000_000_000;

let rate : XRC.ExchangeRate = {
    base_asset = usd;
    quote_asset = icp;
    timestamp = 0;
    rate = 25_000_000;
    metadata = {
        decimals = 8;
        base_asset_num_queried_sources = 1;
        base_asset_num_received_rates = 1;
        quote_asset_num_queried_sources = 1;
        quote_asset_num_received_rates = 1;
        standard_deviation = 0;
        forex_timestamp = null;
    };
};

func newState() : ExchangeRates.State = ExchangeRates.newState(Map.new());

func describe(l : ExchangeRates.Lookup) : Text = switch (l) {
    case (#fresh(_)) "fresh";
    case (#failed(_)) "failed";
    case (#inFlight({ stale = ?_ })) "inFlight with stale";
    case (#inFlight({ stale = null })) "inFlight";
    case (#mustFetch) "mustFetch";
};

suite(
    "ExchangeRates failure cache",
    func() {
        test(
            "remembers an XRC error for a minute, then fetches again",
            func() {
                let state = newState();
                ignore ExchangeRates.record(state, pair, #Err(#RateLimited), 0);
                expect.text(describe(ExchangeRates.lookup(state, pair, minute - 1))).equal("failed");
                expect.text(describe(ExchangeRates.lookup(state, pair, minute))).equal("mustFetch");
            },
        );
        test(
            "returns the cached error itself",
            func() {
                let state = newState();
                ignore ExchangeRates.record(state, pair, #Err(#ForexAssetsNotFound), 0);
                switch (ExchangeRates.lookup(state, pair, 1)) {
                    case (#failed(#ForexAssetsNotFound)) {};
                    case (other) {
                        expect.text(describe(other)).equal("failed");
                    };
                };
            },
        );
        test(
            "a success clears the failure",
            func() {
                let state = newState();
                ignore ExchangeRates.record(state, pair, #Err(#Pending), 0);
                ignore ExchangeRates.record(state, pair, #Ok(rate), 1);
                expect.nat(Map.size(state.failures)).equal(0);
                expect.text(describe(ExchangeRates.lookup(state, pair, 2))).equal("fresh");
            },
        );
        test(
            "an expired rate is fetched again even after a later failure expires",
            func() {
                let state = newState();
                ignore ExchangeRates.record(state, pair, #Ok(rate), 0);
                expect.text(describe(ExchangeRates.lookup(state, pair, ExchangeRates.CACHE_TTL - 1))).equal("fresh");
                ignore ExchangeRates.record(state, pair, #Err(#RateLimited), ExchangeRates.CACHE_TTL);
                expect.text(describe(ExchangeRates.lookup(state, pair, ExchangeRates.CACHE_TTL + 1))).equal("failed");
                expect.text(describe(ExchangeRates.lookup(state, pair, ExchangeRates.CACHE_TTL + minute))).equal("mustFetch");
            },
        );
        test(
            "keys failures by ordered pair",
            func() {
                let state = newState();
                ignore ExchangeRates.record(state, pair, #Err(#RateLimited), 0);
                expect.text(describe(ExchangeRates.lookup(state, (icp, usd), 1))).equal("mustFetch");
            },
        );
    },
);

suite(
    "ExchangeRates max age",
    func() {
        test(
            "a caller with a shorter max age refetches a rate the cache still holds",
            func() {
                let state = newState();
                ignore ExchangeRates.record(state, pair, #Ok(rate), 0);
                expect.text(describe(ExchangeRates.lookupWithin(state, pair, ExchangeRates.QUOTE_MAX_AGE - 1, ExchangeRates.QUOTE_MAX_AGE))).equal("fresh");
                expect.text(describe(ExchangeRates.lookupWithin(state, pair, ExchangeRates.QUOTE_MAX_AGE, ExchangeRates.QUOTE_MAX_AGE))).equal("mustFetch");
                expect.text(describe(ExchangeRates.lookup(state, pair, ExchangeRates.QUOTE_MAX_AGE))).equal("fresh");
            },
        );
        test(
            "is not offered an expired rate during a refresh",
            func() {
                let state = newState();
                ignore ExchangeRates.record(state, pair, #Ok(rate), 0);
                Map.set(state.inFlight, ExchangeRates.assetPairHash, pair, ());
                expect.text(describe(ExchangeRates.lookupWithin(state, pair, ExchangeRates.QUOTE_MAX_AGE, ExchangeRates.QUOTE_MAX_AGE))).equal("inFlight");
            },
        );
    },
);

suite(
    "ExchangeRates in-flight fetches",
    func() {
        test(
            "a pair being fetched is not fetched again",
            func() {
                let state = newState();
                Map.set(state.inFlight, ExchangeRates.assetPairHash, pair, ());
                expect.text(describe(ExchangeRates.lookup(state, pair, 0))).equal("inFlight");
            },
        );
        test(
            "offers the expired rate while it is refreshed",
            func() {
                let state = newState();
                ignore ExchangeRates.record(state, pair, #Ok(rate), 0);
                Map.set(state.inFlight, ExchangeRates.assetPairHash, pair, ());
                expect.text(describe(ExchangeRates.lookup(state, pair, ExchangeRates.CACHE_TTL))).equal("inFlight with stale");
            },
        );
    },
);

suite(
    "ExchangeRates public budget",
    func() {
        test(
            "allows PUBLIC_FETCHES_PER_WINDOW fetches per window",
            func() {
                let state = newState();
                var allowed = 0;
                for (_ in Nat.range(0, ExchangeRates.PUBLIC_FETCHES_PER_WINDOW + 5)) {
                    if (ExchangeRates.takePublicBudget(state, minute)) allowed += 1;
                };
                expect.nat(allowed).equal(ExchangeRates.PUBLIC_FETCHES_PER_WINDOW);
                expect.bool(ExchangeRates.takePublicBudget(state, 2 * minute - 1)).equal(false);
                expect.bool(ExchangeRates.takePublicBudget(state, 2 * minute)).equal(true);
            },
        );
    },
);
