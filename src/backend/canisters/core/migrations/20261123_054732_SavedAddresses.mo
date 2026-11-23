import Map "mo:core/Map";

// Saved addresses (BRE-209): each user's saved shipping addresses. No one has any yet.
module {
    type ShippingAddress = {
        name : Text;
        phone : ?Text;
        line1 : Text;
        line2 : ?Text;
        city : Text;
        region : Text;
        postalCode : Text;
        country : Text;
    };

    type UserAddresses = {
        var nextId : Nat;
        var defaultId : ?Nat;
        byId : Map.Map<Nat, { nickname : Text; address : ShippingAddress; updatedAt : Int }>;
    };

    public func migration(_ : {}) : {
        savedAddresses : Map.Map<Principal, UserAddresses>;
    } {
        { savedAddresses = Map.empty() };
    };
};
