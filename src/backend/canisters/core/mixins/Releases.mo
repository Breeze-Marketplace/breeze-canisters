import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Time "mo:core/Time";

import AdminAPI "../api/admin";
import PlatformPermissions "../../../lib/PlatformPermissions";
import ReleasesAPI "../api/releases";
import Siblings "../lib/Siblings";
import HistoryAPI "../api/history";

/// Published shop and vault releases, for merchants who manage their own shop (BRE-79; see
/// `api/releases`).
mixin (adminApi : AdminAPI.API, releasesState : ReleasesAPI.State, history : HistoryAPI.State) {
    /// Publishes a shop or vault wasm version stored in the canister factory, with release notes
    /// (at most `MAX_NOTES` characters), so self-managed merchants can install it. Core records the
    /// SHA-256 the factory computed on upload. Publish a version once its rollout is approved; a
    /// yanked version is refused. Needs `Upgrades.Approve`.
    public shared ({ caller }) func publishRelease(name : Siblings.WasmName, version : Siblings.Version, notes : Text) : async Result<ReleasesAPI.Release, ReleasesAPI.PublishError> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.upgradesApprove)) {
            return #err(#Unauthorized);
        };
        let factory = Siblings.canisterFactory<system>();
        let result = await ReleasesAPI.publish(
            releasesState,
            name,
            version,
            notes,
            Principal.fromActor(factory),
            func(n : Siblings.WasmName, v : Siblings.Version) : async ?ReleasesAPI.WasmInfo {
                await factory.getWasmInfo(n, v);
            },
            Time.now(),
        );
        switch (result) {
            case (#ok(_)) ignore HistoryAPI.record(history, caller, null, #releasePublished({ name; version }));
            case (#err(_)) {};
        };
        result;
    };

    /// Every published release, newest first: version, SHA-256, size and notes. Public. Call it
    /// as an update (the `icp` default) for a certified answer to check a download against.
    public query func listShopReleases() : async [ReleasesAPI.Release] {
        ReleasesAPI.list(releasesState);
    };

    /// The wasm of a published release, from the canister factory. Public; only published
    /// versions. A composite query, so the answer isn't certified: check its SHA-256 against
    /// `listShopReleases`.
    public composite query func getShopRelease(name : Siblings.WasmName, version : Siblings.Version) : async Result<Blob, { #NotPublished }> {
        let release = switch (ReleasesAPI.get(releasesState, name, version)) {
            case (?r) { r };
            case (null) { return #err(#NotPublished) };
        };
        let factory = actor (release.source.toText()) : actor {
            getWasm : query (Siblings.WasmName, Siblings.Version) -> async Result<{ wasm : Blob; sha256 : Blob }, { #NotFound; #Yanked }>;
        };
        // A version yanked after publishing can't be downloaded either.
        switch (await factory.getWasm(name, version)) {
            case (#ok({ wasm })) { #ok(wasm) };
            case (#err(_)) { #err(#NotPublished) };
        };
    };
};
