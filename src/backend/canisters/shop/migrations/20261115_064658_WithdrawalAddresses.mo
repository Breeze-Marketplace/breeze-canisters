import Map "mo:core/Map";

// Adds `withdrawalAddresses`, the Owner's labeled withdrawal addresses (BRE-150). None are saved
// yet: the browser-only list the withdraw form kept before isn't readable from here.
module {
    type Destination = { owner : Principal; subaccount : ?Blob };
    type Saved = { name : Text; addedAt : Int };

    public func migration(_old : {}) : {
        withdrawalAddresses : Map.Map<Destination, Saved>;
    } {
        { withdrawalAddresses = Map.empty() };
    };
};
