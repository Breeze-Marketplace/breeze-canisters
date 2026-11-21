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
        #FullAddress : Address;
        #PostalCode : Text;
    };

    // Only the fields this migration regroups; the rest carry over unchanged.
    type OldActor = {
        var name : Text;
        var description : Text;
        var logoUrl : ?Text;
        var bannerImageUrl : ?Text;
        var physicalLocation : ?ShopLocation;
        var showPhysicalLocation : Bool;
        var mediaCanisterId : ?Principal;
        var hmacSecretKey : Blob;
        var hmacSecretKeyVersion : Nat8;
    };

    type NewActor = {
        profile : {
            var name : Text;
            var description : Text;
            var logoUrl : ?Text;
            var bannerImageUrl : ?Text;
            var physicalLocation : ?ShopLocation;
            var showPhysicalLocation : Bool;
        };
        media : {
            var mediaCanisterId : ?Principal;
            var hmacSecretKey : Blob;
            var hmacSecretKeyVersion : Nat8;
        };
    };

    /// Groups the shop profile and the media/delivery settings into records, so the mixins that own
    /// them can update their fields (a mixin can't assign an actor `var`).
    public func migration(old : OldActor) : NewActor {
        {
            profile = {
                var name = old.name;
                var description = old.description;
                var logoUrl = old.logoUrl;
                var bannerImageUrl = old.bannerImageUrl;
                var physicalLocation = old.physicalLocation;
                var showPhysicalLocation = old.showPhysicalLocation;
            };
            media = {
                var mediaCanisterId = old.mediaCanisterId;
                var hmacSecretKey = old.hmacSecretKey;
                var hmacSecretKeyVersion = old.hmacSecretKeyVersion;
            };
        };
    };
};
