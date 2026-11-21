import { expect; suite; test } "mo:test";

import Map "mo:map/Map";

import Migration "../migrations/20261120_144935_ArtistPages";

type OldListener = shared {
    data : {
        name : Text;
        description : Text;
        logoUrl : Text;
        bannerImageUrl : ?Text;
        physicalLocation : ?{
            #PostalCode : Text;
            #FullAddress : {
                line1 : Text;
                line2 : ?Text;
                city : Text;
                region : Text;
                postalCode : Text;
                country : Text;
            };
        };
        locationPublic : Bool;
    };
} -> async ();

suite(
    "ArtistPages migration (BRE-197)",
    func() {
        test(
            "every shop shows as a storefront with the Liner Notes preset and no artist profile",
            func() {
                let next = Migration.migration({
                    shopDetailsUpdatedSubscribers = Map.new<Principal, OldListener>();
                });
                assert next.presentation.mode == #storefront;
                assert next.presentation.artistPreset == #linerNotes;
                assert next.presentation.artistProfile == null;
                expect.nat(Map.size(next.shopDetailsUpdatedSubscribers)).equal(0);
            },
        );
    },
);
