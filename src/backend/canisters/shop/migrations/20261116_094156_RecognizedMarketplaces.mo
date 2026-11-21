import Map "mo:core/Map";

// Adds `recognizedMarketplaces`: the marketplaces the Owner confirmed, with each one's frontend
// canister and name. Starts empty: earlier Marketplace grants keep their access but were never
// confirmed with these details.
module {
    type RecognizedMarketplace = {
        backendCanisterId : Principal;
        frontendCanisterId : ?Principal;
        name : Text;
        recognizedAt : Int;
        recognizedBy : Principal;
    };

    type OldActor = {};
    type NewActor = {
        recognizedMarketplaces : Map.Map<Principal, RecognizedMarketplace>;
    };

    public func migration(_ : OldActor) : NewActor {
        { recognizedMarketplaces = Map.empty() };
    };
};
