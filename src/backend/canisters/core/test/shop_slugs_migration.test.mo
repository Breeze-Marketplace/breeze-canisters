import { expect; suite; test } "mo:test";
import CoreMap "mo:core/Map";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Map "mo:map/Map";

import Migration "../migrations/20261108_011041_ShopSlugs";
import ShopAPI "../api/shop";

// The migration's input types, as core had them before slugs (BRE-71).
type OldItem = {
    canisterId : Principal;
    owner : Principal;
    shopDetails : ShopAPI.ShopDetails;
    registeredBy : Principal;
    registrationDate : Int;
};

type QuoteStatus = {
    #Pending;
    #Paid;
    #Creating;
    #Created : Principal;
    #Refunding;
    #Refunded;
};

type OldQuote = {
    id : Nat;
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

let shopA = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let shopB = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let shopC = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");
let alice = Principal.fromText("vg3po-ix777-77774-qaafa-cai");

func shop(canisterId : Principal, name : Text) : OldItem = {
    canisterId;
    owner = alice;
    shopDetails = {
        name;
        description = "";
        logoUrl = null;
        bannerImageUrl = null;
        physicalLocation = null;
        locationPublic = false;
    };
    registeredBy = alice;
    registrationDate = 0;
};

func quote(id : Nat, name : Text, status : QuoteStatus) : OldQuote = {
    id;
    owner = alice;
    name;
    normalizedName = name;
    description = "";
    currency = #ICP;
    amount = 0;
    createdAt = 0;
    expiresAt = 0;
    status;
    lastError = null;
};

func run(shops : [OldItem], quotes : [OldQuote]) : {
    slugOf : Principal -> Text;
    quoteSlug : Nat -> Text;
    slugs : ShopAPI.SlugState;
    reservedSlugs : CoreMap.Map<Text, Nat>;
} {
    let shopRegistry = Map.new<Principal, OldItem>();
    for (s in shops.values()) {
        Map.set(shopRegistry, Map.phash, s.canisterId, s);
    };
    let quoteMap = Map.new<Nat, OldQuote>();
    for (q in quotes.values()) { Map.set(quoteMap, Map.nhash, q.id, q) };
    let next = Migration.migration({
        shopRegistry;
        shopCreationState = {
            quotes = quoteMap;
            quotesByOwner = Map.new<Principal, [Nat]>();
            reservedNames = Map.new<Text, Nat>();
            var nextQuoteId = quotes.size();
            var priceUsdCents = 0;
        };
    });
    {
        slugOf = func(id : Principal) : Text {
            switch (Map.get(next.shopRegistry, Map.phash, id)) {
                case (?item) { item.slug };
                case null { "?" };
            };
        };
        quoteSlug = func(id : Nat) : Text {
            switch (Map.get(next.shopCreationState.quotes, Map.nhash, id)) {
                case (?q) { q.slug };
                case null { "?" };
            };
        };
        slugs = next.shopSlugs;
        reservedSlugs = next.shopCreationState.reservedSlugs;
    };
};

suite(
    "Migration ShopSlugs",
    func() {
        test(
            "gives each shop a slug from its name, suffixed in canister ID order on a clash",
            func() {
                // Sorted by canister ID: shopA < shopB < shopC.
                let r = run([shop(shopC, "Blue Heron!"), shop(shopA, "Blue Heron"), shop(shopB, "Owl")], []);
                expect.text(r.slugOf(shopA)).equal("blue-heron");
                expect.text(r.slugOf(shopB)).equal("owl");
                expect.text(r.slugOf(shopC)).equal("blue-heron-2");
                let bySlug = r.slugs.bySlug;
                expect.bool(bySlug.get(Text.compare, "blue-heron-2") == ?shopC).isTrue();
                expect.bool(r.slugs.byShop.get(Principal.compare, shopA) == ?["blue-heron"]).isTrue();
            },
        );
        test(
            "gives open quotes a free slug and settled quotes none",
            func() {
                let r = run(
                    [shop(shopA, "Heron")],
                    [quote(0, "Heron", #Paid), quote(1, "Done", #Created(shopB)), quote(2, "Kite", #Pending), quote(3, "Gone", #Refunded)],
                );
                expect.text(r.quoteSlug(0)).equal("heron-2");
                expect.text(r.quoteSlug(1)).equal("");
                expect.text(r.quoteSlug(2)).equal("kite");
                expect.text(r.quoteSlug(3)).equal("");
                expect.bool(r.reservedSlugs.get(Text.compare, "heron-2") == ?0).isTrue();
                expect.bool(r.reservedSlugs.get(Text.compare, "kite") == ?2).isTrue();
                expect.nat(r.reservedSlugs.size()).equal(2);
            },
        );
    },
);
