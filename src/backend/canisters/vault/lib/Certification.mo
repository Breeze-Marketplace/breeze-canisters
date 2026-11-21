import Array "mo:core/Array";
import Assets "mo:assets";
import CertifiedAssets "mo:certified-assets";

/// What the vault certifies for each stored asset, so the HTTP gateway can verify responses.
module {
    let IDENTITY = "identity";

    /// The endpoint certifying `key`'s stored content, or null when it has no content (an asset
    /// created by a batch whose content hasn't been set). Uses the encoding's stored SHA-256 when the
    /// uploader gave one, else hashes every chunk, which for a large file costs many instructions.
    public func storedEndpoint(assets : Assets.Assets, key : Text) : ?CertifiedAssets.Endpoint {
        let ?details = assets.list({}).find(func a = a.key == key) else return null;
        let encoding = switch (details.encodings.find(func e = e.content_encoding == IDENTITY)) {
            case (?identity) identity;
            case null {
                if (details.encodings.size() == 0) return null;
                details.encodings[0];
            };
        };
        let endpoint = CertifiedAssets.Endpoint(key, null);
        switch (encoding.sha256) {
            case (?sha256) ignore endpoint.hash(sha256);
            case null ignore endpoint.chunks(contentChunks(assets, key, encoding.content_encoding));
        };
        ?endpoint.status(200).response_header("Content-Type", details.content_type);
    };

    func contentChunks(assets : Assets.Assets, key : Text, contentEncoding : Text) : [Blob] {
        let first = assets.get({ key; accept_encodings = [contentEncoding] });
        var chunks = [first.content];
        var length = first.content.size();
        var index = 1;
        while (length < first.total_length) {
            let { content } = assets.get_chunk({
                key;
                content_encoding = contentEncoding;
                index;
                sha256 = null;
            });
            if (content.size() == 0) return chunks;
            chunks := chunks.concat([content]);
            length += content.size();
            index += 1;
        };
        chunks;
    };

    /// Replaces whatever `certs` holds for `key` with its stored content, or removes it when the
    /// asset has none.
    public func recertify(assets : Assets.Assets, certs : CertifiedAssets.CertifiedAssets, key : Text) {
        certs.remove_all(key);
        switch (storedEndpoint(assets, key)) {
            case (?endpoint) certs.certify(endpoint);
            case null {};
        };
    };

    /// Every stored asset's key, for recertifying them all after an upgrade.
    public func keys(assets : Assets.Assets) : [Text] {
        assets.list({}).map(func a = a.key);
    };
};
