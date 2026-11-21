import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Order "mo:core/Order";
import OldMap "mo:map/Map";

// Moves core's wasm versions from free-text labels to the structured versions the canister factory
// assigns (BRE-85). The old labels aren't carried over: install records, snapshot versions,
// rollouts and published releases are dropped, so every existing shop and vault shows an unknown
// version until core upgrades it again. That's fine on the dev networks this runs on so far.
// Each shop's recorded vault is kept. Adds the current version of each name, the version new shops
// and vaults get, starting at 0.0.1: what `scripts/setup.sh` uploads first to the emptied factory.
module {
    type WasmName = { #shop; #vault };
    type Version = { major : Nat; minor : Nat; patch : Nat };

    type InstalledWasm = { version : Version; sha256 : ?Blob };

    type OldRollout = {
        name : Text;
        version : Text;
        canary : Principal;
        approved : Bool;
    };

    type Rollout = {
        name : WasmName;
        version : Version;
        canary : Principal;
        approved : Bool;
    };

    type OldRelease = {
        name : Text;
        version : Text;
        sha256 : Blob;
        size : Nat;
        notes : Text;
        publishedAt : Int;
        source : Principal;
    };

    type Release = {
        name : WasmName;
        version : Version;
        sha256 : Blob;
        size : Nat;
        notes : Text;
        publishedAt : Int;
        source : Principal;
    };

    type OldActor = {
        shopCanistersState : {
            wasmVersions : OldMap.Map<Principal, Text>;
            vaultsByShop : OldMap.Map<Principal, Principal>;
        };
        upgradesState : {
            rollouts : Map.Map<Text, OldRollout>;
            snapshotVersions : Map.Map<Principal, Text>;
        };
        releasesState : { releases : Map.Map<Text, OldRelease> };
    };

    type NewActor = {
        shopCanistersState : {
            wasmVersions : OldMap.Map<Principal, InstalledWasm>;
            vaultsByShop : OldMap.Map<Principal, Principal>;
        };
        upgradesState : {
            rollouts : Map.Map<Text, Rollout>;
            snapshotVersions : Map.Map<Principal, InstalledWasm>;
            currentVersions : Map.Map<WasmName, [Version]>;
        };
        releasesState : { releases : Map.Map<Text, Release> };
    };

    let first : Version = { major = 0; minor = 0; patch = 1 };

    func compareName(a : WasmName, b : WasmName) : Order.Order {
        func rank(n : WasmName) : Nat = switch (n) {
            case (#shop) { 0 };
            case (#vault) { 1 };
        };
        Nat.compare(rank(a), rank(b));
    };

    public func migration(old : OldActor) : NewActor {
        let wasmVersions = OldMap.new<Principal, InstalledWasm>();
        let snapshotVersions = Map.empty<Principal, InstalledWasm>();
        let rollouts = Map.empty<Text, Rollout>();
        let releases = Map.empty<Text, Release>();
        let currentVersions = Map.empty<WasmName, [Version]>();
        Map.add(currentVersions, compareName, #shop, [first]);
        Map.add(currentVersions, compareName, #vault, [first]);

        {
            shopCanistersState = {
                wasmVersions;
                vaultsByShop = old.shopCanistersState.vaultsByShop;
            };
            upgradesState = { rollouts; snapshotVersions; currentVersions };
            releasesState = { releases };
        };
    };
};
