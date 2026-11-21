import Iter "mo:core/Iter";
import Runtime "mo:core/Runtime";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Assets "mo:assets";
import CertifiedAssets "mo:certified-assets";

import Certification "../lib/Certification";
import Folders "../lib/Folders";
import Move "../lib/Move";
import Writers "../lib/Writers";

/// The media library: folders, and moving files between folders or between private and public.
/// Writers only, like every other write; folder names can describe private files, so listing them is
/// writers only too.
mixin (
    assets : Assets.Assets,
    certs : CertifiedAssets.CertifiedAssets,
    persistEntries : () -> (),
    writers : Writers.Writers,
    folders : Folders.Folders,
) {
    /// Creates `path` (e.g. `docs/contracts`) and the folders above it. Creating one that exists has
    /// no effect.
    public shared ({ caller }) func create_folder(path : Text) : async () {
        Writers.require(writers, caller);
        switch (Folders.create(folders, path)) {
            case (#ok(_)) {};
            case (#err(e)) Runtime.trap(Folders.errorMessage(e));
        };
    };

    /// Deletes `path` when it holds no folders and no files.
    public shared ({ caller }) func delete_folder(path : Text) : async () {
        Writers.require(writers, caller);
        switch (Folders.delete(folders, assets.assets.keys(), path)) {
            case (#ok) {};
            case (#err(e)) Runtime.trap(Folders.errorMessage(e));
        };
    };

    /// The folders created with `create_folder`. Files' keys imply more.
    public shared query ({ caller }) func list_folders() : async [Text] {
        Writers.require(writers, caller);
        folders.values().toArray();
    };

    /// Files `from`'s content under `to` and removes `from`, refusing to replace an existing asset.
    /// Moving between `/private/…` and `/public/…` changes who can read the file. Links to `from`
    /// stop working.
    public shared ({ caller }) func move_asset(arg : { from : Text; to : Text }) : async () {
        Writers.require(writers, caller);
        switch (Move.moveAsset(assets, arg.from, arg.to)) {
            case (#ok) {};
            case (#err(e)) Runtime.trap(Move.errorMessage(e));
        };
        persistEntries();
        Certification.recertify(assets, certs, arg.from);
        Certification.recertify(assets, certs, arg.to);
    };
};
