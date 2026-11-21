import { expect } "mo:test";
import { suite; test } "mo:test";

import Token "../Token";

func show(ledger : ?Token.Ledger) : Text = debug_show (ledger);

suite(
    "Token.ledgerFor",
    func() {
        test(
            "routes ICP to the ICP ledger",
            func() {
                expect.text(show(Token.ledgerFor("ICP"))).equal(show(?#ICP));
            },
        );
        test(
            "routes ckUSDC to the ckUSDC ledger, not the ICP ledger",
            func() {
                expect.text(show(Token.ledgerFor("ckUSDC"))).equal(show(?#ckUSDC));
            },
        );
        test(
            "rejects unknown tokens instead of falling back to ICP",
            func() {
                expect.text(show(Token.ledgerFor("ckBTC"))).equal(show(null));
                expect.text(show(Token.ledgerFor(""))).equal(show(null));
            },
        );
        test(
            "is case-sensitive",
            func() {
                expect.text(show(Token.ledgerFor("icp"))).equal(show(null));
                expect.text(show(Token.ledgerFor("CKUSDC"))).equal(show(null));
            },
        );
        test(
            "routes every supported token",
            func() {
                for (token in Token.supported.values()) {
                    expect.bool(Token.ledgerFor(token) != null).isTrue();
                };
            },
        );
    },
);
