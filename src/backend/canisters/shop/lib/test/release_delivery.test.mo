import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import AuthService "../auth";
import Music "../music";
import ReleaseDelivery "../release_delivery";
import ShopPermissions "../permissions";
import Fixtures "fixtures";

let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let musician = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let buyer = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");
let otherBuyer = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");

let releaseVariant : Nat32 = 7;
let plainVariant : Nat32 = 8;

func setup() : { library : Music.Library; auth : AuthService.AuthService } {
    let auth = Fixtures.newAuthService(owner);
    Fixtures.grantRole(auth, musician, "Musician", [ShopPermissions.musicEdit]);
    { library = Music.emptyLibrary(); auth };
};

func trackInput(n : Text, flac : Bool) : Music.TrackInput {
    let mp3 : Music.AudioFile = {
        format = #mp3_320;
        mediaKey = "/private/music/1/" # n # "/mp3_320";
        bytes = 8_000_000;
    };
    let flacFile : Music.AudioFile = {
        format = #flac;
        mediaKey = "/private/music/1/" # n # "/flac";
        bytes = 30_000_000;
    };
    let withFlac = [mp3, flacFile];
    {
        title = "Track " # n;
        artists = ["Canary"];
        durationMs = 180_000;
        isrc = null;
        explicit = false;
        files = if (flac) withFlac else [mp3];
        previewKey = null;
        credits = [];
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
        upc = null;
        genre = null;
        tracks;
    };
};

