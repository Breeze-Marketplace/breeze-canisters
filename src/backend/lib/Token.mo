/// Token symbols the wallet handles, and which ledger each one lives on.
/// Pure, so `mops test` can cover the routing; `Wallet` maps a `Ledger` to its canister.
module {
    /// The ledger canisters a token can live on.
    public type Ledger = { #ICP; #ckUSDC };

    /// Every token symbol `ledgerFor` accepts, in sweep order.
    public let supported : [Text] = ["ICP", "ckUSDC"];

    /// The ledger for `token`, or null when the token isn't supported.
    /// Callers must reject null rather than fall back to a default ledger (BRE-30).
    public func ledgerFor(token : Text) : ?Ledger {
        switch (token) {
            case ("ICP") { ?#ICP };
            case ("ckUSDC") { ?#ckUSDC };
            case _ { null };
        };
    };
};
