import { suite; test } "mo:test";

import PaymentCurrency "../payment_currency";

let usd = PaymentCurrency.USD;
let usdc = PaymentCurrency.USDC;

suite(
    "PaymentCurrency.token",
    func() {
        test(
            "routes ICP orders to the ICP ledger",
            func() {
                assert PaymentCurrency.token(PaymentCurrency.ICP) == ?"ICP";
            },
        );
        test(
            "routes USDC and ckUSDC orders to the ckUSDC ledger",
            func() {
                assert PaymentCurrency.token(usdc) == ?"ckUSDC";
                assert PaymentCurrency.token({
                    class_ = #Cryptocurrency;
                    symbol = "ckUSDC";
                }) == ?"ckUSDC";
                assert PaymentCurrency.isUsdc(usdc);
            },
        );
        test(
            "has no ledger for fiat or unknown tokens",
            func() {
                assert PaymentCurrency.token(usd) == null;
                assert PaymentCurrency.token({
                    class_ = #FiatCurrency;
                    symbol = "USDC";
                }) == null;
                assert PaymentCurrency.token({
                    class_ = #Cryptocurrency;
                    symbol = "BTC";
                }) == null;
                assert not PaymentCurrency.isUsdc(PaymentCurrency.ICP);
            },
        );
    },
);

suite(
    "PaymentCurrency.usdcFromUsd",
    func() {
        test(
            "prices USDC one to one with USD, keeping the decimals",
            func() {
                let price = PaymentCurrency.usdcFromUsd({
                    currency = usd;
                    amount = 1_999;
                    metadata = { decimals = 2 };
                });
                assert price.currency == usdc;
                assert price.amount == 1_999;
                assert price.metadata.decimals == 2;
            },
        );
    },
);

suite(
    "PaymentCurrency.withDecimals",
    func() {
        test(
            "scales up exactly",
            func() {
                let price = PaymentCurrency.withDecimals({ currency = usdc; amount = 1_999; metadata = { decimals = 2 } }, 6);
                assert price.amount == 19_990_000;
                assert price.metadata.decimals == 6;
                assert price.currency == usdc;
            },
        );
        test(
            "rounds up when it drops digits",
            func() {
                assert PaymentCurrency.withDecimals({ currency = usdc; amount = 1_000_001; metadata = { decimals = 8 } }, 6).amount == 10_001;
                assert PaymentCurrency.withDecimals({ currency = usdc; amount = 1_000_000; metadata = { decimals = 8 } }, 6).amount == 10_000;
            },
        );
        test(
            "leaves the same decimals alone",
            func() {
                assert PaymentCurrency.withDecimals({ currency = usdc; amount = 42; metadata = { decimals = 6 } }, 6).amount == 42;
            },
        );
    },
);