func track(s : { library : Music.Library; auth : AuthService.AuthService }, n : Text, flac : Bool) : Music.TrackId {
    switch (Music.createTrack(s.library, s.auth, musician, trackInput(n, flac))) {
        case (#ok(t)) t.id;
        case (#err(_)) { assert false; 0 };
    };
};

func release(s : { library : Music.Library; auth : AuthService.AuthService }, tracks : [Music.TrackId]) : Music.ReleaseId {
    switch (Music.createRelease(s.library, s.auth, musician, releaseInput(tracks))) {
        case (#ok(r)) r.id;
        case (#err(_)) { assert false; 0 };
    };
};

func order(status : ReleaseDelivery.OrderStatus) : ReleaseDelivery.Order {
    {
        buyer;
        status;
        items = [{ variantId = plainVariant; quantity = 1 }, { variantId = releaseVariant; quantity = 1 }];
    };
};

func deliverableOf(r : Music.ReleaseId) : Nat32 -> ?Music.Deliverable {
    func(variantId : Nat32) : ?Music.Deliverable = if (variantId == releaseVariant) ?#release(r) else null;
};

func errTag<T>(r : { #ok : T; #err : ReleaseDelivery.ReleaseDeliveryError }) : Text {
    switch (r) {
        case (#ok(_)) "ok";
        case (#err(e)) {
            let shown = debug_show e;
            switch (shown.split(#char '(').next()) {
                case (?tag) tag;
                case null shown;
            };
        };
    };
};

func keys(files : [(Music.TrackId, Music.AudioFile)]) : [Text] = files.map(func((_, f) : (Music.TrackId, Music.AudioFile)) : Text = f.mediaKey);

suite(
    "Who may download a release",
    func() {
        test(
            "the buyer of a paid release line",
            func() {
                for (status in [#paid, #processing, #partiallyFulfilled, #fulfilled].values()) {
                    expect.bool(ReleaseDelivery.releaseFor(buyer, order(status), 1, deliverableOf(3)) == #ok(3)).isTrue();
                };
            },
        );
        test(
            "not another buyer, nor the anonymous principal",
            func() {
                expect.text(errTag(ReleaseDelivery.releaseFor(otherBuyer, order(#paid), 1, deliverableOf(3)))).equal("#Unauthorized");
                expect.text(errTag(ReleaseDelivery.releaseFor(Principal.anonymous(), order(#paid), 1, deliverableOf(3)))).equal("#Unauthorized");
            },
        );
        test(
            "not before payment, nor after cancelling or a refund",
            func() {
                for (status in [#created, #awaitingPayment, #canceled, #refunded].values()) {
                    expect.text(errTag(ReleaseDelivery.releaseFor(buyer, order(status), 1, deliverableOf(3)))).equal("#OrderNotPaid");
                };
            },
        );
        test(
            "not for a line that sells no release, or one out of range",
            func() {
                expect.text(errTag(ReleaseDelivery.releaseFor(buyer, order(#paid), 0, deliverableOf(3)))).equal("#NotARelease");
                expect.text(errTag(ReleaseDelivery.releaseFor(buyer, order(#paid), 2, deliverableOf(3)))).equal("#InvalidLineIndex");
            },
        );
        test(
            "not for a line with no units, which cost nothing",
            func() {
                let free : ReleaseDelivery.Order = {
                    order(#paid) with items = [{ variantId = plainVariant; quantity = 1 }, { variantId = releaseVariant; quantity = 0 }]
                };
                expect.text(errTag(ReleaseDelivery.releaseFor(buyer, free, 1, deliverableOf(3)))).equal("#InvalidLineIndex");
            },
        );
        test(
            "not once the variant is gone",
            func() {
                expect.text(errTag(ReleaseDelivery.releaseFor(buyer, order(#paid), 1, func(_ : Nat32) : ?Music.Deliverable = null))).equal("#NotARelease");
            },
        );
    },
);

suite(
    "Which files a release delivers",
    func() {
        test(
            "every track's file in the format, in track order",
            func() {
                let s = setup();
                let a = track(s, "a", true);
                let b = track(s, "b", false);
                let r = release(s, [b, a]);
                switch (ReleaseDelivery.filesOf(s.library, r, #mp3_320)) {
                    case (#ok(files)) expect.array(keys(files), Text.toText, Text.equal).equal(["/private/music/1/b/mp3_320", "/private/music/1/a/mp3_320"]);
                    case (#err(_)) assert false;
                };
                switch (ReleaseDelivery.filesOf(s.library, r, #flac)) {
                    case (#ok(files)) expect.array(keys(files), Text.toText, Text.equal).equal(["/private/music/1/a/flac"]);
                    case (#err(_)) assert false;
                };
                expect.text(errTag(ReleaseDelivery.filesOf(s.library, r, #wav))).equal("#FormatUnavailable");
                expect.text(errTag(ReleaseDelivery.filesOf(s.library, 99, #mp3_320))).equal("#NotFound");
            },
        );
        test(
            "a track added and a file replaced after the sale reach the buyer",
            func() {
                let s = setup();
                let a = track(s, "a", false);
                let r = release(s, [a]);
                Music.markSold(s.library, r);
                let bonus = track(s, "bonus", false);
                switch (Music.updateRelease(s.library, s.auth, musician, r, releaseInput([a, bonus]), func(_ : Music.ReleaseId) : Bool = true)) {
                    case (#ok(_)) {};
                    case (#err(_)) assert false;
                };
                let fixed = {
                    trackInput("a", false) with files = [{
                        format = #mp3_320;
                        mediaKey = "/private/music/1/a/mp3_320-v2";
                        bytes = 9_000_000;
                    }]
                };
                switch (Music.updateTrack(s.library, s.auth, musician, a, fixed)) {
                    case (#ok(_)) {};
                    case (#err(_)) assert false;
                };
                switch (ReleaseDelivery.filesOf(s.library, r, #mp3_320)) {
                    case (#ok(files)) expect.array(keys(files), Text.toText, Text.equal).equal(["/private/music/1/a/mp3_320-v2", "/private/music/1/bonus/mp3_320"]);
                    case (#err(_)) assert false;
                };
            },
        );
        test(
            "an archived release still delivers",
            func() {
                let s = setup();
                let r = release(s, [track(s, "a", false)]);
                ignore Music.setReleaseStatus(s.library, s.auth, musician, r, #Archived);
                expect.text(errTag(ReleaseDelivery.filesOf(s.library, r, #mp3_320))).equal("ok");
            },
        );
    },
);

suite(
    "fileNonce",
    func() {
        test(
            "gives each ticket of a call its own 16-byte nonce",
            func() {
                let seed = Blob.fromArray([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32]);
                let first = ReleaseDelivery.fileNonce(seed, 0);
                let second = ReleaseDelivery.fileNonce(seed, 1);
                expect.nat(first.size()).equal(16);
                expect.bool(first == second).isFalse();
                expect.array(second.toArray(), func(n : Nat8) : Text = debug_show n, func(x : Nat8, y : Nat8) : Bool = x == y).equal([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0, 0, 0, 1]);
            },
        );
    },
);
