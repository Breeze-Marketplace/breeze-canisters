import { expect; suite; test } "mo:test";

import CoreMap "mo:core/Map";
import CoreSet "mo:core/Set";
import Nat32 "mo:core/Nat32";
import Map "mo:map/Map";

import Migration "../migrations/20261120_042534_MusicListings";

type OldRelease = {
    id : Nat32;
    kind : { #Single; #EP; #Album };
    title : Text;
    artist : Text;
    artworkKey : Text;
    releaseDate : ?Int;
    upc : ?Text;
    tracks : [Nat32];
    status : { #Active; #Archived };
};

let release : OldRelease = {
    id = 3;
    kind = #Album;
    title = "Feathers";
    artist = "Gus";
    artworkKey = "/public/music/art";
    releaseDate = null;
    upc = null;
    tracks = [1, 2];
    status = #Active;
};

suite(
    "MusicListings migration (BRE-187)",
    func() {
        test(
            "every release gains no genre and keeps the rest, and the library counters carry over",
            func() {
                let releases = CoreMap.empty<Nat32, OldRelease>();
                CoreMap.add(releases, Nat32.compare, release.id, release);
                let next = Migration.migration({
                    music = {
                        tracks = CoreMap.empty();
                        releases;
                        soldReleases = CoreSet.singleton<Nat32>(3);
                        var nextTrackId = 3;
                        var nextReleaseId = 4;
                    };
                    productUpdatedSubscribers = Map.new();
                });
                switch (CoreMap.get(next.music.releases, Nat32.compare, release.id)) {
                    case (?r) {
                        expect.bool(r.genre == null).isTrue();
                        expect.text(r.title).equal("Feathers");
                        expect.nat(r.tracks.size()).equal(2);
                    };
                    case null assert false;
                };
                expect.bool(CoreSet.contains(next.music.soldReleases, Nat32.compare, release.id)).isTrue();
                expect.nat32(next.music.nextTrackId).equal(3);
                expect.nat32(next.music.nextReleaseId).equal(4);
                expect.nat(Map.size(next.productUpdatedSubscribers)).equal(0);
            },
        );
    },
);
