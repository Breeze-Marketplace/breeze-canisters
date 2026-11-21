import Cycles "mo:core/Cycles";
import Error "mo:core/Error";
import Float "mo:core/Float";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import { type Result } "mo:core/Result";
import Time "mo:core/Time";
import Map "mo:map/Map";

import Assets "Assets";
import XRC "../interfaces/xrc";

/// XRC exchange rates with a per-canister cache, shared by core and shop (see `mixins/ExchangeRates`).
///
/// Each XRC call costs `CYCLES_NEEDED_FOR_XRC_CALL`, so a pair is fetched at most once at a time,
/// failures are remembered for `FAILURE_TTL`, and the public endpoint, which takes any pair, has a
/// per-minute budget of new fetches (BRE-63).
module {
    public type ExchangeRateCacheEntry = {
        xrcResponse : XRC.ExchangeRate;
        descaledRate : Float.Float;
        lastUpdated : Time.Time;
    };

    public type AssetPair = (XRC.Asset, XRC.Asset);

    /// Successful rates. Stable: it survives upgrades.
    public type Cache = Map.Map<AssetPair, ExchangeRateCacheEntry>;

    public type FetchError = {
        #InsufficientCycles;
        #XRCError : XRC.ExchangeRateError;
    };

    public type FetchExchangeRateResponse = Result<ExchangeRateCacheEntry, FetchError>;

    public type Failure = { error : XRC.ExchangeRateError; at : Time.Time };

    /// Everything `fetch` reads and writes. Only `rates` is stable; the rest is transient
    /// (`newState` in a `transient let`), since losing it on upgrade costs at most one XRC call per pair.
    public type State = {
        rates : Cache;
        failures : Map.Map<AssetPair, Failure>;
        inFlight : Map.Map<AssetPair, ()>;
        publicBudget : { var windowStart : Time.Time; var used : Nat };
    };

    public let CYCLES_NEEDED_FOR_XRC_CALL = 1_000_000_000;
    public let CACHE_TTL : Time.Time = 1_800_000_000_000; // 30 minutes
    /// The oldest rate a shop creation quote may lock in (BRE-120): the quote then holds it for 30 minutes more.
    public let QUOTE_MAX_AGE : Time.Time = 300_000_000_000; // 5 minutes
    public let FAILURE_TTL : Time.Time = 60_000_000_000; // 1 minute
    public let PUBLIC_BUDGET_WINDOW : Time.Time = 60_000_000_000; // 1 minute
    /// New XRC calls `getExchangeRates` may start per `PUBLIC_BUDGET_WINDOW`, across all pairs.
    /// The app uses two or three pairs, each fetched about every `CACHE_TTL`.
    public let PUBLIC_FETCHES_PER_WINDOW = 3;

    public let assetPairHash = (Assets.hashAssetPair, Assets.assetPairsEquivalent);

    public func newState(rates : Cache) : State {
        {
            rates;
            failures = Map.new();
            inFlight = Map.new();
            publicBudget = { var windowStart = 0; var used = 0 };
        };
    };

    public type Lookup = {
        #fresh : ExchangeRateCacheEntry;
        #failed : XRC.ExchangeRateError;
        /// Another message is fetching this pair; `stale` is the expired entry, if any.
        #inFlight : { stale : ?ExchangeRateCacheEntry };
        #mustFetch;
    };

    /// What `fetch` can answer for `pair` at `now` without calling XRC.
    public func lookup(state : State, pair : AssetPair, now : Time.Time) : Lookup {
        lookupWithin(state, pair, now, CACHE_TTL);
    };

    /// `lookup` for a caller that wants a rate at most `maxAge` old (at most `CACHE_TTL`, the cache's
    /// own limit). Such a caller is never offered an expired rate while a refresh runs.
    public func lookupWithin(state : State, pair : AssetPair, now : Time.Time, maxAge : Time.Time) : Lookup {
        let cached = Map.get(state.rates, assetPairHash, pair);
        switch (cached) {
            case (?entry) {
                if (now - entry.lastUpdated < Int.min(maxAge, CACHE_TTL)) return #fresh(entry);
            };
            case null {};
        };
        if (Map.has(state.inFlight, assetPairHash, pair)) {
            return #inFlight({
                stale = if (maxAge >= CACHE_TTL) cached else null;
            });
        };
        switch (Map.get(state.failures, assetPairHash, pair)) {
            case (?failure) {
                if (now - failure.at < FAILURE_TTL) return #failed(failure.error);
            };
            case null {};
        };
        #mustFetch;
    };

    /// Records XRC's answer for `pair` and returns it as a fetch response.
    public func record(
        state : State,
        pair : AssetPair,
        result : { #Ok : XRC.ExchangeRate; #Err : XRC.ExchangeRateError },
        now : Time.Time,
    ) : FetchExchangeRateResponse {
        switch (result) {
            case (#Ok(rate)) {
                let entry = {
                    xrcResponse = rate;
                    descaledRate = rate.rate.toNat().toFloat() / (10 ** rate.metadata.decimals.toNat()).toFloat();
                    lastUpdated = now;
                };
                Map.set(state.rates, assetPairHash, pair, entry);
                Map.delete(state.failures, assetPairHash, pair);
                #ok(entry);
            };
            case (#Err(error)) {
                Map.set(state.failures, assetPairHash, pair, { error; at = now });
                #err(#XRCError(error));
            };
        };
    };

    /// Takes one fetch from the public budget at `now`; false when this window's budget is spent.
    public func takePublicBudget(state : State, now : Time.Time) : Bool {
        let budget = state.publicBudget;
        if (now - budget.windowStart >= PUBLIC_BUDGET_WINDOW) {
            budget.windowStart := now;
            budget.used := 0;
        };
        if (budget.used >= PUBLIC_FETCHES_PER_WINDOW) return false;
        budget.used += 1;
        true;
    };

    /// Returns the cached rate for `baseAsset`/`quoteAsset` while it is fresh, or a failure from the last
    /// `FAILURE_TTL`; otherwise spends cycles on one XRC call and caches its result. While that call runs,
    /// other callers get the expired entry if there is one, else `#Pending` (a message can't await a call
    /// another message started).
    public func fetch(
        state : State,
        xrc : XRC.xrc,
        baseAsset : XRC.Asset,
        quoteAsset : XRC.Asset,
    ) : async* FetchExchangeRateResponse {
        await* fetchWith(state, xrc, (baseAsset, quoteAsset), CACHE_TTL, func() = true);
    };

    /// `fetch` for a caller that needs a rate at most `maxAge` old: a cached rate older than that is
    /// fetched again (within the failure cache and one-call-at-a-time rules of `fetch`).
    public func fetchWithin(
        state : State,
        xrc : XRC.xrc,
        baseAsset : XRC.Asset,
        quoteAsset : XRC.Asset,
        maxAge : Time.Time,
    ) : async* FetchExchangeRateResponse {
        await* fetchWith(state, xrc, (baseAsset, quoteAsset), maxAge, func() = true);
    };

    /// `fetch` for callers that choose the pair: a new XRC call also spends from the public budget,
    /// and gets `#RateLimited` when it is spent.
    public func fetchPublic(
        state : State,
        xrc : XRC.xrc,
        baseAsset : XRC.Asset,
        quoteAsset : XRC.Asset,
    ) : async* FetchExchangeRateResponse {
        await* fetchWith(state, xrc, (baseAsset, quoteAsset), CACHE_TTL, func() = takePublicBudget(state, Time.now()));
    };

    func fetchWith(
        state : State,
        xrc : XRC.xrc,
        pair : AssetPair,
        maxAge : Time.Time,
        allowFetch : () -> Bool,
    ) : async* FetchExchangeRateResponse {
        switch (lookupWithin(state, pair, Time.now(), maxAge)) {
            case (#fresh(entry)) { return #ok(entry) };
            case (#failed(error)) { return #err(#XRCError(error)) };
            case (#inFlight({ stale = ?entry })) { return #ok(entry) };
            case (#inFlight({ stale = null })) {
                return #err(#XRCError(#Pending));
            };
            case (#mustFetch) {};
        };

        if (Cycles.balance() < CYCLES_NEEDED_FOR_XRC_CALL) {
            return #err(#InsufficientCycles);
        };
        if (not allowFetch()) {
            return #err(#XRCError(#RateLimited));
        };

        // Ask for the previous minute: XRC may not have collected rates for the current one yet.
        let oneMinuteAgo : Nat64 = (Int.abs(Time.now()).toNat64() / 1_000_000_000) - 60;
        Map.set(state.inFlight, assetPairHash, pair, ());
        try {
            let result = await (with cycles = CYCLES_NEEDED_FOR_XRC_CALL) xrc.get_exchange_rate({
                timestamp = ?oneMinuteAgo;
                base_asset = pair.0;
                quote_asset = pair.1;
            });
            record(state, pair, result, Time.now());
        } catch (e) {
            record(state, pair, #Err(#Other({ code = 0 : Nat32; description = Error.message(e) })), Time.now());
        } finally {
            Map.delete(state.inFlight, assetPairHash, pair);
        };
    };
};
