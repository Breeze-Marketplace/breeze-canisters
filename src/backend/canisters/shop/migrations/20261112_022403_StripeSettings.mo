// Adds `stripe`, the merchant's Stripe restricted key for card payments (BRE-123). No shop has
// one yet, so it starts empty: card payments stay off until the Owner sets a key.
module {
    type StripeSettings = { var restrictedKey : ?Text };

    public func migration(_old : {}) : { stripe : StripeSettings } {
        { stripe = { var restrictedKey = null } };
    };
};
