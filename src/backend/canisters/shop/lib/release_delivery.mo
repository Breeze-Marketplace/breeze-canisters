import Array "mo:core/Array";
import Map "mo:core/Map";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import Music "music";

/// Delivering a release a buyer paid for (BRE-185): who may download it, and which files they get.
/// The files are read from the release as it stands at call time, so tracks added and files replaced
/// after the sale reach every past buyer. Takes structural order fields rather than `../types` (which
/// imports `canister:xrc`) so it can run under `mops test`.
module ReleaseDelivery {
    /// The order statuses `OrderStatus` has, spelled out here for the same reason.
    public type OrderStatus = {
        #created;
        #awaitingPayment;
        #paid;
        #processing;
        #partiallyFulfilled;
        #fulfilled;
        #canceled;
        #refunded;
    };

    public type Order = {
        buyer : Principal;
        status : OrderStatus;
        items : [{ variantId : Nat32; quantity : Nat32 }];
    };

    public type ReleaseDeliveryError = {
        #NotFound : Text;
        #Unauthorized : Text;
        #OrderNotPaid : Text;
        #InvalidLineIndex : Text;
        /// The line's variant doesn't sell a release.
        #NotARelease : Text;
        /// No track of the release has a file in the requested format.
        #FormatUnavailable : Text;
        #InvalidInput : Text;
        #MediaNotConfigured : Text;
    };

    /// One file to download, with the ticket the vault checks for it.
    public type ReleaseDownload = {
        trackId : Music.TrackId;
        format : Music.AudioFormat;
        bytes : Nat;
        mediaKey : Text;
        token : Text;
    };

    /// Every file of release `releaseId` in `format`, in track order. A track with no file in that
    /// format is left out. Tickets for the files expire together at `expiresAt` (seconds).
    public type ReleaseDeliveryResponse = {
        releaseId : Music.ReleaseId;
        format : Music.AudioFormat;
        expiresAt : Nat64;
        files : [ReleaseDownload];
    };

    /// The most tickets `requestReleaseDelivery` signs in one call: one per track.
    public let MAX_FILES = Music.Limits.MAX_TRACKS_PER_RELEASE;

    /// The release order line `lineIndex` sells, if `caller` bought it and the order is paid.
    /// `deliverableOf` reads a variant's current deliverable (null for a deleted variant).
    public func releaseFor(
        caller : Principal,
        order : Order,
        lineIndex : Nat,
        deliverableOf : Nat32 -> ?Music.Deliverable,
    ) : Result<Music.ReleaseId, ReleaseDeliveryError> {
        if (caller.isAnonymous() or caller != order.buyer) {
            return #err(#Unauthorized("Only the order's buyer can download its music"));
        };
        if (not isPaid(order.status)) {
            return #err(#OrderNotPaid("The order must be paid before its music can be downloaded"));
        };
        if (lineIndex >= order.items.size()) {
            return #err(#InvalidLineIndex("Line index is out of range for this order"));
        };
        let line = order.items[lineIndex];
        // Orders refuse empty lines now, but an older order may hold one that wasn't paid for.
        if (line.quantity == 0) {
            return #err(#InvalidLineIndex("This order line has no units, so nothing was bought on it"));
        };
        switch (deliverableOf(line.variantId)) {
            case (?#release(id)) #ok(id);
            case null #err(#NotARelease("This order line doesn't sell a release"));
        };
    };

    /// Paid orders, fulfilled or not. A refunded or cancelled order delivers nothing.
    public func isPaid(status : OrderStatus) : Bool {
        switch (status) {
            case (#paid or #processing or #partiallyFulfilled or #fulfilled) true;
            case (#created or #awaitingPayment or #canceled or #refunded) false;
        };
    };

    /// The files of release `releaseId` in `format` as it stands now, in track order, each with its
    /// track's id.
    public func filesOf(library : Music.Library, releaseId : Music.ReleaseId, format : Music.AudioFormat) : Result<[(Music.TrackId, Music.AudioFile)], ReleaseDeliveryError> {
        let ?release = library.releases.get(releaseId) else return #err(#NotFound("Release " # Nat32.toText(releaseId) # " not found"));
        let files = release.tracks.filterMap(
            func(id : Music.TrackId) : ?(Music.TrackId, Music.AudioFile) {
                let ?track = library.tracks.get(id) else return null;
                switch (track.files.find(func(f : Music.AudioFile) : Bool = f.format == format)) {
                    case (?file) ?(id, file);
                    case null null;
                };
            }
        );
        if (files.size() == 0) return #err(#FormatUnavailable("This release has no " # describe(format) # " files"));
        #ok(files);
    };

    /// The nonce for the `index`-th ticket of one call: the first 12 bytes of `seed` (from
    /// `raw_rand`), then `index` as 4 big-endian bytes, so one draw gives each ticket its own nonce.
    public func fileNonce(seed : Blob, index : Nat) : Blob {
        let bytes = seed.toArray();
        let n = Nat32.fromNat(index % 4_294_967_296);
        let counter : [Nat8] = [
            Nat8.fromNat((n >> 24).toNat() % 256),
            Nat8.fromNat((n >> 16).toNat() % 256),
            Nat8.fromNat((n >> 8).toNat() % 256),
            Nat8.fromNat(n.toNat() % 256),
        ];
        Blob.fromArray(
            Array.tabulate<Nat8>(
                16,
                func(i : Nat) : Nat8 {
                    if (i < 12) { if (i < bytes.size()) bytes[i] else 0 } else counter[i - 12 : Nat];
                },
            )
        );
    };

    public func describe(format : Music.AudioFormat) : Text {
        switch (format) {
            case (#mp3_320) "MP3";
            case (#flac) "FLAC";
            case (#wav) "WAV";
            case (#aiff) "AIFF";
            case (#alac) "ALAC";
            case (#aac_256) "AAC";
        };
    };
};
