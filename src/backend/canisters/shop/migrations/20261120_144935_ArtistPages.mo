import Map "mo:map/Map";

// Artist pages (BRE-197):
// - Adds `presentation`: every existing shop shows as a storefront, with the default artist preset
//   (Liner Notes) and no artist profile until its owner sets one.
// - Shop-details events now carry the presentation. The subscribers' callbacks are stored with the
//   event type, so they are re-typed: a callback that took the old event takes the new one (its extra
//   field is dropped by a subscriber that doesn't know it).
module {
    type Address = {
        line1 : Text;
        line2 : ?Text;
        city : Text;
        region : Text;
        postalCode : Text;
        country : Text;
    };
    type ShopLocation = { #PostalCode : Text; #FullAddress : Address };
    type Presentation = { #storefront; #artist };

    type OldEventData = {
        name : Text;
        description : Text;
        logoUrl : Text;
        bannerImageUrl : ?Text;
        physicalLocation : ?ShopLocation;
        locationPublic : Bool;
    };
    type NewEventData = OldEventData and { presentation : ?Presentation };

    type OldListener = shared { data : OldEventData } -> async ();
    type NewListener = shared { data : NewEventData } -> async ();

    type ArtistProfile = {
        bio : Text;
        photoKey : ?Text;
        links : [{
            kind : { #website; #store; #streaming; #social; #other };
            url : Text;
        }];
    };

    type OldActor = {
        shopDetailsUpdatedSubscribers : Map.Map<Principal, OldListener>;
    };
    type NewActor = {
        shopDetailsUpdatedSubscribers : Map.Map<Principal, NewListener>;
        presentation : {
            var mode : Presentation;
            var artistPreset : { #linerNotes };
            var artistProfile : ?ArtistProfile;
        };
    };

    public func migration(old : OldActor) : NewActor {
        let shopDetailsUpdatedSubscribers = Map.new<Principal, NewListener>();
        for ((subscriber, listener) in Map.entries(old.shopDetailsUpdatedSubscribers)) {
            Map.set<Principal, NewListener>(shopDetailsUpdatedSubscribers, Map.phash, subscriber, listener);
        };
        {
            shopDetailsUpdatedSubscribers;
            presentation = {
                var mode = #storefront;
                var artistPreset = #linerNotes;
                var artistProfile = null;
            };
        };
    };
};
