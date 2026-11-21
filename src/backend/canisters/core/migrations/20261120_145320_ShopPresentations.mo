import Map "mo:map/Map";

// Artist pages (BRE-197): each registered shop's presentation, storefront or artist page. Every shop
// already registered starts as a storefront; its next `ShopDetailsUpdated` event from a shop version
// that sends the presentation corrects it.
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
        slug : Text;
        owner : Principal;
        shopDetails : ShopDetails;
        registeredBy : Principal;
        registrationDate : Int;
    };

    type ShopRegistryItem = OldShopRegistryItem and {
        presentation : { #storefront; #artist };
    };

    type OldActor = {
        shopRegistry : Map.Map<Principal, OldShopRegistryItem>;
    };
    type NewActor = {
        shopRegistry : Map.Map<Principal, ShopRegistryItem>;
    };

    public func migration(old : OldActor) : NewActor {
        let shopRegistry = Map.new<Principal, ShopRegistryItem>();
        for ((shopId, item) in Map.entries(old.shopRegistry)) {
            Map.set<Principal, ShopRegistryItem>(shopRegistry, Map.phash, shopId, { item with presentation = #storefront });
        };
        { shopRegistry };
    };
};
