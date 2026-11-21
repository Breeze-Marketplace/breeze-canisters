import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import ShopPresentation "../presentation";
import ShopPermissions "../permissions";
import Fixtures "fixtures";
import { type ArtistProfile; type ProfileProblem; type Settings } "../presentation";

let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let designer = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let catalogManager = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");

func newSettings() : Settings = {
    var mode = #storefront;
    var artistPreset = #linerNotes;
    var artistProfile = null;
};

let profile : ArtistProfile = {
    bio = "Songs about birds.";
    photoKey = ?"/public/artist/gus.jpg";
    links = [
        { kind = #store; url = "https://gus.bandcamp.com" },
        { kind = #streaming; url = "https://open.example.com/artist/gus" },
    ];
};

func problems(p : ArtistProfile) : [Text] = ShopPresentation.profileProblems(p).map(func(e : ProfileProblem) : Text = debug_show (e));

func repeat(text : Text, times : Nat) : Text {
    var out = "";
    for (_ in Array.repeat((), times).values()) out #= text;
    out;
};

suite(
    "artist profile validation",
    func() {
        test(
            "a valid profile has no problems, with or without a photo",
            func() {
                expect.nat(problems(profile).size()).equal(0);
                expect.nat(problems({ profile with photoKey = null; links = [] }).size()).equal(0);
            },
        );
        test(
            "a bio over the limit is refused",
            func() {
                expect.nat(problems({ profile with bio = repeat("a", ShopPresentation.Limits.maxBio) }).size()).equal(0);
                expect.array(problems({ profile with bio = repeat("a", ShopPresentation.Limits.maxBio + 1) }), func t = t, Text.equal).equal([debug_show (#BioTooLong({ max = ShopPresentation.Limits.maxBio }) : ProfileProblem)]);
            },
        );
        test(
            "the photo must be a public vault key",
            func() {
                for (key in ["/private/music/a.flac", "https://example.com/a.jpg", "/public/../private/a", "/public/a.jpg?x=1"].values()) {
                    expect.nat(problems({ profile with photoKey = ?key }).size()).greater(0);
                };
                expect.nat(problems({ profile with photoKey = ?("/public/" # repeat("a", ShopPresentation.Limits.maxAssetKey)) }).size()).equal(1);
            },
        );
        test(
            "links must be https and are capped",
            func() {
                let bad = problems({
                    profile with links = [
                        { kind = #website; url = "https://ok.example.com" },
                        { kind = #social; url = "http://insecure.example.com" },
                        { kind = #other; url = "javascript:alert(1)" },
                        { kind = #other; url = "https://spaces in.example.com" },
                    ]
                });
                expect.nat(bad.size()).equal(3);
                expect.bool(bad[0].contains(#text "index = 1")).isTrue();

                let link = { kind = #website; url = "https://ok.example.com" };
                expect.nat(problems({ profile with links = Array.repeat(link, ShopPresentation.Limits.maxLinks) }).size()).equal(0);
                expect.array(problems({ profile with links = Array.repeat(link, ShopPresentation.Limits.maxLinks + 1) }), func t = t, Text.equal).equal([debug_show (#TooManyLinks({ max = ShopPresentation.Limits.maxLinks }) : ProfileProblem)]);
            },
        );
    },
);

suite(
    "setting the presentation and artist profile",
    func() {
        test(
            "the Owner and Storefront.Edit can set them; others, and anonymous callers, can't",
            func() {
                let auth = Fixtures.newAuthService(owner);
                Fixtures.grantRole(auth, designer, "Designer", [ShopPermissions.storefrontEdit]);
                Fixtures.grantRole(auth, catalogManager, "Catalog", [ShopPermissions.productsEdit]);
                let settings = newSettings();

                expect.bool(ShopPresentation.setPresentation(settings, auth, catalogManager, #artist, null) == #err(#Unauthorized("Changing how the shop is shown needs the Storefront.Edit permission"))).isTrue();
                expect.bool(ShopPresentation.setPresentation(settings, auth, Principal.anonymous(), #artist, null) != #ok(true)).isTrue();
                assert settings.mode == #storefront;

                expect.bool(ShopPresentation.setPresentation(settings, auth, designer, #artist, ?#linerNotes) == #ok(true)).isTrue();
                assert settings.mode == #artist;
                expect.bool(ShopPresentation.setPresentation(settings, auth, owner, #artist, null) == #ok(false)).isTrue();
                expect.bool(ShopPresentation.setPresentation(settings, auth, owner, #storefront, null) == #ok(true)).isTrue();
                assert settings.mode == #storefront;

                switch (ShopPresentation.setArtistProfile(settings, auth, catalogManager, ?profile)) {
                    case (#err(#Unauthorized(_))) {};
                    case (_) assert false;
                };
                assert settings.artistProfile == null;
                assert ShopPresentation.setArtistProfile(settings, auth, designer, ?profile) == #ok;
                assert settings.artistProfile == ?profile;
                assert ShopPresentation.setArtistProfile(settings, auth, owner, null) == #ok;
                assert settings.artistProfile == null;
            },
        );
        test(
            "the preset changes only when one is given, and switching it alone isn't a presentation change",
            func() {
                let auth = Fixtures.newAuthService(owner);
                Fixtures.grantRole(auth, designer, "Designer", [ShopPermissions.storefrontEdit]);
                Fixtures.grantRole(auth, catalogManager, "Catalog", [ShopPermissions.productsEdit]);
                let settings = newSettings();
                expect.bool(ShopPresentation.setPresentation(settings, auth, designer, #artist, ?#gatefold) == #ok(true)).isTrue();
                assert settings.artistPreset == #gatefold;
                expect.bool(ShopPresentation.setPresentation(settings, auth, designer, #artist, ?#setlist) == #ok(false)).isTrue();
                assert settings.artistPreset == #setlist;
                expect.bool(ShopPresentation.setPresentation(settings, auth, owner, #artist, null) == #ok(false)).isTrue();
                assert settings.artistPreset == #setlist;
                expect.bool(ShopPresentation.setPresentation(settings, auth, catalogManager, #artist, ?#linerNotes) != #ok(false)).isTrue();
                assert settings.artistPreset == #setlist;
                // The preset survives a switch to a storefront and back.
                ignore ShopPresentation.setPresentation(settings, auth, owner, #storefront, null);
                ignore ShopPresentation.setPresentation(settings, auth, owner, #artist, null);
                assert ShopPresentation.view(settings, null).artistPreset == ?#setlist;
            },
        );
        test(
            "an invalid profile is refused with every problem and nothing is stored",
            func() {
                let auth = Fixtures.newAuthService(owner);
                let settings = newSettings();
                assert ShopPresentation.setArtistProfile(settings, auth, owner, ?profile) == #ok;
                switch (ShopPresentation.setArtistProfile(settings, auth, owner, ?{ profile with bio = repeat("a", 2_001); photoKey = ?"/private/x" })) {
                    case (#err(#Invalid(list))) expect.nat(list.size()).equal(2);
                    case (_) assert false;
                };
                assert settings.artistProfile == ?profile;
            },
        );
        test(
            "the view wraps every variant in an option",
            func() {
                let settings = newSettings();
                let empty = ShopPresentation.view(settings, null);
                assert empty.presentation == ?#storefront;
                assert empty.artistPreset == ?#linerNotes;
                assert empty.artistProfile == null;

                settings.mode := #artist;
                settings.artistProfile := ?profile;
                let vault = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");
                let full = ShopPresentation.view(settings, ?vault);
                assert full.presentation == ?#artist;
                assert full.mediaCanisterId == ?vault;
                switch (full.artistProfile) {
                    case (?p) {
                        expect.text(p.bio).equal(profile.bio);
                        assert p.links[0].kind == ?#store;
                        expect.text(p.links[1].url).equal("https://open.example.com/artist/gus");
                    };
                    case null assert false;
                };
            },
        );
    },
);
