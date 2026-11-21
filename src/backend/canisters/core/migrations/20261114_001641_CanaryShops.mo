import Map "mo:core/Map";
import Set "mo:core/Set";

// Adds the shops admins allow as rollout canaries (BRE-147), none at first: until an admin marks a
// shop, no new version can get a canary.
module {
    type WasmName = { #shop; #vault };

    type InstalledWasm = { version : Nat; sha256 : ?Blob };

    type Rollout = {
        name : WasmName;
        version : Nat;
        canary : Principal;
        approved : Bool;
    };

    type OldActor = {
        upgradesState : {
            rollouts : Map.Map<Text, Rollout>;
            snapshotVersions : Map.Map<Principal, InstalledWasm>;
            currentVersions : Map.Map<WasmName, [Nat]>;
        };
    };

    type NewActor = {
        upgradesState : {
            rollouts : Map.Map<Text, Rollout>;
            snapshotVersions : Map.Map<Principal, InstalledWasm>;
            currentVersions : Map.Map<WasmName, [Nat]>;
            canaryShops : Set.Set<Principal>;
        };
    };

    public func migration(old : OldActor) : NewActor {
        {
            upgradesState = {
                old.upgradesState with
                canaryShops = Set.empty<Principal>();
            };
        };
    };
};
