import Map "mo:map/Map";

// Adds the admin shop registry's state (BRE-26): the wasm version core last installed on each shop
// and vault, and each shop's vault. Canisters created before this have no entry: unknown.
module {
    type ShopCanistersState = {
        wasmVersions : Map.Map<Principal, Text>;
        vaultsByShop : Map.Map<Principal, Principal>;
    };

    type OldActor = {};

    type NewActor = {
        shopCanistersState : ShopCanistersState;
    };

    public func migration(_ : OldActor) : NewActor {
        {
            shopCanistersState = {
                wasmVersions = Map.new<Principal, Text>();
                vaultsByShop = Map.new<Principal, Principal>();
            };
        };
    };
};
