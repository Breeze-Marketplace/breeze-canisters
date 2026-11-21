import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";
import Principal "mo:core/Principal";

import AuthService "../auth";
import Music "../music";
import ShopPermissions "../permissions";
import Fixtures "fixtures";

let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let musician = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let stranger = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");

func setup() : { library : Music.Library; auth : AuthService.AuthService } {
    let auth = Fixtures.newAuthService(owner);
    Fixtures.grantRole(auth, musician, "Musician", [ShopPermissions.musicEdit]);
    { library = Music.emptyLibrary(); auth };
};

func mp3(key : Text) : Music.AudioFile = {
    format = #mp3_320;
    mediaKey = key;
    bytes = 8_000_000;
};

func trackInput(title : Text) : Music.TrackInput {
    {
        title;
        artists = ["Canary"];
        durationMs = 180_000;
        isrc = ?"USRC17607839";
        explicit = false;
        files = [mp3("/private/music/1/1/mp3_320"), { format = #flac; mediaKey = "/private/music/1/1/flac"; bytes = 30_000_000 }];
        previewKey = ?"/public/music/1/1/preview";
        credits = [("Producer", "Gus")];
        lyrics = null;
    };
};

func releaseInput(tracks : [Music.TrackId]) : Music.ReleaseInput {
    {
        kind = #EP;
        title = "First Song";
        artist = "Canary";
        artworkKey = "/public/music/1/artwork";
        releaseDate = null;
        upc = ?"123456789012";
        genre = null;
        tracks;
    };
};

func newTrack(s : { library : Music.Library; auth : AuthService.AuthService }, title : Text) : Music.TrackId {
    switch (Music.createTrack(s.library, s.auth, musician, trackInput(title))) {
        case (#ok(t)) t.id;
        case (#err(_)) { assert false; 0 };
    };
};

func newRelease(s : { library : Music.Library; auth : AuthService.AuthService }, tracks : [Music.TrackId]) : Music.ReleaseId {
    switch (Music.createRelease(s.library, s.auth, musician, releaseInput(tracks))) {
        case (#ok(r)) r.id;
        case (#err(_)) { assert false; 0 };
    };
};

func isErr<T>(r : { #ok : T; #err : Music.MusicError }, tag : Text) : Bool {
    switch (r) {
        case (#ok(_)) false;
        case (#err(e)) (debug_show e).startsWith(#text("#" # tag));
    };
};

suite(
    "Music library access",
    func() {
        test(
            "writes need Music.Edit and a signed-in caller",
            func() {
                let s = setup();
                expect.bool(isErr(Music.createTrack(s.library, s.auth, stranger, trackInput("A")), "Unauthorized")).isTrue();
                expect.bool(isErr(Music.createTrack(s.library, s.auth, Principal.anonymous(), trackInput("A")), "Unauthorized")).isTrue();
                expect.bool(isErr(Music.listTracks(s.library, s.auth, stranger, null, null), "Unauthorized")).isTrue();
                expect.bool(isErr(Music.listReleases(s.library, s.auth, stranger, null, null), "Unauthorized")).isTrue();
                ignore newTrack(s, "A");
                // The Owner holds every permission.
                expect.bool(isErr(Music.createTrack(s.library, s.auth, owner, trackInput("B")), "Unauthorized")).isFalse();
            },
        );
        test(
            "public reads leave out private file keys",
            func() {
                let s = setup();
                let r = newRelease(s, [newTrack(s, "A")]);
                switch (Music.getPublicRelease(s.library, r)) {
                    case (?release) {
                        expect.nat(release.tracks.size()).equal(1);
                        expect.nat(release.tracks[0].files.size()).equal(2);
                        expect.nat(release.durationMs).equal(180_000);
                        expect.bool((debug_show release).contains(#text "/private/")).isFalse();
                    };
                    case null assert false;
                };
                let page = Music.listPublicReleases(s.library, null, null);
                expect.nat(page.items.size()).equal(1);
                expect.bool((debug_show page).contains(#text "/private/")).isFalse();
                expect.nat(page.items[0].trackCount).equal(1);
            },
        );
    },
);

suite(
    "Track rules",
    func() {
        test(
            "every track needs an MP3 file",
            func() {
                let s = setup();
                let input = {
                    trackInput("A") with files = [{
                        format = #flac;
                        mediaKey = "/private/a.flac";
                        bytes = 1;
                    }]
                };
                expect.bool(isErr(Music.createTrack(s.library, s.auth, musician, input), "InvalidInput")).isTrue();
            },
        );
        test(
            "files are private keys, one per format, within the caps",
            func() {
                let s = setup();
                let publicFile = {
                    trackInput("A") with files = [mp3("/public/a.mp3")]
                };
                expect.bool(isErr(Music.createTrack(s.library, s.auth, musician, publicFile), "InvalidInput")).isTrue();
                let escaping = {
                    trackInput("A") with files = [mp3("/private/../public/a.mp3")]
                };
                expect.bool(isErr(Music.createTrack(s.library, s.auth, musician, escaping), "InvalidInput")).isTrue();
                let twice = {
                    trackInput("A") with files = [mp3("/private/a.mp3"), mp3("/private/b.mp3")]
                };
                expect.bool(isErr(Music.createTrack(s.library, s.auth, musician, twice), "InvalidInput")).isTrue();
                let huge = {
                    trackInput("A") with files = [{
                        mp3("/private/a.mp3") with bytes = Music.Limits.MAX_FILE_BYTES + 1
                    }]
                };
                expect.bool(isErr(Music.createTrack(s.library, s.auth, musician, huge), "LimitReached")).isTrue();
                let many = {
                    trackInput("A") with files = Array.tabulate<Music.AudioFile>(Music.Limits.MAX_FILES_PER_TRACK + 1, func(i) = mp3("/private/" # i.toText()))
                };
                expect.bool(isErr(Music.createTrack(s.library, s.auth, musician, many), "LimitReached")).isTrue();
                let publicPreview = {
                    trackInput("A") with previewKey = ?"/private/a.mp3"
                };
                expect.bool(isErr(Music.createTrack(s.library, s.auth, musician, publicPreview), "InvalidInput")).isTrue();
            },
        );
        test(
            "checks the title, artists, ISRC and duration",
            func() {
                let s = setup();
                for (
                    input in [
                        { trackInput("  ") with title = "  " },
                        { trackInput("A") with artists = [] },
                        { trackInput("A") with isrc = ?"usrc1760783" },
                        { trackInput("A") with durationMs = 0 : Nat32 },
                    ].values()
                ) {
                    expect.bool(isErr(Music.createTrack(s.library, s.auth, musician, input), "InvalidInput")).isTrue();
                };
                expect.nat(s.library.tracks.size()).equal(0);
            },
        );
        test(
            "update keeps the id and status; delete refuses a track a release lists",
            func() {
                let s = setup();
                let t = newTrack(s, "A");
                ignore Music.setTrackStatus(s.library, s.auth, musician, t, #Archived);
                switch (Music.updateTrack(s.library, s.auth, musician, t, trackInput("B"))) {
                    case (#ok(track)) {
                        expect.text(track.title).equal("B");
                        expect.bool(track.status == #Archived and track.id == t).isTrue();
                    };
                    case (#err(_)) assert false;
                };
                let r = newRelease(s, [t]);
                expect.bool(isErr(Music.deleteTrack(s.library, s.auth, musician, t), "InUse")).isTrue();
                expect.bool(isErr(Music.deleteRelease(s.library, s.auth, musician, r, func(_) = false), "")).isFalse();
                expect.bool(isErr(Music.deleteTrack(s.library, s.auth, musician, t), "")).isFalse();
                expect.bool(s.library.tracks.get(t) == null).isTrue();
            },
        );
    },
);

suite(
    "Release rules",
    func() {
        test(
            "lists existing tracks once each, within the caps",
            func() {
                let s = setup();
                let a = newTrack(s, "A");
                expect.bool(isErr(Music.createRelease(s.library, s.auth, musician, releaseInput([a, a])), "InvalidInput")).isTrue();
                expect.bool(isErr(Music.createRelease(s.library, s.auth, musician, releaseInput([a, 99])), "NotFound")).isTrue();
                let tooMany = Array.tabulate<Music.TrackId>(Music.Limits.MAX_TRACKS_PER_RELEASE + 1, func(i) = Nat32.fromNat(i));
                expect.bool(isErr(Music.createRelease(s.library, s.auth, musician, releaseInput(tooMany)), "LimitReached")).isTrue();
                let badArt = {
                    releaseInput([a]) with artworkKey = "/private/art.png"
                };
                expect.bool(isErr(Music.createRelease(s.library, s.auth, musician, badArt), "InvalidInput")).isTrue();
                let badUpc = { releaseInput([a]) with upc = ?"12345" };
                expect.bool(isErr(Music.createRelease(s.library, s.auth, musician, badUpc), "InvalidInput")).isTrue();
            },
        );
        test(
            "caps a release's total bytes, also when a track's files grow",
            func() {
                let s = setup();
                let big = {
                    mp3("/private/big.mp3") with bytes = Music.Limits.MAX_FILE_BYTES
                };
                let ids = Array.tabulate<Music.TrackId>(
                    5,
                    func(i) = switch (Music.createTrack(s.library, s.auth, musician, { trackInput("T" # i.toText()) with files = [big] })) {
                        case (#ok(t)) t.id;
                        case (#err(_)) 0;
                    },
                );
                let r = newRelease(s, ids); // exactly at the cap
                let sixth = newTrack(s, "Six");
                expect.bool(isErr(Music.updateRelease(s.library, s.auth, musician, r, releaseInput(ids.concat([sixth])), func(_) = false), "LimitReached")).isTrue();
                let grown = {
                    trackInput("A") with files = [big, { format = #flac; mediaKey = "/private/a.flac"; bytes = 1 }]
                };
                expect.bool(isErr(Music.updateTrack(s.library, s.auth, musician, ids[0], grown), "LimitReached")).isTrue();
            },
        );
        test(
            "a sold release can gain and reorder tracks but not lose one, and can't be deleted",
            func() {
                let s = setup();
                let a = newTrack(s, "A");
                let b = newTrack(s, "B");
                let c = newTrack(s, "C");
                let r = newRelease(s, [a, b]);
                Music.markSold(s.library, r);
                expect.bool(isErr(Music.updateRelease(s.library, s.auth, musician, r, releaseInput([b, a, c]), func(_) = false), "")).isFalse();
                switch (s.library.releases.get(r)) {
                    case (?release) expect.bool(release.tracks == [b, a, c]).isTrue();
                    case null assert false;
                };
                expect.bool(isErr(Music.updateRelease(s.library, s.auth, musician, r, releaseInput([a, c]), func(_) = false), "ReleaseSold")).isTrue();
                expect.bool(isErr(Music.deleteRelease(s.library, s.auth, musician, r, func(_) = false), "ReleaseSold")).isTrue();
                // Archive instead: it leaves the public list, and stays readable for past buyers.
                ignore Music.setReleaseStatus(s.library, s.auth, musician, r, #Archived);
                expect.nat(Music.listPublicReleases(s.library, null, null).items.size()).equal(0);
                expect.bool(Music.getPublicRelease(s.library, r) != null).isTrue();
            },
        );
        test(
            "an unsold release can lose tracks, and is deleted only once no variant sells it",
            func() {
                let s = setup();
                let a = newTrack(s, "A");
                let b = newTrack(s, "B");
                let r = newRelease(s, [a, b]);
                expect.bool(isErr(Music.updateRelease(s.library, s.auth, musician, r, releaseInput([b]), func(_) = false), "")).isFalse();
                expect.bool(isErr(Music.deleteRelease(s.library, s.auth, musician, r, func(id) = id == r), "InUse")).isTrue();
                expect.bool(isErr(Music.deleteRelease(s.library, s.auth, musician, r, func(_) = false), "")).isFalse();
                expect.bool(s.library.releases.get(r) == null).isTrue();
            },
        );
        test(
            "a release a variant sells keeps at least one track",
            func() {
                let s = setup();
                let a = newTrack(s, "A");
                let r = newRelease(s, [a]);
                expect.bool(isErr(Music.updateRelease(s.library, s.auth, musician, r, releaseInput([]), func(id) = id == r), "InUse")).isTrue();
                expect.bool(isErr(Music.updateRelease(s.library, s.auth, musician, r, releaseInput([]), func(_) = false), "")).isFalse();
            },
        );
        test(
            "a release starts empty, unlisted and unsellable until it has a track",
            func() {
                let s = setup();
                let r = newRelease(s, []);
                expect.nat(Music.listPublicReleases(s.library, null, null).items.size()).equal(0);
                expect.bool(isErr(Music.checkDeliverable(s.library, ?#release(r)), "InvalidInput")).isTrue();
                let a = newTrack(s, "A");
                expect.bool(isErr(Music.updateRelease(s.library, s.auth, musician, r, releaseInput([a]), func(_) = false), "")).isFalse();
                expect.nat(Music.listPublicReleases(s.library, null, null).items.size()).equal(1);
                expect.bool(Music.checkDeliverable(s.library, ?#release(r)) == #ok).isTrue();
            },
        );
        test(
            "a variant may link only to an active release",
            func() {
                let s = setup();
                let r = newRelease(s, [newTrack(s, "A")]);
                expect.bool(Music.checkDeliverable(s.library, ?#release(r)) == #ok).isTrue();
                expect.bool(Music.checkDeliverable(s.library, null) == #ok).isTrue();
                expect.bool(isErr(Music.checkDeliverable(s.library, ?#release(r + 1)), "NotFound")).isTrue();
                ignore Music.setReleaseStatus(s.library, s.auth, musician, r, #Archived);
                expect.bool(isErr(Music.checkDeliverable(s.library, ?#release(r)), "InvalidInput")).isTrue();
            },
        );
    },
);

suite(
    "Paging",
    func() {
        test(
            "pages releases and tracks in id order, public pages skipping archived releases",
            func() {
                let s = setup();
                let t = newTrack(s, "A");
                let ids = Array.tabulate<Music.ReleaseId>(5, func(_) = newRelease(s, [t]));
                ignore Music.setReleaseStatus(s.library, s.auth, musician, ids[1], #Archived);
                let first = Music.listPublicReleases(s.library, null, ?2);
                expect.bool(first.items.map(func(r : Music.PublicReleaseSummary) : Nat32 = r.id) == [ids[0], ids[2]]).isTrue();
                let rest = Music.listPublicReleases(s.library, first.next, ?2);
                expect.bool(rest.items.map(func(r : Music.PublicReleaseSummary) : Nat32 = r.id) == [ids[3], ids[4]]).isTrue();
                switch (Music.listReleases(s.library, s.auth, musician, null, ?10)) {
                    case (#ok(page)) expect.nat(page.items.size()).equal(5);
                    case (#err(_)) assert false;
                };
                switch (Music.listTracks(s.library, s.auth, musician, ?t, null)) {
                    case (#ok(page)) expect.nat(page.items.size()).equal(0);
                    case (#err(_)) assert false;
                };
            },
        );
    },
);

suite(
    "Reply sizes",
    func() {
        test(
            "caps a track's text and lyrics in bytes",
            func() {
                let s = setup();
                let wide = Text.fromIter(Array.repeat<Char>('\u{1F3B5}', 190).values()); // 4 bytes each
                let credits = Array.tabulate<Music.Credit>(20, func(_) = (wide, wide));
                expect.bool(isErr(Music.createTrack(s.library, s.auth, musician, { trackInput("A") with credits }), "LimitReached")).isTrue();
                let lyrics = ?Text.fromIter(Array.repeat<Char>('\u{1F3B5}', 5_001).values());
                expect.bool(isErr(Music.createTrack(s.library, s.auth, musician, { trackInput("A") with lyrics }), "LimitReached")).isTrue();
            },
        );
        test(
            "pages at most MAX_TRACKS_PAGE tracks; lyrics only for listed tracks",
            func() {
                let s = setup();
                let ids = Array.tabulate<Music.TrackId>(Music.Limits.MAX_TRACKS_PAGE + 5, func(i) = newTrack(s, "T" # i.toText()));
                switch (Music.listTracks(s.library, s.auth, musician, null, ?200)) {
                    case (#ok(page)) {
                        expect.nat(page.items.size()).equal(Music.Limits.MAX_TRACKS_PAGE);
                        expect.bool(page.next != null).isTrue();
                    };
                    case (#err(_)) assert false;
                };
                ignore Music.updateTrack(s.library, s.auth, musician, ids[0], { trackInput("A") with lyrics = ?"la la" });
                expect.bool(Music.getTrackLyrics(s.library, ids[0]) == null).isTrue();
                ignore newRelease(s, [ids[0]]);
                expect.bool(Music.getTrackLyrics(s.library, ids[0]) == ?"la la").isTrue();
                switch (Music.getPublicRelease(s.library, 1)) {
                    case (?r) expect.bool(r.tracks[0].hasLyrics).isTrue();
                    case null assert false;
                };
            },
        );
    },
);

suite(
    "Marketplace release (BRE-187)",
    func() {
        test(
            "a release keeps a trimmed genre, and a blank one as none",
            func() {
                let s = setup();
                let t = newTrack(s, "A");
                switch (Music.createRelease(s.library, s.auth, musician, { releaseInput([t]) with genre = ?"  Electronic " })) {
                    case (#ok(r)) expect.bool(r.genre == ?"Electronic").isTrue();
                    case (#err(_)) assert false;
                };
                switch (Music.updateRelease(s.library, s.auth, musician, 1, { releaseInput([t]) with genre = ?"   " }, func _ = false)) {
                    case (#ok(r)) expect.bool(r.genre == null).isTrue();
                    case (#err(_)) assert false;
                };
                let long = Text.join(Array.tabulate<Text>(Music.Limits.MAX_TITLE_CHARS + 1, func _ = "a").values(), "");
                expect.bool(isErr(Music.createRelease(s.library, s.auth, musician, { releaseInput([t]) with genre = ?long }), "InvalidInput")).isTrue();
            },
        );
        test(
            "the marketplace sees the kind, artist and genre of the release a variant sells",
            func() {
                let s = setup();
                ignore Music.createRelease(s.library, s.auth, musician, { releaseInput([newTrack(s, "A")]) with genre = ?"Folk" });
                switch (Music.marketplaceRelease(s.library, ?#release(1))) {
                    case (?r) {
                        expect.bool(r.kind == #EP).isTrue();
                        expect.text(r.artist).equal("Canary");
                        expect.bool(r.genre == ?"Folk").isTrue();
                    };
                    case null assert false;
                };
                expect.bool(Music.marketplaceRelease(s.library, null) == null).isTrue();
                expect.bool(Music.marketplaceRelease(s.library, ?#release(99)) == null).isTrue();
            },
        );
        test(
            "productsSelling lists each product with a variant selling the release once",
            func() {
                let variants = [
                    {
                        productId = 1 : Nat32;
                        deliverable = ?#release(5 : Nat32);
                    },
                    {
                        productId = 1 : Nat32;
                        deliverable = ?#release(5 : Nat32);
                    },
                    {
                        productId = 2 : Nat32;
                        deliverable = ?#release(6 : Nat32);
                    },
                    { productId = 3 : Nat32; deliverable = null },
                    {
                        productId = 4 : Nat32;
                        deliverable = ?#release(5 : Nat32);
                    },
                ];
                expect.array<Nat32>(Music.productsSelling(variants.values(), 5), func n = n.toText(), func(a, b) = a == b).equal([1, 4]);
            },
        );
    },
);
