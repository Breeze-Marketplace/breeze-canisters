import Map "mo:map/Map";
import Principal "mo:core/Principal";
import Set "mo:core/Set";

// Artist discovery (BRE-201): `artistShops` lists the registered shops shown as artist pages, filled
// from the registry's presentations, and `hiddenShops` the shops trust_safety hid. Core learned of
// hidden shops only from now on, so it starts empty and core fills it from product_index after the
// upgrade; `hiddenShopsCopy.complete` stays false until that first copy finishes, and until then
// `listArtistShops` lists no one, so no hidden artist shows in between.
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

    type ShopRegistryItem = {
        canisterId : Principal;
        slug : Text;
        owner : Principal;
        shopDetails : ShopDetails;
        registeredBy : Principal;
        registrationDate : Int;
        presentation : { #storefront; #artist };
    };

    type OldActor = {
        shopRegistry : Map.Map<Principal, ShopRegistryItem>;
    };
    type NewActor = {
        shopRegistry : Map.Map<Principal, ShopRegistryItem>;
        artistShops : Set.Set<Principal>;
        hiddenShops : Set.Set<Principal>;
        hiddenShopsCopy : { var complete : Bool };
    };

    public func migration(old : OldActor) : NewActor {
        let artistShops = Set.empty<Principal>();
        for ((shopId, item) in Map.entries(old.shopRegistry)) {
            if (item.presentation == #artist) {
                Set.add(artistShops, Principal.compare, shopId);
            };
        };
        {
            shopRegistry = old.shopRegistry;
            artistShops;
            hiddenShops = Set.empty<Principal>();
            hiddenShopsCopy = { var complete = false };
        };
    };
};
