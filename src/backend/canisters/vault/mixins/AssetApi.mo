import Array "mo:core/Array";
import Runtime "mo:core/Runtime";
import Assets "mo:assets";
import AssetsTypes "mo:assets/Types";
import CertifiedAssets "mo:certified-assets";

import Certification "../lib/Certification";
import Visibility "../lib/Visibility";
import Writers "../lib/Writers";

/// The asset-canister-compatible API. `persistEntries` saves `assets.entries()` to the actor's stable
/// `entries` var, which this mixin can't assign itself. Every write checks `writers`, then calls
/// `assets` as `vault`, the only principal on `mo:assets`' own list.
mixin (
    assets : Assets.Assets,
    certs : CertifiedAssets.CertifiedAssets,
    persistEntries : () -> (),
    writers : Writers.Writers,
    creator : Principal,
    vault : Principal,
) {
    /// Lets `other` write. Writers only; adding one twice has no effect.
    public shared ({ caller }) func authorize(other : Principal) : async () {
        Writers.require(writers, caller);
        Writers.add(writers, other);
    };

    /// Takes write access away from `other`. Writers only. Refuses to remove the creator (core) or
    /// the last writer.
    public shared ({ caller }) func deauthorize(other : Principal) : async () {
        Writers.require(writers, caller);
        switch (Writers.remove(writers, creator, other)) {
            case (#ok) {};
            case (#err(#creator)) Runtime.trap("can't remove the canister that created this vault");
            case (#err(#last)) Runtime.trap("can't remove the last authorized principal");
        };
    };

    /// Who can write. Writers only. An update, like the stock asset canister's.
    public shared ({ caller }) func list_authorized() : async [Principal] {
        Writers.require(writers, caller);
        Writers.toArray(writers);
    };

    /// Private keys: writers only.
    public shared query ({ caller }) func retrieve(path : Assets.Path) : async Assets.Contents {
        Visibility.requireReadable(writers, caller, path);
        assets.retrieve(path);
    };

    public shared ({ caller }) func store(
        arg : {
            key : Assets.Key;
            content_type : Text;
            content_encoding : Text;
            content : Blob;
            sha256 : ?Blob;
        }
    ) : async () {
        Writers.require(writers, caller);
        assets.store({
            caller = vault;
            arg;
        });
        persistEntries();
        Certification.recertify(assets, certs, arg.key);
    };

    /// Writers see every asset; anyone else sees public ones only.
    public shared query ({ caller }) func list(arg : {}) : async [AssetsTypes.AssetDetails] {
        let all = assets.list(arg);
        if (Writers.isWriter(writers, caller)) return all;
        all.filter(func(asset : AssetsTypes.AssetDetails) : Bool = not Visibility.isPrivate(asset.key));
    };

    /// Private keys: writers only.
    public shared query ({ caller }) func get(
        arg : {
            key : AssetsTypes.Key;
            accept_encodings : [Text];
        }
    ) : async ({
        content : Blob;
        content_type : Text;
        content_encoding : Text;
        total_length : Nat;
        sha256 : ?Blob;
    }) {
        Visibility.requireReadable(writers, caller, arg.key);
        assets.get(arg);
    };

    /// Private keys: writers only.
    public shared query ({ caller }) func get_chunk(
        arg : {
            key : AssetsTypes.Key;
            content_encoding : Text;
            index : Nat;
            sha256 : ?Blob;
        }
    ) : async ({
        content : Blob;
    }) {
        Visibility.requireReadable(writers, caller, arg.key);
        assets.get_chunk(arg);
    };

    public shared ({ caller }) func create_batch(arg : {}) : async ({
        batch_id : AssetsTypes.BatchId;
    }) {
        Writers.require(writers, caller);
        assets.create_batch({
            caller = vault;
            arg;
        });
    };

    public shared ({ caller }) func create_chunk(
        arg : {
            batch_id : AssetsTypes.BatchId;
            content : Blob;
        }
    ) : async ({
        chunk_id : AssetsTypes.ChunkId;
    }) {
        Writers.require(writers, caller);
        assets.create_chunk({
            caller = vault;
            arg;
        });
    };

    public shared ({ caller }) func commit_batch(args : AssetsTypes.CommitBatchArguments) : async () {
        Writers.require(writers, caller);
        assets.commit_batch({
            caller = vault;
            args;
        });
        persistEntries();

        // Certify what the batch left stored, not what each operation says: large uploads arrive as
        // `CreateAsset` (no content yet) then `SetAssetContent` in one batch.
        for (op in args.operations.values()) {
            switch (op) {
                case (#CreateAsset({ key })) Certification.recertify(assets, certs, key);
                case (#SetAssetContent({ key })) Certification.recertify(assets, certs, key);
                case (#UnsetAssetContent({ key })) Certification.recertify(assets, certs, key);
                case (#DeleteAsset({ key })) Certification.recertify(assets, certs, key);
                case (#Clear(_)) certs.clear();
            };
        };
    };

    // `create_asset` has no content yet, so only `set_asset_content` certifies the endpoint.
    public shared ({ caller }) func create_asset(arg : AssetsTypes.CreateAssetArguments) : async () {
        Writers.require(writers, caller);
        assets.create_asset({
            caller = vault;
            arg;
        });
        persistEntries();
    };

    public shared ({ caller }) func set_asset_content(arg : AssetsTypes.SetAssetContentArguments) : async () {
        Writers.require(writers, caller);
        assets.set_asset_content({
            caller = vault;
            arg;
        });
        persistEntries();
        Certification.recertify(assets, certs, arg.key);
    };

    public shared ({ caller }) func unset_asset_content(args : AssetsTypes.UnsetAssetContentArguments) : async () {
        Writers.require(writers, caller);
        assets.unset_asset_content({
            caller = vault;
            args;
        });
        persistEntries();
        Certification.recertify(assets, certs, args.key);
    };

    public shared ({ caller }) func delete_asset(args : AssetsTypes.DeleteAssetArguments) : async () {
        Writers.require(writers, caller);
        assets.delete_asset({
            caller = vault;
            args;
        });
        persistEntries();
        Certification.recertify(assets, certs, args.key);
    };

    public shared ({ caller }) func clear(args : AssetsTypes.ClearArguments) : async () {
        Writers.require(writers, caller);
        assets.clear({
            caller = vault;
            args;
        });
        persistEntries();
        certs.clear();
    };

    /// Recertifies every stored asset, one message each so hashing a large file can't exhaust
    /// another's instruction budget. Run after each upgrade (see `main.mo`): vaults before this fix
    /// certified batch-uploaded files as empty, which the gateway rejects. A failure only skips
    /// that asset.
    private func recertifyAllAssets() : async () {
        for (key in Certification.keys(assets).values()) {
            try { await recertifyAsset(key) } catch (_) {};
        };
    };

    private func recertifyAsset(key : Text) : async () {
        Certification.recertify(assets, certs, key);
    };
};
