import Array "mo:core/Array";
import Map "mo:core/Map";
import Int "mo:core/Int";
import { type Result } "mo:core/Result";
import Text "mo:core/Text";

import WasmVersion "../../../../lib/WasmVersion";

/// Published shop and vault releases (BRE-79): the wasm versions self-managed merchants can install
/// themselves, each with its SHA-256 and release notes. Admins publish a version stored in the
/// canister factory (`publish`); anyone can list releases and download a published wasm.
module {
    public type Release = {
        name : WasmVersion.WasmName;
        version : WasmVersion.Version;
        /// The canister factory's interface number: a merchant can upgrade between releases with the
        /// same interface without breaking callers. A different one may break them (BRE-85).
        interface : Nat;
        /// The factory marked the upload breaking against the version before it.
        breaking : Bool;
        /// SHA-256 of the wasm, as the canister factory computed it on upload (BRE-85). A version's
        /// bytes never change there. Equals the module hash `icp canister status` shows once it's
        /// installed.
        sha256 : Blob;
        size : Nat;
        /// What changed, whether it migrates state, and anything a merchant must do.
        notes : Text;
        publishedAt : Int;
        /// The canister factory core fetched the wasm from; `getShopRelease` reads it there.
        source : Principal;
    };

    public type State = {
        /// Releases by `key(name, version)`.
        releases : Map.Map<Text, Release>;
    };

    public type PublishError = {
        #Unauthorized;
        /// Notes longer than `MAX_NOTES` characters.
        #NotesTooLong;
        /// The canister factory holds no wasm for this name and version.
        #WasmNotFound;
        /// The version was yanked in the canister factory.
        #WasmYanked;
    };

    /// What `publish` needs from the canister factory about a version.
    public type WasmInfo = {
        interface : Nat;
        breaking : Bool;
        sha256 : Blob;
        size : Nat;
        yanked : Bool;
    };

    /// Caps what an admin stores per release.
    public let MAX_NOTES = 4_000;

    public func newState() : State {
        { releases = Map.empty<Text, Release>() };
    };

    public func key(name : WasmVersion.WasmName, version : WasmVersion.Version) : Text {
        WasmVersion.key(name, version);
    };

    /// Records `name`'s wasm `version` as a release, with the hash and size the canister factory
    /// holds for it. Publishing a version again replaces its notes. A yanked version is refused. The
    /// caller checks that the caller is an admin.
    public func publish(
        state : State,
        name : WasmVersion.WasmName,
        version : WasmVersion.Version,
        notes : Text,
        source : Principal,
        getWasmInfo : (WasmVersion.WasmName, WasmVersion.Version) -> async ?WasmInfo,
        now : Int,
    ) : async Result<Release, PublishError> {
        if (notes.size() > MAX_NOTES) { return #err(#NotesTooLong) };
        let info = switch (await getWasmInfo(name, version)) {
            case (?i) { i };
            case (null) { return #err(#WasmNotFound) };
        };
        if (info.yanked) { return #err(#WasmYanked) };
        let release : Release = {
            name;
            version;
            interface = info.interface;
            breaking = info.breaking;
            sha256 = info.sha256;
            size = info.size;
            notes;
            publishedAt = now;
            source;
        };
        Map.add(state.releases, Text.compare, key(name, version), release);
        #ok(release);
    };

    public func get(state : State, name : WasmVersion.WasmName, version : WasmVersion.Version) : ?Release {
        Map.get(state.releases, Text.compare, key(name, version));
    };

    /// Every release, newest first.
    public func list(state : State) : [Release] {
        let all = Array.fromIter(Map.values(state.releases));
        all.sort(func(a, b) = Int.compare(b.publishedAt, a.publishedAt));
    };
};
