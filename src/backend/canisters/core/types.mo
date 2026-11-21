import { type Result } "mo:core/Result";

import ShopCreationAPI "api/shop_creation";

/// Request and response types of core's public methods that aren't owned by an `api/` module.
module {
    public type UserRegistryItem = {
        registrationDate : Int;
    };

    public type ShopInitArgs = {
        name : Text;
        description : Text;
    };

    public type ShopCreationPrice = {
        usdCents : Nat;
        /// ICP e8s at the current exchange rate.
        icpE8s : Nat;
        /// ckUSDC (6 decimals).
        ckusdc : Nat;
    };

    public type CreateShopQuoteRequest = {
        name : Text;
        description : Text;
        /// The shop's URL slug (BRE-71). Null: core makes one from the name (see `suggestShopSlug`).
        slug : ?Text;
        currency : ShopCreationAPI.Currency;
    };

    public type CheckShopSlugError = {
        #InvalidSlug : Text;
        #SlugTaken;
    };

    public type CreateShopQuoteError = ShopCreationAPI.CreateQuoteError or {
        #Unauthenticated;
        #Unauthorized;
        #PriceUnavailable : Text;
    };

    public type CreateShopError = ShopCreationAPI.ClaimError or {
        #Unauthenticated;
    };

    public type CreateShopResponse = Result<(Principal), CreateShopError>;
};
