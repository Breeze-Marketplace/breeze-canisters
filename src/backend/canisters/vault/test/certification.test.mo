import { expect } "mo:test";
import { suite; test } "mo:test";

import Blob "mo:core/Blob";
import Principal "mo:core/Principal";
import Assets "mo:assets";
import Sha256 "mo:sha2/Sha256";

import Certification "../lib/Certification";

let uploader = Principal.fromText("aaaaa-aa");
let key = "/private/big.bin";
let chunkA : Blob = "first chunk of a large file|";
let chunkB : Blob = "second chunk";
let wholeHash = Sha256.fromBlob(#sha256, "first chunk of a large file|second chunk");

func showBlob(b : Blob) : Text = debug_show (b);

func newAssets() : Assets.Assets = Assets.Assets({
    serializedEntries = ([], [uploader]);
});

/// A large upload as the asset manager sends it: chunks, then one batch of create + set content.
func batchUpload(assets : Assets.Assets, sha256 : ?Blob) {
    let { batch_id } = assets.create_batch({ caller = uploader; arg = {} });
    let a = assets.create_chunk({
        caller = uploader;
        arg = { batch_id; content = chunkA };
    });
    let b = assets.create_chunk({
        caller = uploader;
        arg = { batch_id; content = chunkB };
    });
    assets.commit_batch({
        caller = uploader;
        args = {
            batch_id;
            operations = [
                #CreateAsset({ key; content_type = "application/octet-stream" }),
                #SetAssetContent({
                    key;
                    content_encoding = "identity";
                    chunk_ids = [a.chunk_id, b.chunk_id];
                    sha256;
                }),
            ];
        };
    });
};

func certifiedHash(assets : Assets.Assets) : ?Blob {
    switch (Certification.storedEndpoint(assets, key)) {
        case (?endpoint) ?endpoint.build().hash;
        case null null;
    };
};

suite(
    "storedEndpoint",
    func() {
        test(
            "hashes every chunk of a batch upload, not an empty body",
            func() {
                let assets = newAssets();
                batchUpload(assets, null);
                expect.option(certifiedHash(assets), showBlob, Blob.equal).equal(?wholeHash);
            },
        );

        test(
            "uses the uploader's SHA-256 when given",
            func() {
                let assets = newAssets();
                batchUpload(assets, ?wholeHash);
                expect.option(certifiedHash(assets), showBlob, Blob.equal).equal(?wholeHash);
            },
        );

        test(
            "is null for an asset with no content",
            func() {
                let assets = newAssets();
                let { batch_id } = assets.create_batch({
                    caller = uploader;
                    arg = {};
                });
                assets.commit_batch({
                    caller = uploader;
                    args = {
                        batch_id;
                        operations = [#CreateAsset({ key; content_type = "image/png" })];
                    };
                });
                expect.option(certifiedHash(assets), showBlob, Blob.equal).isNull();
            },
        );

        test(
            "is null for an unknown key",
            func() {
                expect.option(certifiedHash(newAssets()), showBlob, Blob.equal).isNull();
            },
        );
    },
);
