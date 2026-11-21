import { expect; suite; test } "mo:test";
import Principal "mo:core/Principal";
import Map "mo:map/Map";

import Migration "../migrations/20261120_145320_ShopPresentations";
import ShopAPI "../api/shop";

// The registry item as core had it before BRE-197.
type OldItem = {
    canisterId : Principal;
    slug : Text;
    owner : Principal;
    shopDetails : ShopAPI.ShopDetails;
    registeredBy : Principal;
    registrationDate : Int;
};

let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
let owner = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");

suite(
    "ShopPresentations migration (BRE-197)",
    func() {
        test(
            "every registered shop becomes a storefront and keeps the rest",
            func() {
                let old = Map.new<Principal, OldItem>();
                Map.set<Principal, OldItem>(
                    old,
                    Map.phash,
                    shopId,
                    {
                        canisterId = shopId;
                        slug = "gus";
                        owner;
                        shopDetails = {
                            name = "Gus";
                            description = "Songs";
                            logoUrl = null;
                            bannerImageUrl = null;
                            physicalLocation = null;
                            locationPublic = false;
                        };
                        registeredBy = owner;
                        registrationDate = 7;
                    },
                );
                let next = Migration.migration({ shopRegistry = old });
                expect.nat(Map.size(next.shopRegistry)).equal(1);
                switch (Map.get(next.shopRegistry, Map.phash, shopId)) {
                    case (?item) {
                        assert item.presentation == #storefront;
                        expect.text(item.slug).equal("gus");
                        expect.text(item.shopDetails.name).equal("Gus");
                        expect.int(item.registrationDate).equal(7);
                    };
                    case null assert false;
                };
            },
        );
    },
);
