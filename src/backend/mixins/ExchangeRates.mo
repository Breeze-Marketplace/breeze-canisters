import ExchangeRates "../lib/ExchangeRates";
import XRC "../interfaces/xrc";

/// Public `getExchangeRates` endpoint over the including canister's exchange-rates state.
mixin (exchangeRates : ExchangeRates.State, xrc : XRC.xrc) {
    /// Returns the cached XRC quote for `baseAsset`/`quoteAsset` when fresh. Otherwise spends cycles on a new XRC
    /// call and caches it. Open to any caller, anonymous included (storefront checkout): new calls come out of a
    /// per-minute budget shared by all pairs and callers, and return `#RateLimited` once it is spent.
    public shared func getExchangeRates(
        baseAsset : XRC.Asset,
        quoteAsset : XRC.Asset,
    ) : async ExchangeRates.FetchExchangeRateResponse {
        await* ExchangeRates.fetchPublic(exchangeRates, xrc, baseAsset, quoteAsset);
    };
};
