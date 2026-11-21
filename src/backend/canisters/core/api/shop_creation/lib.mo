import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Error "mo:core/Error";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import CoreMap "mo:core/Map";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Time "mo:core/Time";

import Map "mo:map/Map";

import Hex "../../../../lib/Hex";
import Logger "../../../../lib/Logger";
import TimeUtil "../../../../lib/Time";

/// Paid shop creation. A merchant asks for a quote (a USD-pegged price in ICP or ckUSDC, locked
/// for `QUOTE_TTL_MINUTES`), pays it into the quote's own deposit subaccount of core, and then
/// claims it: core creates the shop only once that subaccount covers the quote. A failed creation
/// leaves the quote `#Paid`, so the merchant can retry without paying again, or ask for a refund.
module {
    public type QuoteId = Nat;

    public type Currency = { #ICP; #ckUSDC };

    public type Account = { owner : Principal; subaccount : ?Blob };

    public type QuoteStatus = {
        /// Not known to be paid yet. Payment is checked when the merchant claims the quote.
        #Pending;
        /// Paid (or free), but no shop yet: the last creation attempt failed.
        #Paid;
        /// A claim is running. Guards against a second claim or a refund in the meantime.
        #Creating;
        /// A refund is running.
        #Refunding;
        #Created : Principal;
        #Refunded;
    };

    public type Quote = {
        id : QuoteId;
        owner : Principal;
        name : Text;
        description : Text;
        normalizedName : Text;
        /// The shop's URL slug, reserved with the name (BRE-71). Empty on quotes settled before
        /// slugs existed.
        slug : Text;
        currency : Currency;
        /// Price in the currency's ledger units (e8s for ICP, 1e-6 for ckUSDC).
        amount : Nat;
        createdAt : Time.Time;
        expiresAt : Time.Time;
        status : QuoteStatus;
        lastError : ?Text;
    };

    /// A quote as the merchant sees it, with where to pay it.
    public type QuoteView = Quote and {
        depositAccount : Account;
        /// Hex account identifier of `depositAccount`, for exchanges that only take ICP account IDs. Null for ckUSDC.
        depositAccountId : ?Text;
    };

    /// Stable state, owned by core.
    public type State = {
        quotes : Map.Map<QuoteId, Quote>;
        quotesByOwner : Map.Map<Principal, [QuoteId]>;
        /// Normalized shop name -> the quote holding it while unpaid quotes are open or a paid quote waits for its shop.
        reservedNames : Map.Map<Text, QuoteId>;
        /// Slug -> the quote holding it, the same way as `reservedNames` (BRE-71).
        reservedSlugs : CoreMap.Map<Text, QuoteId>;
        var nextQuoteId : QuoteId;
        var priceUsdCents : Nat;
    };

    public let QUOTE_TTL_MINUTES = 30;
    /// A quote paid after it expired can still be claimed for this long, at the quoted amount.
    public let CLAIM_GRACE_HOURS = 24;
    public let MAX_OPEN_QUOTES_PER_USER = 3;
    public let DEFAULT_PRICE_USD_CENTS = 1_000;

    public func newState() : State {
        {
            quotes = Map.new<QuoteId, Quote>();
            quotesByOwner = Map.new<Principal, [QuoteId]>();
            reservedNames = Map.new<Text, QuoteId>();
            reservedSlugs = CoreMap.empty<Text, QuoteId>();
            var nextQuoteId = 0;
            var priceUsdCents = DEFAULT_PRICE_USD_CENTS;
        };
    };

    public type Ledgers = {
        balanceOf : (Currency, Account) -> async Nat;
        fee : (Currency) -> async Nat;
        /// Transfers `amount` (fee on top) from core's `fromSubaccount`, with `createdAtTime` as the
        /// ICRC-1 `created_at_time`, so the ledger rejects a repeat of the same transfer. Returns the block index.
        transfer : (Currency, TransferArgs) -> async Result<Nat, Text>;
    };

    public type TransferArgs = {
        fromSubaccount : Blob;
        to : Account;
        amount : Nat;
        fee : Nat;
        createdAtTime : Nat64;
    };

    public type Dependencies = {
        state : State;
        /// Core: owns every deposit account and receives paid fees in its main account.
        self : Principal;
        ledgers : Ledgers;
        /// True if a registered shop already uses this normalized name.
        shopNameTaken : (Text) -> Bool;
        /// True if a shop has or had this slug.
        shopSlugTaken : (Text) -> Bool;
        /// The registered shop with this normalized name, if `owner` owns it. Tells whether a claim
        /// that failed or trapped got as far as registering its shop.
        findShop : (normalizedName : Text, owner : Principal) -> ?Principal;
        now : () -> Time.Time;
        logger : Logger.BoundLogger;
    };

    public class API(dependencies : Dependencies) {
        public let {
            state;
            self;
            ledgers;
            shopNameTaken;
            shopSlugTaken;
            findShop;
            now;
            logger;
        } = dependencies;
        /// Quotes a `claim`, `refund` or `releaseStuck` call is working on. Transient: no call spans an
        /// upgrade (core is stopped first), so after one a `#Creating` or `#Refunding` quote that isn't
        /// here is stuck, not busy. Each call removes its quote in `finally`.
        public let inFlight = Set.empty<QuoteId>();
    };

    // Deposit accounts

    /// Subaccount `"SC"` ++ quote ID (big-endian, 8 bytes) ++ zeros. Core's per-user wallet
    /// subaccounts start with the principal's length (at most 29), so the two never collide.
    public func depositSubaccount(id : QuoteId) : Blob {
        Blob.fromArray(
            Array.tabulate<Nat8>(
                32,
                func(i) {
                    if (i == 0) { 0x53 } else if (i == 1) { 0x43 } else if (i < 10) {
                        Nat8.fromNat((id / (256 ** (9 - i))) % 256);
                    } else { 0 };
                },
            )
        );
    };

    public func depositAccount(api : API, id : QuoteId) : Account {
        { owner = api.self; subaccount = ?depositSubaccount(id) };
    };

    func toView(api : API, quote : Quote) : QuoteView {
        let account = depositAccount(api, quote.id);
        let depositAccountId = switch (quote.currency) {
            case (#ICP) {
                ?Hex.encode(Blob.toArray(Principal.toLedgerAccount(account.owner, account.subaccount)));
            };
            case (#ckUSDC) { null };
        };
        { quote with depositAccount = account; depositAccountId };
    };

    // Pricing

    /// Converts a USD price to ICP e8s, rounding up. `rate` is ICP per USD (XRC base USD, quote ICP),
    /// scaled by 10^`rateDecimals`.
    public func usdCentsToE8s(usdCents : Nat, rate : Nat64, rateDecimals : Nat32) : Nat {
        let numerator = usdCents * Nat64.toNat(rate) * (10 ** 8);
        let denominator = 100 * (10 ** Nat32.toNat(rateDecimals));
        (numerator + denominator - 1) / denominator;
    };

    /// ckUSDC has 6 decimals and is pegged 1:1 to USD.
    public func usdCentsToCkusdc(usdCents : Nat) : Nat {
        usdCents * 10_000;
    };

    // Name reservations

    func isOpen(api : API, quote : Quote) : Bool {
        isOpenAt(quote, api.now());
    };

    func isOpenAt(quote : Quote, now : Time.Time) : Bool {
        switch (quote.status) {
            case (#Pending) { now <= quote.expiresAt };
            case (#Paid or #Creating or #Refunding) { true };
            case (#Created(_) or #Refunded) { false };
        };
    };

    /// True once no payment into the quote's deposit is expected: its shop exists, it was refunded,
    /// or it was never paid and its claim grace period is over. A deposit that arrives after this
    /// can still be refunded (`refund` reads the ledger), but the admin balances view may no longer
    /// list it (BRE-101).
    public func depositSettled(quote : Quote, now : Time.Time) : Bool {
        switch (quote.status) {
            case (#Created(_) or #Refunded) { true };
            case (#Pending) {
                now > quote.expiresAt + TimeUtil.fromHours(CLAIM_GRACE_HOURS);
            };
            case (#Paid or #Creating or #Refunding) { false };
        };
    };

    /// True if `normalizedName` belongs to a registered shop, or another user's open quote holds it.
    public func nameUnavailable(api : API, normalizedName : Text, owner : Principal) : Bool {
        if (api.shopNameTaken(normalizedName)) {
            return true;
        };
        switch (Map.get(api.state.reservedNames, Map.thash, normalizedName)) {
            case (null) { false };
            case (?id) {
                switch (Map.get(api.state.quotes, Map.nhash, id)) {
                    case (?holder) {
                        holder.owner != owner and isOpen(api, holder)
                    };
                    case (null) { false };
                };
            };
        };
    };

    /// True if `slug` belongs to a shop (now or before), or another user's open quote holds it.
    public func slugUnavailable(api : API, slug : Text, owner : Principal) : Bool {
        if (api.shopSlugTaken(slug)) { return true };
        switch (api.state.reservedSlugs.get(Text.compare, slug)) {
            case (null) { false };
            case (?id) {
                switch (Map.get(api.state.quotes, Map.nhash, id)) {
                    case (?holder) {
                        holder.owner != owner and isOpen(api, holder)
                    };
                    case (null) { false };
                };
            };
        };
    };

    /// True if any open quote holds `slug` at time `now`, whoever its owner. Takes the state rather
    /// than the API so the shop registry, built before the API, can call it.
    public func slugReserved(state : State, slug : Text, now : Time.Time) : Bool {
        let ?id = state.reservedSlugs.get(Text.compare, slug) else return false;
        switch (Map.get(state.quotes, Map.nhash, id)) {
            case (?holder) { isOpenAt(holder, now) };
            case (null) { false };
        };
    };

    /// Releases the quote's name and slug, where it still holds them.
    func releaseName(api : API, quote : Quote) {
        if (Map.get(api.state.reservedNames, Map.thash, quote.normalizedName) == ?quote.id) {
            Map.delete(api.state.reservedNames, Map.thash, quote.normalizedName);
        };
        if (api.state.reservedSlugs.get(Text.compare, quote.slug) == ?quote.id) {
            api.state.reservedSlugs.remove(Text.compare, quote.slug);
        };
    };

    func setStatus(api : API, quote : Quote, status : QuoteStatus, lastError : ?Text) : Quote {
        let updated = { quote with status; lastError };
        Map.set(api.state.quotes, Map.nhash, quote.id, updated);
        updated;
    };

    func markCreated(api : API, quote : Quote, shopId : Principal) : Quote {
        let created = setStatus(api, quote, #Created(shopId), null);
        releaseName(api, created);
        created;
    };

    /// Ends a claim that didn't reach `#Created`: if its shop got registered anyway, the quote is
    /// `#Created` (so a retry can't create a second shop), otherwise it goes back to `restoreTo`.
    /// Leaves a quote that isn't `#Creating` alone. Runs in `finally`, so it only reads maps.
    func unlockClaim(api : API, id : QuoteId, restoreTo : QuoteStatus, lastError : ?Text) {
        let ?quote = Map.get(api.state.quotes, Map.nhash, id) else return;
        if (quote.status != #Creating) { return };
        switch (api.findShop(quote.normalizedName, quote.owner)) {
            case (?shopId) { ignore markCreated(api, quote, shopId) };
            case (null) { ignore setStatus(api, quote, restoreTo, lastError) };
        };
    };

    // Quotes

    public type CreateQuoteRequest = {
        name : Text;
        description : Text;
        normalizedName : Text;
        /// A valid slug (`Slug.validate`); `createQuote` checks it's free.
        slug : Text;
        currency : Currency;
        /// Price in the currency's ledger units, from `usdCentsToE8s` / `usdCentsToCkusdc`.
        amount : Nat;
    };

    public type CreateQuoteError = {
        #ShopNameConflict;
        #ShopSlugConflict;
        #InvalidSlug : Text;
        #TooManyOpenQuotes;
    };

    /// Opens a quote and reserves its shop name. A free quote (amount 0) starts out `#Paid`.
    /// Callers check that `caller` is a registered user.
    public func createQuote(api : API, caller : Principal, req : CreateQuoteRequest) : Result<QuoteView, CreateQuoteError> {
        if (nameUnavailable(api, req.normalizedName, caller)) {
            return #err(#ShopNameConflict);
        };
        if (slugUnavailable(api, req.slug, caller)) {
            return #err(#ShopSlugConflict);
        };

        let ownQuoteIds = Option.get(Map.get(api.state.quotesByOwner, Map.phash, caller), []);
        let openUnpaid = Array.filter<QuoteId>(
            ownQuoteIds,
            func(id) {
                switch (Map.get(api.state.quotes, Map.nhash, id)) {
                    case (?q) { q.status == #Pending and isOpen(api, q) };
                    case (null) { false };
                };
            },
        );
        if (openUnpaid.size() >= MAX_OPEN_QUOTES_PER_USER) {
            return #err(#TooManyOpenQuotes);
        };

        let id = api.state.nextQuoteId;
        api.state.nextQuoteId += 1;

        let createdAt = api.now();
        let quote : Quote = {
            id;
            owner = caller;
            name = req.name;
            description = req.description;
            normalizedName = req.normalizedName;
            slug = req.slug;
            currency = req.currency;
            amount = req.amount;
            createdAt;
            expiresAt = createdAt + TimeUtil.fromMinutes(QUOTE_TTL_MINUTES);
            status = if (req.amount == 0) { #Paid } else { #Pending };
            lastError = null;
        };
        Map.set(api.state.quotes, Map.nhash, id, quote);
        Map.set(api.state.quotesByOwner, Map.phash, caller, Array.concat(ownQuoteIds, [id]));
        Map.set(api.state.reservedNames, Map.thash, req.normalizedName, id);
        api.state.reservedSlugs.add(Text.compare, req.slug, id);

        #ok(toView(api, quote));
    };

    public func getQuote(api : API, caller : Principal, id : QuoteId) : ?QuoteView {
        switch (Map.get(api.state.quotes, Map.nhash, id)) {
            case (?quote) {
                if (quote.owner == caller) { ?toView(api, quote) } else { null };
            };
            case (null) { null };
        };
    };

    /// The caller's quotes, newest first.
    public func listQuotes(api : API, caller : Principal) : [QuoteView] {
        let ids = Option.get(Map.get(api.state.quotesByOwner, Map.phash, caller), []);
        let views = Array.filterMap<QuoteId, QuoteView>(
            ids,
            func(id) { getQuote(api, caller, id) },
        );
        Array.reverse(views);
    };

    // Claiming

    public type ClaimError = {
        #NotFound;
        #InProgress;
        #Refunded;
        #Expired;
        #ShopNameConflict;
        #ShopSlugConflict;
        #NotPaid : { required : Nat; received : Nat };
        #LedgerError : Text;
        #CreationFailed : Text;
    };

    /// Creates the shop for a paid quote with `createShop`, which gets the quote and returns the new
    /// shop's canister ID. Idempotent once the shop exists. On failure the quote stays `#Paid`, and
    /// so it does when this call traps after an `await` (BRE-68): `finally` releases the lock.
    public func claim(
        api : API,
        caller : Principal,
        id : QuoteId,
        createShop : (Quote) -> async Result<Principal, Text>,
    ) : async Result<Principal, ClaimError> {
        let quote = switch (Map.get(api.state.quotes, Map.nhash, id)) {
            case (?q) {
                if (q.owner != caller) { return #err(#NotFound) } else { q };
            };
            case (null) { return #err(#NotFound) };
        };

        switch (quote.status) {
            case (#Created(shopId)) { return #ok(shopId) };
            case (#Creating or #Refunding) { return #err(#InProgress) };
            case (#Refunded) { return #err(#Refunded) };
            case (#Pending) {
                if (api.now() > quote.expiresAt + TimeUtil.fromHours(CLAIM_GRACE_HOURS)) {
                    return #err(#Expired);
                };
            };
            case (#Paid) {};
        };

        if (nameUnavailable(api, quote.normalizedName, caller)) {
            return #err(#ShopNameConflict);
        };
        if (slugUnavailable(api, quote.slug, caller)) {
            return #err(#ShopSlugConflict);
        };

        // Lock the quote before the first await; `finally` unlocks it however the call ends.
        let locked = setStatus(api, quote, #Creating, quote.lastError);
        Set.add(api.inFlight, Nat.compare, id);
        Map.set(api.state.reservedNames, Map.thash, quote.normalizedName, id);
        api.state.reservedSlugs.add(Text.compare, quote.slug, id);
        // What an unfinished claim leaves the quote as: `#Paid` once the deposit is known to cover it.
        var restoreTo = quote.status;
        var lastError = quote.lastError;

        try {
            if (quote.status == #Pending) {
                let received = try {
                    await api.ledgers.balanceOf(quote.currency, depositAccount(api, id));
                } catch (e) {
                    return #err(#LedgerError(Error.message(e)));
                };
                if (received < quote.amount) {
                    return #err(#NotPaid({ required = quote.amount; received }));
                };
                restoreTo := #Paid;
            };

            let result = try { await createShop(locked) } catch (e) {
                #err(Error.message(e));
            };

            switch (result) {
                case (#err(msg)) {
                    // `unlockClaim` (in `finally`) marks the quote `#Created` instead if the shop got
                    // registered before the failure, and `#Paid` otherwise.
                    lastError := ?msg;
                    api.logger.error("Shop creation for quote " # Nat.toText(id) # " failed: " # msg);
                    switch (api.findShop(quote.normalizedName, quote.owner)) {
                        case (?shopId) { #ok(shopId) };
                        case (null) { #err(#CreationFailed(msg)) };
                    };
                };
                case (#ok(shopId)) {
                    let created = switch (Map.get(api.state.quotes, Map.nhash, id)) {
                        case (?live) { markCreated(api, live, shopId) };
                        case (null) { locked };
                    };
                    try { await sweep(api, created) } catch (e) {
                        api.logger.error("Sweeping quote " # Nat.toText(id) # " failed: " # Error.message(e));
                    };
                    #ok(shopId);
                };
            };
        } finally {
            Set.remove(api.inFlight, Nat.compare, id);
            unlockClaim(api, id, restoreTo, lastError);
        };
    };

    /// Moves a claimed quote's deposit (overpayment included) to core's main account. Failures are
    /// only logged: the funds stay in the deposit subaccount, which core still controls.
    func sweep(api : API, quote : Quote) : async () {
        try {
            let balance = await api.ledgers.balanceOf(quote.currency, depositAccount(api, quote.id));
            let fee = await api.ledgers.fee(quote.currency);
            if (balance <= fee) { return };
            switch (
                await api.ledgers.transfer(
                    quote.currency,
                    {
                        fromSubaccount = depositSubaccount(quote.id);
                        to = { owner = api.self; subaccount = null };
                        amount = balance - fee;
                        fee;
                        createdAtTime = createdAtTime(api);
                    },
                )
            ) {
                case (#ok(_)) {};
                case (#err(msg)) {
                    api.logger.error("Sweeping quote " # Nat.toText(quote.id) # " failed: " # msg);
                };
            };
        } catch (e) {
            api.logger.error("Sweeping quote " # Nat.toText(quote.id) # " failed: " # Error.message(e));
        };
    };

    func createdAtTime(api : API) : Nat64 {
        Nat64.fromNat(Int.abs(api.now()));
    };

    // Refunds

    public type RefundError = {
        #NotFound;
        #InProgress;
        #AlreadyClaimed;
        #Refunded;
        #NothingToRefund;
        #LedgerError : Text;
    };

    /// Sends everything in an unclaimed quote's deposit account, less the ledger fee, to `to`, and
    /// closes the quote. Returns the amount sent. The amount comes from the live balance, so a retry
    /// after a refund that went out finds nothing left to send.
    ///
    /// `finally` unlocks the quote however the call ends (BRE-68). A trap after the transfer was sent
    /// leaves its outcome unknown, so a paid quote goes back to `#Pending` rather than `#Paid`: a
    /// later claim checks the deposit again instead of creating a shop the merchant got refunded for.
    public func refund(api : API, caller : Principal, id : QuoteId, to : Account) : async Result<Nat, RefundError> {
        let quote = switch (Map.get(api.state.quotes, Map.nhash, id)) {
            case (?q) {
                if (q.owner != caller) { return #err(#NotFound) } else { q };
            };
            case (null) { return #err(#NotFound) };
        };

        switch (quote.status) {
            case (#Created(_)) { return #err(#AlreadyClaimed) };
            case (#Creating or #Refunding) { return #err(#InProgress) };
            case (#Refunded) { return #err(#Refunded) };
            case (#Pending or #Paid) {};
        };

        ignore setStatus(api, quote, #Refunding, quote.lastError);
        Set.add(api.inFlight, Nat.compare, id);
        // What an unfinished refund leaves the quote as.
        var restoreTo = quote.status;

        try {
            let balance = await api.ledgers.balanceOf(quote.currency, depositAccount(api, id));
            let fee = await api.ledgers.fee(quote.currency);
            if (balance <= fee) {
                return #err(#NothingToRefund);
            };
            let amount : Nat = balance - fee;
            // A free quote needs no deposit, so it can stay `#Paid` whatever happens to the transfer.
            if (quote.amount > 0) { restoreTo := #Pending };
            let sent = await api.ledgers.transfer(
                quote.currency,
                {
                    fromSubaccount = depositSubaccount(id);
                    to;
                    amount;
                    fee;
                    createdAtTime = createdAtTime(api);
                },
            );
            switch (sent) {
                case (#ok(_)) {
                    switch (Map.get(api.state.quotes, Map.nhash, id)) {
                        case (?live) {
                            releaseName(api, setStatus(api, live, #Refunded, null));
                        };
                        case (null) {};
                    };
                    api.logger.info("Refunded quote " # Nat.toText(id) # ": " # Nat.toText(amount));
                    #ok(amount);
                };
                case (#err(msg)) {
                    // The ledger refused it, so the deposit is still there.
                    restoreTo := quote.status;
                    #err(#LedgerError(msg));
                };
            };
        } catch (e) {
            // A rejected call (the ledger trapped or refused it) made no transfer.
            restoreTo := quote.status;
            #err(#LedgerError(Error.message(e)));
        } finally {
            Set.remove(api.inFlight, Nat.compare, id);
            switch (Map.get(api.state.quotes, Map.nhash, id)) {
                case (?live) {
                    if (live.status == #Refunding) {
                        ignore setStatus(api, live, restoreTo, live.lastError);
                    };
                };
                case (null) {};
            };
        };
    };

    // Stuck quotes

    func isStuck(api : API, quote : Quote) : Bool {
        (quote.status == #Creating or quote.status == #Refunding) and not Set.contains(api.inFlight, Nat.compare, quote.id);
    };

    /// Quotes left `#Creating` or `#Refunding` by a call that no longer runs: before BRE-68, a trap
    /// after an `await` kept the lock. Callers check that the caller is an admin.
    public func listStuck(api : API) : [QuoteView] {
        let stuck = Map.toArray(Map.filter<QuoteId, Quote>(api.state.quotes, Map.nhash, func(_, q) { isStuck(api, q) }));
        Array.map<(QuoteId, Quote), QuoteView>(stuck, func((_, q)) { toView(api, q) });
    };

    public type ReleaseError = {
        #NotFound;
        /// The quote isn't `#Creating` or `#Refunding`.
        #NotStuck;
        /// A claim or refund of the quote is running.
        #InProgress;
        #LedgerError : Text;
    };

    /// Unlocks a stuck quote (see `listStuck`) and returns its new status: `#Created` if its shop is
    /// registered, otherwise `#Paid` if its deposit covers the price and `#Pending` if not, so the
    /// merchant can claim or refund it again. Callers check that the caller is an admin.
    public func releaseStuck(api : API, id : QuoteId) : async Result<QuoteStatus, ReleaseError> {
        let ?quote = Map.get(api.state.quotes, Map.nhash, id) else return #err(#NotFound);
        if (Set.contains(api.inFlight, Nat.compare, id)) {
            return #err(#InProgress);
        };
        if (not isStuck(api, quote)) { return #err(#NotStuck) };

        switch (api.findShop(quote.normalizedName, quote.owner)) {
            case (?shopId) {
                ignore markCreated(api, quote, shopId);
                return #ok(#Created(shopId));
            };
            case (null) {};
        };

        Set.add(api.inFlight, Nat.compare, id);
        try {
            let balance = try {
                await api.ledgers.balanceOf(quote.currency, depositAccount(api, id));
            } catch (e) {
                return #err(#LedgerError(Error.message(e)));
            };
            let status = if (balance >= quote.amount) { #Paid } else {
                #Pending;
            };
            switch (Map.get(api.state.quotes, Map.nhash, id)) {
                case (?live) {
                    if (live.status != #Creating and live.status != #Refunding) {
                        return #err(#NotStuck);
                    };
                    ignore setStatus(api, live, status, live.lastError);
                };
                case (null) { return #err(#NotFound) };
            };
            api.logger.warning("Released stuck quote " # Nat.toText(id) # " as " # debug_show (status));
            #ok(status);
        } finally {
            Set.remove(api.inFlight, Nat.compare, id);
        };
    };
};
