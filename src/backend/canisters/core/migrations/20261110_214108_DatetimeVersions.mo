import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Order "mo:core/Order";
import Text "mo:core/Text";
import OldMap "mo:map/Map";

// Moves core's wasm versions from `major.minor.patch` records to datetimes (see `WasmVersion`). The
// old versions aren't carried over: install records, snapshot versions, rollouts and releases are
// dropped, and each name's current version is 1, the version the factory gives its first upload
// (`scripts/setup.sh`). Each shop's recorded vault is kept. Meant for a canister reinstalled with the
// new versioning, not for an upgrade that keeps its shops' versions.
module {
    type WasmName = { #shop; #vault };
    type OldVersion = { major : Nat; minor : Nat; patch : Nat };

    type OldInstalledWasm = { version : OldVersion; sha256 : ?Blob };
    type InstalledWasm = { version : Nat; sha256 : ?Blob };

    type OldRollout = {
        name : WasmName;
        version : OldVersion;
        canary : Principal;
        approved : Bool;
    };
    type Rollout = {
        name : WasmName;
        version : Nat;
        canary : Principal;
        approved : Bool;
    };

    type OldRelease = {
        name : WasmName;
        version : OldVersion;
        sha256 : Blob;
        size : Nat;
        notes : Text;
        publishedAt : Int;
        source : Principal;
    };
    type Release = {
        name : WasmName;
        version : Nat;
        sha256 : Blob;
        size : Nat;
        notes : Text;
        publishedAt : Int;
        source : Principal;
    };

    type OldActor = {
        shopCanistersState : {
            wasmVersions : OldMap.Map<Principal, OldInstalledWasm>;
            vaultsByShop : OldMap.Map<Principal, Principal>;
        };
        upgradesState : {
            rollouts : Map.Map<Text, OldRollout>;
            snapshotVersions : Map.Map<Principal, OldInstalledWasm>;
            currentVersions : Map.Map<WasmName, [OldVersion]>;
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
            currentVersions : Map.Map<WasmName, [Nat]>;
        };
        releasesState : { releases : Map.Map<Text, Release> };
    };

    func compareName(a : WasmName, b : WasmName) : Order.Order {
        func rank(n : WasmName) : Nat = switch (n) {
            case (#shop) 0;
            case (#vault) 1;
        };
        Nat.compare(rank(a), rank(b));
    };

    public func migration(old : OldActor) : NewActor {
        let currentVersions = Map.empty<WasmName, [Nat]>();
        Map.add(currentVersions, compareName, #shop, [1]);
        Map.add(currentVersions, compareName, #vault, [1]);
        {
            shopCanistersState = {
                wasmVersions = OldMap.new<Principal, InstalledWasm>();
                vaultsByShop = old.shopCanistersState.vaultsByShop;
            };
            upgradesState = {
                rollouts = Map.empty<Text, Rollout>();
                snapshotVersions = Map.empty<Principal, InstalledWasm>();
                currentVersions;
            };
            releasesState = { releases = Map.empty<Text, Release>() };
        };
    };
};
