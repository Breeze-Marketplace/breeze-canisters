import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import CoreMap "mo:core/Map";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Map "mo:map/Map";

/// BRE-71: shops get URL slugs. Gives every registered shop a slug made from its name, in canister
/// ID order, with `-2`, `-3`, … when two clash, and records it in the new `shopSlugs`. Then gives
/// each quote that may still become a shop (not created or refunded) a slug the same way, reserved
/// in the new `shopCreationState.reservedSlugs`. Settled quotes get an empty slug: nothing reads it.
///
/// The slug rules are copied from `api/shop/slug.mo` as they are now, as a migration can't import
/// project modules.
module {
    type Address = {
        line1 : Text;
        line2 : ?Text;
        city : Text;
        region : Text;
        postalCode : Text;
        country : Text;
    };

    type ShopLocation = {
        #PostalCode : Text;
        #FullAddress : Address;
    };

    type ShopDetails = {
        name : Text;
        description : Text;
        logoUrl : ?Text;
        bannerImageUrl : ?Text;
        physicalLocation : ?ShopLocation;
        locationPublic : Bool;
    };

    type OldShopRegistryItem = {
        canisterId : Principal;
        owner : Principal;
        shopDetails : ShopDetails;
        registeredBy : Principal;
        registrationDate : Int;
    };

    type ShopRegistryItem = {
        canisterId : Principal;
        slug : Text;
        owner : Principal;
        shopDetails : ShopDetails;
        registeredBy : Principal;
        registrationDate : Int;
    };

    type QuoteId = Nat;

    type QuoteStatus = {
        #Pending;
        #Paid;
        #Creating;
        #Created : Principal;
        #Refunding;
        #Refunded;
    };

    type OldQuote = {
        id : QuoteId;
        owner : Principal;
        name : Text;
        normalizedName : Text;
        description : Text;
        currency : { #ICP; #ckUSDC };
        amount : Nat;
        createdAt : Int;
        expiresAt : Int;
        status : QuoteStatus;
        lastError : ?Text;
    };

    type Quote = {
        id : QuoteId;
        owner : Principal;
        name : Text;
        normalizedName : Text;
        slug : Text;
        description : Text;
        currency : { #ICP; #ckUSDC };
        amount : Nat;
        createdAt : Int;
        expiresAt : Int;
        status : QuoteStatus;
        lastError : ?Text;
    };

    type OldShopCreationState = {
        quotes : Map.Map<QuoteId, OldQuote>;
        quotesByOwner : Map.Map<Principal, [QuoteId]>;
        reservedNames : Map.Map<Text, QuoteId>;
        var nextQuoteId : QuoteId;
        var priceUsdCents : Nat;
    };

    type ShopCreationState = {
        quotes : Map.Map<QuoteId, Quote>;
        quotesByOwner : Map.Map<Principal, [QuoteId]>;
        reservedNames : Map.Map<Text, QuoteId>;
        reservedSlugs : CoreMap.Map<Text, QuoteId>;
        var nextQuoteId : QuoteId;
        var priceUsdCents : Nat;
    };

    type SlugState = {
        bySlug : CoreMap.Map<Text, Principal>;
        byShop : CoreMap.Map<Principal, [Text]>;
    };

    type OldActor = {
        shopRegistry : Map.Map<Principal, OldShopRegistryItem>;
        shopCreationState : OldShopCreationState;
    };

    type NewActor = {
        shopRegistry : Map.Map<Principal, ShopRegistryItem>;
        shopCreationState : ShopCreationState;
        shopSlugs : SlugState;
    };

    // Slug rules, as in api/shop/slug.mo.

    let MIN_LENGTH = 3;
    let MAX_LENGTH = 40;

    let RESERVED : [Text] = [
        "about",
        "account",
        "admin",
        "api",
        "cart",
        "checkout",
        "control",
        "costs",
        "dashboard",
        "edit",
        "funds",
        "help",
        "inventory",
        "invoice",
        "legal",
        "login",
        "logout",
        "media",
        "new",
        "orders",
        "policies",
        "products",
        "search",
        "sell",
        "settings",
        "shop",
        "shops",
        "support",
        "wallet",
    ];

    func isSlugChar(c : Char) : Bool {
        (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
    };

    func isPrincipalText(text : Text) : Bool {
        let bytes = List.empty<Nat8>();
        var buffer : Nat32 = 0;
        var bits : Nat32 = 0;
        for (c in text.chars()) {
            if (c != '-') {
                let n = Char.toNat32(c);
                let value : Nat32 = if (c >= 'a' and c <= 'z') { n - 97 } else if (c >= '2' and c <= '7') {
                    n - 50 + 26;
                } else { return false };
                buffer := ((buffer << 5) | value) & 0xFFFF;
                bits += 5;
                if (bits >= 8) {
                    bits -= 8;
                    bytes.add(Nat8.fromNat32((buffer >> bits) & 0xFF));
                };
            };
        };
        if (bytes.size() < 4 or bytes.size() > 33) { return false };
        let body = Array.sliceToArray(bytes.toArray(), 4, bytes.size());
        Principal.fromBlob(Blob.fromArray(body)).toText() == text;
    };

    func isValid(slug : Text) : Bool {
        let size = slug.size();
        if (size < MIN_LENGTH or size > MAX_LENGTH) { return false };
        var previousHyphen = true;
        for (c in slug.chars()) {
            if (c == '-') {
                if (previousHyphen) { return false };
                previousHyphen := true;
            } else if (isSlugChar(c)) {
                previousHyphen := false;
            } else { return false };
        };
        not previousHyphen and Array.find<Text>(RESERVED, func w = w == slug) == null and not isPrincipalText(slug);
    };

    func take(text : Text, n : Nat) : Text {
        var out = "";
        var count = 0;
        label chars for (c in text.chars()) {
            if (count >= n) break chars;
            out #= Char.toText(c);
            count += 1;
        };
        Text.trimEnd(out, #char '-');
    };

    func fromName(name : Text) : Text {
        var out = "";
        var size = 0;
        var previousHyphen = true;
        label chars for (c in Text.toLower(name).chars()) {
            if (size >= MAX_LENGTH) break chars;
            if (isSlugChar(c)) {
                out #= Char.toText(c);
                size += 1;
                previousHyphen := false;
            } else if (not previousHyphen) {
                out #= "-";
                size += 1;
                previousHyphen := true;
            };
        };
        let base = Text.trimEnd(out, #char '-');
        if (base == "") { return "my-shop" };
        if (isValid(base)) { return base };
        let padded = take(base, MAX_LENGTH - 5) # "-shop";
        if (isValid(padded)) { padded } else { "my-shop" };
    };

    func unique(base : Text, available : Text -> Bool) : Text {
        if (isValid(base) and available(base)) { return base };
        var n = 2;
        loop {
            let suffix = "-" # Nat.toText(n);
            let candidate = take(base, MAX_LENGTH - suffix.size()) # suffix;
            if (isValid(candidate) and available(candidate)) {
                return candidate;
            };
            n += 1;
        };
    };

    public func migration(old : OldActor) : NewActor {
        let bySlug = CoreMap.empty<Text, Principal>();
        let byShop = CoreMap.empty<Principal, [Text]>();
        let reservedSlugs = CoreMap.empty<Text, QuoteId>();
        func free(slug : Text) : Bool {
            not bySlug.containsKey(Text.compare, slug) and not reservedSlugs.containsKey(Text.compare, slug);
        };

        let shopIds = Array.sort(Iter.toArray(Map.keys(old.shopRegistry)), Principal.compare);
        for (id in shopIds.values()) {
            switch (Map.get(old.shopRegistry, Map.phash, id)) {
                case (?item) {
                    let slug = unique(fromName(item.shopDetails.name), free);
                    bySlug.add(Text.compare, slug, id);
                    byShop.add(Principal.compare, id, [slug]);
                };
                case null {};
            };
        };
        let shopRegistry = Map.map<Principal, OldShopRegistryItem, ShopRegistryItem>(
            old.shopRegistry,
            Map.phash,
            func(id, item) {
                let slug = switch (byShop.get(Principal.compare, id)) {
                    case (?own) { if (own.size() > 0) { own[0] } else { "" } };
                    case null { "" }; // unreachable: every shop got one above
                };
                { item with slug };
            },
        );

        let quoteIds = Array.sort(Iter.toArray(Map.keys(old.shopCreationState.quotes)), Nat.compare);
        let quoteSlugs = CoreMap.empty<QuoteId, Text>();
        for (id in quoteIds.values()) {
            switch (Map.get(old.shopCreationState.quotes, Map.nhash, id)) {
                case (?quote) {
                    switch (quote.status) {
                        case (#Created(_) or #Refunded) {};
                        case _ {
                            let slug = unique(fromName(quote.name), free);
                            reservedSlugs.add(Text.compare, slug, id);
                            quoteSlugs.add(Nat.compare, id, slug);
                        };
                    };
                };
                case null {};
            };
        };
        let quotes = Map.map<QuoteId, OldQuote, Quote>(
            old.shopCreationState.quotes,
            Map.nhash,
            func(id, quote) {
                let slug = switch (quoteSlugs.get(Nat.compare, id)) {
                    case (?s) { s };
                    case null { "" };
                };
                { quote with slug };
            },
        );

        {
            shopRegistry;
            shopCreationState = {
                quotes;
                quotesByOwner = old.shopCreationState.quotesByOwner;
                reservedNames = old.shopCreationState.reservedNames;
                reservedSlugs;
                var nextQuoteId = old.shopCreationState.nextQuoteId;
                var priceUsdCents = old.shopCreationState.priceUsdCents;
            };
            shopSlugs = { bySlug; byShop };
        };
    };
};
