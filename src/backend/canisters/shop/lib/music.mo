import Array "mo:core/Array";
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Time "mo:core/Time";

import Pagination "../../../lib/Pagination";
import AuthService "auth";
import ShopPermissions "permissions";

/// The shop's music library (BRE-182): tracks, and releases (single, EP, album) that list them in
/// order. A product variant sells a release through its `deliverable`; buyers get every file of every
/// track of the release as it stands when they download, so edits reach past buyers. Full audio files
/// are private vault keys and never leave the shop through a public read.
module Music {
    public type TrackId = Nat32;
    public type ReleaseId = Nat32;

    public type AudioFormat = {
        #mp3_320;
        #flac;
        #wav;
        #aiff;
        #alac;
        #aac_256;
    };

    /// One encoding of a track: a private vault key (`/private/…`) and its size in bytes.
    public type AudioFile = {
        format : AudioFormat;
        mediaKey : Text;
        bytes : Nat;
    };

    /// Archived tracks and releases stay in the library, and keep being delivered to past buyers, but
    /// aren't listed publicly.
    public type MusicStatus = { #Active; #Archived };

    public type Credit = (role : Text, name : Text);

    public type Track = {
        id : TrackId;
        title : Text;
        /// Main artist first, then featured artists.
        artists : [Text];
        durationMs : Nat32;
        isrc : ?Text;
        explicit : Bool;
        /// At most one file per format, always including `#mp3_320`.
        files : [AudioFile];
        /// A public vault key (`/public/…`) for a short clip anyone may play.
        previewKey : ?Text;
        credits : [Credit];
        lyrics : ?Text;
        status : MusicStatus;
    };

    public type ReleaseKind = { #Single; #EP; #Album };

    public type Release = {
        id : ReleaseId;
        kind : ReleaseKind;
        title : Text;
        artist : Text;
        /// A public vault key (`/public/…`).
        artworkKey : Text;
        releaseDate : ?Time.Time;
        upc : ?Text;
        /// Free text, such as "Electronic"; null when the artist gave none (BRE-187).
        genre : ?Text;
        /// In listing order.
        tracks : [TrackId];
        status : MusicStatus;
    };

    /// What a variant delivers besides (or instead of) its physical goods. Null on a variant means
    /// today's one-media-key delivery (`setDigitalAssetKey`).
    public type Deliverable = { #release : ReleaseId };

    /// `#minimum`: the variant's price is the least a buyer may pay (name-your-price, BRE-184).
    public type Pricing = { #fixed; #minimum };

    /// The library's stable state.
    public type Library = {
        tracks : Map.Map<TrackId, Track>;
        releases : Map.Map<ReleaseId, Release>;
        /// Releases a paid order line has delivered, or could: they can't lose a track or be deleted.
        soldReleases : Set.Set<ReleaseId>;
        var nextTrackId : TrackId;
        var nextReleaseId : ReleaseId;
    };

    public func emptyLibrary() : Library {
        {
            tracks = Map.empty();
            releases = Map.empty();
            soldReleases = Set.empty();
            var nextTrackId = 1;
            var nextReleaseId = 1;
        };
    };

    public type TrackInput = {
        title : Text;
        artists : [Text];
        durationMs : Nat32;
        isrc : ?Text;
        explicit : Bool;
        files : [AudioFile];
        previewKey : ?Text;
        credits : [Credit];
        lyrics : ?Text;
    };

    public type ReleaseInput = {
        kind : ReleaseKind;
        title : Text;
        artist : Text;
        artworkKey : Text;
        releaseDate : ?Time.Time;
        upc : ?Text;
        /// Optional so callers from before BRE-187 still decode; blank counts as none.
        genre : ?Text;
        tracks : [TrackId];
    };

    /// What the marketplace knows of the release a variant sells, synced with the product (BRE-187).
    public type MarketplaceRelease = {
        kind : ReleaseKind;
        artist : Text;
        genre : ?Text;
    };

    /// A file as anyone may see it: its format and size, without the private key.
    public type PublicAudioFile = { format : AudioFormat; bytes : Nat };

    public type PublicTrack = {
        id : TrackId;
        title : Text;
        artists : [Text];
        durationMs : Nat32;
        isrc : ?Text;
        explicit : Bool;
        files : [PublicAudioFile];
        previewKey : ?Text;
        credits : [Credit];
        /// Lyrics are read one track at a time (`getTrackLyrics`), so a release stays well under the
        /// reply size limit.
        hasLyrics : Bool;
    };

    /// A release in the public list: its tracks are read with `getPublicRelease`.
    public type PublicReleaseSummary = {
        id : ReleaseId;
        kind : ReleaseKind;
        title : Text;
        artist : Text;
        artworkKey : Text;
        releaseDate : ?Time.Time;
        upc : ?Text;
        genre : ?Text;
        trackCount : Nat;
        durationMs : Nat;
    };

    public type PublicRelease = {
        id : ReleaseId;
        kind : ReleaseKind;
        title : Text;
        artist : Text;
        artworkKey : Text;
        releaseDate : ?Time.Time;
        upc : ?Text;
        genre : ?Text;
        status : MusicStatus;
        /// In listing order.
        tracks : [PublicTrack];
        durationMs : Nat;
    };

    public type MusicError = {
        #Unauthorized : Text;
        #NotFound : Text;
        #InvalidInput : Text;
        #LimitReached : Text;
        /// The release has sold: it can't lose a track or be deleted (archive it instead).
        #ReleaseSold : Text;
        /// Still in use (a track in a release, a release a variant sells): remove that first.
        #InUse : Text;
    };

    public module Limits {
        public let MAX_TRACKS = 5_000;
        public let MAX_RELEASES = 1_000;
        public let MAX_FILES_PER_TRACK = 6;
        public let MAX_TRACKS_PER_RELEASE = 100;
        /// Each shop's vault pays for what it stores: 1 GB per file and 5 GB per release, counted from
        /// the sizes the uploader reports.
        public let MAX_FILE_BYTES = 1_000_000_000;
        public let MAX_RELEASE_BYTES = 5_000_000_000;
        public let MAX_TITLE_CHARS = 200;
        public let MAX_ARTISTS = 10;
        public let MAX_CREDITS = 50;
        /// Replies are capped at 2 MB, so a track's text (title, artists, ISRC, credits, keys) is
        /// bounded in UTF-8 bytes: a 100-track release fits in `getPublicRelease`, and a page of
        /// `MAX_TRACKS_PAGE` tracks with their lyrics fits in `listTracks`.
        public let MAX_TRACK_TEXT_BYTES = 8_192;
        public let MAX_LYRICS_BYTES = 20_000;
        public let MAX_TRACKS_PAGE = 20;
        public let MAX_KEY_CHARS = 512;
        public let MAX_DURATION_MS : Nat32 = 86_400_000;
    };

    // ---- Access ----

    /// Writes need `Music.Edit` and a signed-in caller.
    public func canEdit(authService : AuthService.AuthService, caller : Principal) : Bool {
        not caller.isAnonymous() and AuthService.hasPermission(authService, caller, ShopPermissions.musicEdit);
    };

    func requireEdit(authService : AuthService.AuthService, caller : Principal) : Result<(), MusicError> {
        if (canEdit(authService, caller)) #ok else #err(#Unauthorized("Editing music needs the Music.Edit permission"));
    };

    // ---- Tracks ----

    public func createTrack(library : Library, authService : AuthService.AuthService, caller : Principal, input : TrackInput) : Result<Track, MusicError> {
        switch (requireEdit(authService, caller)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        if (library.tracks.size() >= Limits.MAX_TRACKS) {
            return #err(#LimitReached("A shop can hold at most " # Nat.toText(Limits.MAX_TRACKS) # " tracks"));
        };
        switch (validateTrack(input)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        let id = library.nextTrackId;
        library.nextTrackId += 1;
        let track = trackFrom(id, input, #Active);
        library.tracks.add(id, track);
        #ok(track);
    };

    /// Replaces track `id`'s details and files. Allowed on a sold release: buyers get the new files.
    public func updateTrack(library : Library, authService : AuthService.AuthService, caller : Principal, id : TrackId, input : TrackInput) : Result<Track, MusicError> {
        switch (requireEdit(authService, caller)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        let ?existing = library.tracks.get(id) else return #err(trackNotFound(id));
        switch (validateTrack(input)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        let track = trackFrom(id, input, existing.status);
        // Larger files could push a release over its byte cap.
        for (release in releasesWithTrack(library, id)) {
            if (releaseBytes(library, release.tracks, ?track) > Limits.MAX_RELEASE_BYTES) {
                return #err(#LimitReached("Release " # Nat32.toText(release.id) # " would be over " # Nat.toText(Limits.MAX_RELEASE_BYTES) # " bytes"));
            };
        };
        library.tracks.add(id, track);
        #ok(track);
    };

    public func setTrackStatus(library : Library, authService : AuthService.AuthService, caller : Principal, id : TrackId, status : MusicStatus) : Result<Track, MusicError> {
        switch (requireEdit(authService, caller)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        let ?existing = library.tracks.get(id) else return #err(trackNotFound(id));
        let track = { existing with status };
        library.tracks.add(id, track);
        #ok(track);
    };

    /// Deletes a track no release lists.
    public func deleteTrack(library : Library, authService : AuthService.AuthService, caller : Principal, id : TrackId) : Result<(), MusicError> {
        switch (requireEdit(authService, caller)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        if (library.tracks.get(id) == null) return #err(trackNotFound(id));
        switch (releasesWithTrack(library, id).next()) {
            case (?release) return #err(#InUse("Release " # Nat32.toText(release.id) # " lists track " # Nat32.toText(id) # "; remove it from the release first"));
            case null {};
        };
        library.tracks.remove(id);
        #ok;
    };

    // ---- Releases ----

    public func createRelease(library : Library, authService : AuthService.AuthService, caller : Principal, input : ReleaseInput) : Result<Release, MusicError> {
        switch (requireEdit(authService, caller)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        if (library.releases.size() >= Limits.MAX_RELEASES) {
            return #err(#LimitReached("A shop can hold at most " # Nat.toText(Limits.MAX_RELEASES) # " releases"));
        };
        switch (validateRelease(library, input)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        let id = library.nextReleaseId;
        library.nextReleaseId += 1;
        let release = releaseFrom(id, input, #Active);
        library.releases.add(id, release);
        #ok(release);
    };

    /// Replaces release `id`'s details and track list. Once it has sold, the new list must still hold
    /// every track (they may be reordered, and tracks added).
    /// `isLinked` says whether a variant sells the release: then it must keep at least one track, as
    /// checkout doesn't check again.
    public func updateRelease(library : Library, authService : AuthService.AuthService, caller : Principal, id : ReleaseId, input : ReleaseInput, isLinked : ReleaseId -> Bool) : Result<Release, MusicError> {
        switch (requireEdit(authService, caller)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        let ?existing = library.releases.get(id) else return #err(releaseNotFound(id));
        switch (validateRelease(library, input)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        if (input.tracks.size() == 0 and isLinked(id)) {
            return #err(#InUse("A product variant sells release " # Nat32.toText(id) # ", so it must keep at least one track"));
        };
        if (isSold(library, id)) {
            for (trackId in existing.tracks.values()) {
                if (not input.tracks.any(func(t : TrackId) : Bool = t == trackId)) {
                    return #err(#ReleaseSold("Release " # Nat32.toText(id) # " has sold, so track " # Nat32.toText(trackId) # " can't be removed"));
                };
            };
        };
        let release = releaseFrom(id, input, existing.status);
        library.releases.add(id, release);
        #ok(release);
    };

    public func setReleaseStatus(library : Library, authService : AuthService.AuthService, caller : Principal, id : ReleaseId, status : MusicStatus) : Result<Release, MusicError> {
        switch (requireEdit(authService, caller)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        let ?existing = library.releases.get(id) else return #err(releaseNotFound(id));
        let release = { existing with status };
        library.releases.add(id, release);
        #ok(release);
    };

    /// Deletes a release that never sold and no variant sells. `isSoldBy` says whether a variant links
    /// to it.
    public func deleteRelease(library : Library, authService : AuthService.AuthService, caller : Principal, id : ReleaseId, isLinked : ReleaseId -> Bool) : Result<(), MusicError> {
        switch (requireEdit(authService, caller)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        if (library.releases.get(id) == null) return #err(releaseNotFound(id));
        if (isSold(library, id)) {
            return #err(#ReleaseSold("Release " # Nat32.toText(id) # " has sold; archive it instead"));
        };
        if (isLinked(id)) {
            return #err(#InUse("A product variant sells release " # Nat32.toText(id) # "; unlink it first"));
        };
        library.releases.remove(id);
        #ok;
    };

    public func isSold(library : Library, id : ReleaseId) : Bool {
        library.soldReleases.contains(id);
    };

    /// Records that release `id` has been sold (a paid order line delivers it).
    public func markSold(library : Library, id : ReleaseId) {
        library.soldReleases.add(id);
    };

    /// Checks that a variant may point at `deliverable`: the release exists, is active and has a track.
    public func checkDeliverable(library : Library, deliverable : ?Deliverable) : Result<(), MusicError> {
        switch (deliverable) {
            case null #ok;
            case (?#release(id)) {
                switch (library.releases.get(id)) {
                    case null #err(releaseNotFound(id));
                    case (?r) {
                        if (r.status == #Archived) return #err(#InvalidInput("Release " # Nat32.toText(id) # " is archived"));
                        if (r.tracks.size() == 0) return #err(#InvalidInput("Release " # Nat32.toText(id) # " has no tracks yet"));
                        #ok;
                    };
                };
            };
        };
    };

    // ---- Reads ----

    /// A page of active releases with at least one track, without their tracks. No access check
    /// needed.
    public func listPublicReleases(library : Library, after : ?ReleaseId, limit : ?Nat) : Pagination.Page<PublicReleaseSummary, ReleaseId> {
        Pagination.scan(
            library.releases.entriesFrom(firstAfter(after)),
            func((id, _) : (ReleaseId, Release)) : ReleaseId = id,
            Nat32.compare,
            after,
            func((_, r) : (ReleaseId, Release)) : ?PublicReleaseSummary = if (isListed(r)) ?releaseSummary(library, r) else null,
            limit,
        );
    };

    /// A release starts empty while the artist uploads its tracks (BRE-183): it's listed, and can be
    /// sold, once it has one.
    func isListed(r : Release) : Bool = r.status == #Active and r.tracks.size() > 0;

    /// Release `id` without private keys, archived or not (past buyers still see what they bought).
    public func getPublicRelease(library : Library, id : ReleaseId) : ?PublicRelease {
        switch (library.releases.get(id)) {
            case (?r) ?publicRelease(library, r);
            case null null;
        };
    };

    /// The lyrics of track `id` if a release lists it, else null. No access check needed: listed
    /// tracks are public.
    public func getTrackLyrics(library : Library, id : TrackId) : ?Text {
        let ?track = library.tracks.get(id) else return null;
        switch (releasesWithTrack(library, id).next()) {
            case (?_) track.lyrics;
            case null null;
        };
    };

    public func listTracks(library : Library, authService : AuthService.AuthService, caller : Principal, after : ?TrackId, limit : ?Nat) : Result<Pagination.Page<Track, TrackId>, MusicError> {
        switch (requireEdit(authService, caller)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        #ok(
            Pagination.scan(
                library.tracks.entriesFrom(firstAfter(after)),
                func((id, _) : (TrackId, Track)) : TrackId = id,
                Nat32.compare,
                after,
                func((_, t) : (TrackId, Track)) : ?Track = ?t,
                ?Nat.min(switch (limit) { case (?l) l; case null Limits.MAX_TRACKS_PAGE }, Limits.MAX_TRACKS_PAGE),
            )
        );
    };

    public func listReleases(library : Library, authService : AuthService.AuthService, caller : Principal, after : ?ReleaseId, limit : ?Nat) : Result<Pagination.Page<Release, ReleaseId>, MusicError> {
        switch (requireEdit(authService, caller)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        #ok(
            Pagination.scan(
                library.releases.entriesFrom(firstAfter(after)),
                func((id, _) : (ReleaseId, Release)) : ReleaseId = id,
                Nat32.compare,
                after,
                func((_, r) : (ReleaseId, Release)) : ?Release = ?r,
                limit,
            )
        );
    };

    public func publicTrack(t : Track) : PublicTrack {
        {
            id = t.id;
            title = t.title;
            artists = t.artists;
            durationMs = t.durationMs;
            isrc = t.isrc;
            explicit = t.explicit;
            files = t.files.map(func(f : AudioFile) : PublicAudioFile = { format = f.format; bytes = f.bytes });
            previewKey = t.previewKey;
            credits = t.credits;
            hasLyrics = t.lyrics != null;
        };
    };

    func releaseSummary(library : Library, r : Release) : PublicReleaseSummary {
        var durationMs = 0;
        for (id in r.tracks.values()) {
            switch (library.tracks.get(id)) {
                case (?t) durationMs += t.durationMs.toNat();
                case null {};
            };
        };
        {
            id = r.id;
            kind = r.kind;
            title = r.title;
            artist = r.artist;
            artworkKey = r.artworkKey;
            releaseDate = r.releaseDate;
            upc = r.upc;
            genre = r.genre;
            trackCount = r.tracks.size();
            durationMs;
        };
    };

    func publicRelease(library : Library, r : Release) : PublicRelease {
        let tracks = r.tracks.filterMap(func(id : TrackId) : ?PublicTrack = switch (library.tracks.get(id)) { case (?t) ?publicTrack(t); case null null });
        var durationMs = 0;
        for (t in tracks.values()) durationMs += t.durationMs.toNat();
        {
            id = r.id;
            kind = r.kind;
            title = r.title;
            artist = r.artist;
            artworkKey = r.artworkKey;
            releaseDate = r.releaseDate;
            upc = r.upc;
            genre = r.genre;
            status = r.status;
            tracks;
            durationMs;
        };
    };

    // ---- Validation ----

    public func validateTrack(input : TrackInput) : Result<(), MusicError> {
        switch (checkField("Track title", input.title)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        if (input.artists.size() == 0) return invalid("A track needs at least one artist");
        if (input.artists.size() > Limits.MAX_ARTISTS) return invalid("A track can list at most " # Nat.toText(Limits.MAX_ARTISTS) # " artists");
        for (a in input.artists.values()) {
            switch (checkField("Artist", a)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
        };
        if (input.durationMs == 0 or input.durationMs > Limits.MAX_DURATION_MS) return invalid("Track duration must be between 1 ms and 24 hours");
        switch (input.isrc) {
            case (?isrc) if (not isIsrc(isrc)) return invalid("An ISRC is 12 letters and digits, like USRC17607839");
            case null {};
        };
        if (input.files.size() > Limits.MAX_FILES_PER_TRACK) {
            return #err(#LimitReached("A track can have at most " # Nat.toText(Limits.MAX_FILES_PER_TRACK) # " files"));
        };
        if (not input.files.any(func(f : AudioFile) : Bool = f.format == #mp3_320)) {
            return invalid("Every track needs an MP3 file");
        };
        for (i in input.files.keys()) {
            let f = input.files[i];
            for (j in Nat.range(0, i)) {
                if (input.files[j].format == f.format) return invalid("Each format can be listed once per track");
            };
            if (not isPrivateKey(f.mediaKey)) return invalid("Audio files must be private files in the shop's vault (/private/…)");
            if (f.bytes == 0) return invalid("An audio file can't be empty");
            if (f.bytes > Limits.MAX_FILE_BYTES) return #err(#LimitReached("An audio file can be at most " # Nat.toText(Limits.MAX_FILE_BYTES) # " bytes"));
        };
        switch (input.previewKey) {
            case (?key) if (not isPublicKey(key)) return invalid("A preview must be a public file in the shop's vault (/public/…)");
            case null {};
        };
        if (input.credits.size() > Limits.MAX_CREDITS) return #err(#LimitReached("A track can list at most " # Nat.toText(Limits.MAX_CREDITS) # " credits"));
        for ((role, name) in input.credits.values()) {
            switch (checkField("Credit role", role)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
            switch (checkField("Credit name", name)) {
                case (#err(e)) return #err(e);
                case (#ok) {};
            };
        };
        switch (input.lyrics) {
            case (?l) if (l.encodeUtf8().size() > Limits.MAX_LYRICS_BYTES) return #err(#LimitReached("Lyrics can be at most " # Nat.toText(Limits.MAX_LYRICS_BYTES) # " bytes"));
            case null {};
        };
        if (trackTextBytes(input) > Limits.MAX_TRACK_TEXT_BYTES) {
            return #err(#LimitReached("A track's title, artists, credits and file names can add up to at most " # Nat.toText(Limits.MAX_TRACK_TEXT_BYTES) # " bytes"));
        };
        #ok;
    };

    public func validateRelease(library : Library, input : ReleaseInput) : Result<(), MusicError> {
        switch (checkField("Release title", input.title)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        switch (checkField("Artist", input.artist)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        if (not isPublicKey(input.artworkKey)) return invalid("Artwork must be a public file in the shop's vault (/public/…)");
        switch (input.upc) {
            case (?upc) if (not isUpc(upc)) return invalid("A UPC is 12 or 13 digits");
            case null {};
        };
        switch (input.genre) {
            case (?genre) if (genre.size() > Limits.MAX_TITLE_CHARS) return invalid("Genre can be at most " # Nat.toText(Limits.MAX_TITLE_CHARS) # " characters");
            case null {};
        };
        if (input.tracks.size() > Limits.MAX_TRACKS_PER_RELEASE) {
            return #err(#LimitReached("A release can have at most " # Nat.toText(Limits.MAX_TRACKS_PER_RELEASE) # " tracks"));
        };
        for (i in input.tracks.keys()) {
            let id = input.tracks[i];
            if (library.tracks.get(id) == null) return #err(trackNotFound(id));
            for (j in Nat.range(0, i)) {
                if (input.tracks[j] == id) return invalid("Track " # Nat32.toText(id) # " is listed twice");
            };
        };
        if (releaseBytes(library, input.tracks, null) > Limits.MAX_RELEASE_BYTES) {
            return #err(#LimitReached("A release's files can add up to at most " # Nat.toText(Limits.MAX_RELEASE_BYTES) # " bytes"));
        };
        #ok;
    };

    /// The UTF-8 bytes of a track's text other than its lyrics.
    func trackTextBytes(input : TrackInput) : Nat {
        var total = input.title.encodeUtf8().size();
        for (a in input.artists.values()) total += a.encodeUtf8().size();
        for ((role, name) in input.credits.values()) total += role.encodeUtf8().size() + name.encodeUtf8().size();
        for (f in input.files.values()) total += f.mediaKey.encodeUtf8().size();
        switch (input.isrc) { case (?t) total += t.size(); case null {} };
        switch (input.previewKey) {
            case (?k) total += k.encodeUtf8().size();
            case null {};
        };
        total;
    };

    /// True for a key the vault serves only with a delivery ticket.
    public func isPrivateKey(key : Text) : Bool {
        key.startsWith(#text "/private/") and safeKey(key);
    };

    /// True for a key the vault serves to anyone.
    public func isPublicKey(key : Text) : Bool {
        key.startsWith(#text "/public/") and safeKey(key);
    };

    func safeKey(key : Text) : Bool {
        key.size() <= Limits.MAX_KEY_CHARS and not key.contains(#text "..") and not key.contains(#char '?') and not key.contains(#char '#') and not key.contains(#char '\\');
    };

    func isIsrc(t : Text) : Bool {
        t.size() == 12 and t.chars().all(func(c : Char) : Bool = (c >= 'A' and c <= 'Z') or c.isDigit());
    };

    func isUpc(t : Text) : Bool {
        (t.size() == 12 or t.size() == 13) and t.chars().all(func(c : Char) : Bool = c.isDigit());
    };

    func checkField(what : Text, t : Text) : Result<(), MusicError> {
        if (t.trim(#char ' ').size() == 0) return invalid(what # " can't be empty");
        if (t.size() > Limits.MAX_TITLE_CHARS) return invalid(what # " can be at most " # Nat.toText(Limits.MAX_TITLE_CHARS) # " characters");
        #ok;
    };

    func invalid(msg : Text) : Result<(), MusicError> = #err(#InvalidInput(msg));

    // ---- Helpers ----

    /// The bytes of every file of `trackIds`, with `replacing` standing in for the stored track of its id.
    func releaseBytes(library : Library, trackIds : [TrackId], replacing : ?Track) : Nat {
        var total = 0;
        for (id in trackIds.values()) {
            let track = switch (replacing) {
                case (?t) if (t.id == id) ?t else library.tracks.get(id);
                case null library.tracks.get(id);
            };
            switch (track) {
                case (?t) for (f in t.files.values()) total += f.bytes;
                case null {};
            };
        };
        total;
    };

    func releasesWithTrack(library : Library, trackId : TrackId) : Iter.Iter<Release> {
        library.releases.values().filter(func(r : Release) : Bool = r.tracks.any(func(t : TrackId) : Bool = t == trackId));
    };

    func trackFrom(id : TrackId, input : TrackInput, status : MusicStatus) : Track {
        { input with id; status };
    };

    func releaseFrom(id : ReleaseId, input : ReleaseInput, status : MusicStatus) : Release {
        { input with id; status; genre = trimmedOrNull(input.genre) };
    };

    func trimmedOrNull(t : ?Text) : ?Text {
        switch (t) {
            case (?t) {
                let trimmed = t.trim(#predicate(Char.isWhitespace));
                if (trimmed.size() == 0) null else ?trimmed;
            };
            case null null;
        };
    };

    /// The marketplace's view of the release `deliverable` sells, or null when it sells none or the
    /// release is gone.
    public func marketplaceRelease(library : Library, deliverable : ?Deliverable) : ?MarketplaceRelease {
        let ?#release(id) = deliverable else return null;
        let ?r = library.releases.get(id) else return null;
        ?{ kind = r.kind; artist = r.artist; genre = r.genre };
    };

    /// The IDs of the products whose variants sell release `id`.
    public func productsSelling(variants : Iter.Iter<{ productId : Nat32; deliverable : ?Deliverable }>, id : ReleaseId) : [Nat32] {
        let ids = Set.empty<Nat32>();
        for (v in variants) {
            if (v.deliverable == ?#release(id)) ids.add(Nat32.compare, v.productId);
        };
        Set.values(ids).toArray();
    };

    /// Where `entriesFrom` should start for a page after `after`.
    func firstAfter(after : ?Nat32) : Nat32 {
        switch (after) {
            case (?a) a;
            case null 0;
        };
    };

    func trackNotFound(id : TrackId) : MusicError = #NotFound("Track " # Nat32.toText(id) # " not found");
    func releaseNotFound(id : ReleaseId) : MusicError = #NotFound("Release " # Nat32.toText(id) # " not found");
};
