import Array "mo:core/Array";
import Map "mo:core/Map";

// Adds the factory's interface number and breaking flag to published releases (BRE-85); releases
// published before get interface 0, not breaking. Also drops version 1 from the current versions:
// `DatetimeVersions` set it as a placeholder for the factory's first upload, which is now its
// upload time like any other, so no wasm has version 1. With none current, `setInitialWasmVersion`
// or an approved rollout sets one.
module {
    type WasmName = { #shop; #vault };

    type InstalledWasm = { version : Nat; sha256 : ?Blob };

    type Rollout = {
        name : WasmName;
        version : Nat;
        canary : Principal;
        approved : Bool;
    };

    type OldRelease = {
        name : WasmName;
        version : Nat;
        sha256 : Blob;
        size : Nat;
        notes : Text;
        publishedAt : Int;
        source : Principal;
    };

    type Release = {
        name : WasmName;
        version : Nat;
        interface : Nat;
        breaking : Bool;
        sha256 : Blob;
        size : Nat;
        notes : Text;
        publishedAt : Int;
        source : Principal;
    };

    type UpgradesState = {
        rollouts : Map.Map<Text, Rollout>;
        snapshotVersions : Map.Map<Principal, InstalledWasm>;
        currentVersions : Map.Map<WasmName, [Nat]>;
    };

    type OldActor = {
        upgradesState : UpgradesState;
        releasesState : { releases : Map.Map<Text, OldRelease> };
    };

    type NewActor = {
        upgradesState : UpgradesState;
        releasesState : { releases : Map.Map<Text, Release> };
    };

    public func migration(old : OldActor) : NewActor {
        {
            upgradesState = {
                old.upgradesState with
                currentVersions = Map.map<WasmName, [Nat], [Nat]>(
                    old.upgradesState.currentVersions,
                    func(_, history) = Array.filter<Nat>(history, func(v) = v != 1),
                );
            };
            releasesState = {
                releases = Map.map<Text, OldRelease, Release>(
                    old.releasesState.releases,
                    func(_, r) = { r with interface = 0; breaking = false },
                );
            };
        };
    };
};
