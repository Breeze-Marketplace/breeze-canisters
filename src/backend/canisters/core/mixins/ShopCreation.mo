import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Time "mo:core/Time";
import Map "mo:map/Map";

import XRC "canister:xrc";

import ExchangeRates "../../../lib/ExchangeRates";
import Pagination "../../../lib/Pagination";
import AdminAPI "../api/admin";
import PlatformPermissions "../../../lib/PlatformPermissions";
import ShopAPI "../api/shop";
import ShopCreationAPI "../api/shop_creation";
import Slug "../api/shop/slug";
import Types "../types";
import AlertsAPI "../api/alerts";
import HistoryAPI "../api/history";

/// Paid shop creation: price, quotes, refunds and claiming a paid quote.
mixin (
    shopCreationApi : ShopCreationAPI.API,
    adminApi : AdminAPI.API,
    shopCreationState : ShopCreationAPI.State,
    exchangeRates : ExchangeRates.State,
    userRegistry : Map.Map<Principal, Types.UserRegistryItem>,
    createShopForQuote : (ShopCreationAPI.Quote) -> async Result<Principal, Text>,
    history : HistoryAPI.State,
    // Records a platform alert and pushes it to staff who asked (BRE-211).
    recordAlert : <system>(AlertsAPI.AlertKind) -> (),
) {
    func shopCreationPriceIn(currency : ShopCreationAPI.Currency, maxRateAge : Time.Time) : async* Result<Nat, Text> {
        let usdCents = shopCreationState.priceUsdCents;
        switch (currency) {
            case (#ckUSDC) { #ok(ShopCreationAPI.usdCentsToCkusdc(usdCents)) };
            case (#ICP) {
                if (usdCents == 0) { return #ok(0) };
                switch (await* ExchangeRates.fetchWithin(exchangeRates, XRC, { class_ = #FiatCurrency; symbol = "USD" }, { class_ = #Cryptocurrency; symbol = "ICP" }, maxRateAge)) {
                    case (#ok(entry)) {
                        #ok(ShopCreationAPI.usdCentsToE8s(usdCents, entry.xrcResponse.rate, entry.xrcResponse.metadata.decimals));
                    };
                    case (#err(#InsufficientCycles)) {
                        #err("Insufficient cycles to fetch the ICP exchange rate");
                    };
                    case (#err(#XRCError(e))) {
                        #err("Failed to fetch the ICP exchange rate: " # debug_show (e));
                    };
                };
            };
        };
    };

    /// The current price of a hosted shop, in USD and in each accepted currency. Open to any caller
    /// with no limit of its own: the ICP price reads the fixed USD/ICP pair through the exchange-rate
    /// cache (BRE-63), so core makes at most one XRC call per 30 min, or one a minute while XRC
    /// fails, however often this is called (BRE-120).
    public shared func getShopCreationPrice() : async Result<Types.ShopCreationPrice, Text> {
        let icpE8s = switch (await* shopCreationPriceIn(#ICP, ExchangeRates.CACHE_TTL)) {
            case (#ok(amount)) { amount };
            case (#err(msg)) { return #err(msg) };
        };
        #ok({
            usdCents = shopCreationState.priceUsdCents;
            icpE8s;
            ckusdc = ShopCreationAPI.usdCentsToCkusdc(shopCreationState.priceUsdCents);
        });
    };

    /// Sets the hosted shop price in US cents. 0 makes shop creation free. Controllers only.
    public shared ({ caller }) func setShopCreationPrice(usdCents : Nat) : async Result<(), { #Unauthorized }> {
        if (not Principal.isController(caller)) {
            return #err(#Unauthorized);
        };
        shopCreationState.priceUsdCents := usdCents;
        ignore HistoryAPI.record(history, caller, null, #shopCreationPriceSet({ usdCents }));
        #ok;
    };

    /// A free slug for a shop called `name`, for the create-shop form to suggest (BRE-71). Not
    /// reserved: `createShopQuote` reserves it.
    public query ({ caller }) func suggestShopSlug(name : Text) : async Text {
        Slug.unique(Slug.fromName(name), func s = not ShopCreationAPI.slugUnavailable(shopCreationApi, s, caller));
    };

    /// Whether `slug` is valid and free for a new shop of the caller's.
    public query ({ caller }) func checkShopSlug(slug : Text) : async Result<(), Types.CheckShopSlugError> {
        switch (Slug.validate(slug)) {
            case (#err(msg)) { return #err(#InvalidSlug(msg)) };
            case (#ok) {};
        };
        if (ShopCreationAPI.slugUnavailable(shopCreationApi, slug, caller)) {
            return #err(#SlugTaken);
        };
        #ok;
    };

    /// Quotes a hosted shop: locks the price in `currency` for 30 minutes, reserves the shop name and
    /// URL slug (`req.slug`, or one made from the name), and returns the account to pay. Pay the quoted amount there, then call `createShop` with the quote ID.
    public shared ({ caller }) func createShopQuote(req : Types.CreateShopQuoteRequest) : async Result<ShopCreationAPI.QuoteView, Types.CreateShopQuoteError> {
        if (caller.isAnonymous()) {
            return #err(#Unauthenticated);
        };

        if (not Map.has(userRegistry, Map.phash, caller)) {
            return #err(#Unauthorized);
        };

        let normalizedName = ShopAPI.normalizeShopName(req.name);
        // Check before the exchange-rate call, then again after it (createQuote) in case the name went meanwhile.
        if (ShopCreationAPI.nameUnavailable(shopCreationApi, normalizedName, caller)) {
            return #err(#ShopNameConflict);
        };
        let slug = switch (req.slug) {
            case (?s) {
                switch (Slug.validate(s)) {
                    case (#err(msg)) { return #err(#InvalidSlug(msg)) };
                    case (#ok) {};
                };
                if (ShopCreationAPI.slugUnavailable(shopCreationApi, s, caller)) {
                    return #err(#ShopSlugConflict);
                };
                s;
            };
            case null {
                Slug.unique(Slug.fromName(req.name), func s = not ShopCreationAPI.slugUnavailable(shopCreationApi, s, caller));
            };
        };

        let amount = switch (await* shopCreationPriceIn(req.currency, ExchangeRates.QUOTE_MAX_AGE)) {
            case (#ok(a)) { a };
            case (#err(msg)) { return #err(#PriceUnavailable(msg)) };
        };

        ShopCreationAPI.createQuote(
            shopCreationApi,
            caller,
            {
                name = req.name;
                description = req.description;
                normalizedName;
                slug;
                currency = req.currency;
                amount;
            },
        );
    };

    /// The caller's quote with ID `quoteId`, including its status and where to pay it.
    public query ({ caller }) func getShopCreationQuote(quoteId : ShopCreationAPI.QuoteId) : async ?ShopCreationAPI.QuoteView {
        ShopCreationAPI.getQuote(shopCreationApi, caller, quoteId);
    };

    /// The caller's shop creation quotes, newest first, a page at a time.
    public query ({ caller }) func listShopCreationQuotes(after : ?ShopCreationAPI.QuoteId, limit : ?Nat) : async Pagination.Page<ShopCreationAPI.QuoteView, ShopCreationAPI.QuoteId> {
        Pagination.page(ShopCreationAPI.listQuotes(shopCreationApi, caller), func(q : ShopCreationAPI.QuoteView) : ShopCreationAPI.QuoteId = q.id, Pagination.descending(Nat.compare), after, limit);
    };

    /// Refunds an unclaimed quote's deposit (less the ledger fee) and closes the quote. Sends it to
    /// `to`, or to the caller's own account (`owner = caller`, no subaccount) when `to` is null:
    /// core never keeps a refund on the caller's behalf (BRE-83).
    public shared ({ caller }) func refundShopCreationQuote(quoteId : ShopCreationAPI.QuoteId, to : ?ShopCreationAPI.Account) : async Result<Nat, ShopCreationAPI.RefundError> {
        let destination = to ?? ({ owner = caller; subaccount = null });
        await ShopCreationAPI.refund(shopCreationApi, caller, quoteId, destination);
    };

    /// Creates the Shop canister for a paid quote (see `createShopQuote`) and registers it in the
    /// marketplace. If creation fails the quote stays paid: call again to retry, or refund it.
    public shared ({ caller }) func createShop(quoteId : ShopCreationAPI.QuoteId) : async Types.CreateShopResponse {
        if (caller.isAnonymous()) {
            return #err(#Unauthenticated);
        };
        let result = await ShopCreationAPI.claim(shopCreationApi, caller, quoteId, createShopForQuote);
        switch (result) {
            case (#err(#CreationFailed(error))) {
                recordAlert<system>(#shopCreationFailed({ quoteId; owner = caller; error = AlertsAPI.clip(error) }));
            };
            case _ {};
        };
        result;
    };

    /// Quotes left `#Creating` or `#Refunding` by a claim or refund that no longer runs (BRE-68).
    /// Release each with `releaseStuckShopCreationQuote`. Needs `ShopCreation.Manage`.
    public query ({ caller }) func listStuckShopCreationQuotes() : async Result<[ShopCreationAPI.QuoteView], { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.shopCreationManage)) {
            return #err(#Unauthorized);
        };
        #ok(ShopCreationAPI.listStuck(shopCreationApi));
    };

    /// Unlocks a stuck quote so its owner can claim or refund it again. Returns its new status:
    /// `#Created` if its shop is registered, otherwise `#Paid` if its deposit covers the price, or
    /// `#Pending`. Refuses a quote whose claim or refund is still running. Needs `ShopCreation.Manage`.
    public shared ({ caller }) func releaseStuckShopCreationQuote(quoteId : ShopCreationAPI.QuoteId) : async Result<ShopCreationAPI.QuoteStatus, ShopCreationAPI.ReleaseError or { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.shopCreationManage)) {
            return #err(#Unauthorized);
        };
        let result = await ShopCreationAPI.releaseStuck(shopCreationApi, quoteId);
        switch (result) {
            case (#ok(_)) ignore HistoryAPI.record(history, caller, null, #stuckQuoteReleased({ quoteId }));
            case (#err(_)) {};
        };
        result;
    };
};
