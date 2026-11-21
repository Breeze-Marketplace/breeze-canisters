import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";

/// Which ledger pays an order in a given currency, and how a USD price becomes a USDC one (BRE-20).
/// Pure, so it runs under `mops test`.
module PaymentCurrency {
    // The shop's `Currency` and `Money`, restated: `../types` imports `canister:xrc`, which `mops test` can't resolve.
    public type Currency = {
        class_ : { #Cryptocurrency; #FiatCurrency };
        symbol : Text;
    };
    public type Money = {
        currency : Currency;
        amount : Nat64;
        metadata : { decimals : Nat32 };
    };

    /// The currency of ICP orders.
    public let ICP : Currency = { class_ = #Cryptocurrency; symbol = "ICP" };

    /// The currency of USDC orders, paid in ckUSDC. Catalogs and checkout name it "USDC".
    public let USDC : Currency = { class_ = #Cryptocurrency; symbol = "USDC" };

    public let USD : Currency = { class_ = #FiatCurrency; symbol = "USD" };

    /// Decimals of the ckUSDC ledger; USDC order totals are stored with these.
    public let CKUSDC_DECIMALS : Nat32 = 6;

    /// Decimals of card (USD) order prices: cents, Stripe's minor unit for USD (BRE-123).
    public let CARD_DECIMALS : Nat32 = 2;

    /// True when an order in `currency` is paid by card through Stripe Checkout: USD only.
    public func isCard(currency : Currency) : Bool {
        currency == USD;
    };

    /// The wallet token (`lib/Token`) whose ledger takes payment for an order in `currency`, or null
    /// when no ledger does (fiat, unknown tokens). "ckUSDC" is accepted as another name for USDC.
    public func token(currency : Currency) : ?Text {
        if (currency.class_ != #Cryptocurrency) {
            return null;
        };
        switch (currency.symbol) {
            case "ICP" ?"ICP";
            case ("USDC" or "ckUSDC") ?"ckUSDC";
            case _ null;
        };
    };

    /// True when `currency` is paid on the ckUSDC ledger.
    public func isUsdc(currency : Currency) : Bool {
        token(currency) == ?"ckUSDC";
    };

    /// A USD price as a USDC one, one to one. ckUSDC is a dollar stablecoin, and the product form
    /// already stores every USD price as a matching USDC catalog line the same way, so this prices a
    /// variant without that line exactly as one with it. The amount keeps the USD price's decimals;
    /// payment checks compare it with the ckUSDC balance (6 decimals) exactly.
    public func usdcFromUsd(usd : Money) : Money {
        { usd with currency = USDC };
    };

    /// `money` in `decimals` decimals, rounded up when it has more, so a converted price never
    /// undercharges. Order totals add unit prices without rescaling them, so a USDC order brings every
    /// line to the ckUSDC ledger's decimals first, whatever decimals each catalog line was stored with.
    public func withDecimals(money : Money, decimals : Nat32) : Money {
        let from = money.metadata.decimals;
        let amount = if (decimals >= from) {
            money.amount * 10 ** (decimals - from).toNat64();
        } else {
            let divisor = 10 ** (from - decimals).toNat64();
            (money.amount + divisor - 1) / divisor;
        };
        { money with amount; metadata = { decimals } };
    };
};
