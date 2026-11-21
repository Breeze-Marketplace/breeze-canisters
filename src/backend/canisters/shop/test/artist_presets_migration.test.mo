import { suite; test } "mo:test";

import Migration "../migrations/20261121_125059_ArtistPresets";

suite(
    "ArtistPresets migration (BRE-202)",
    func() {
        test(
            "keeps each shop's presentation, preset and artist profile",
            func() {
                let profile = ?{
                    bio = "Songs from the night shift";
                    photoKey = ?"/public/photo.jpg";
                    links = [{
                        kind = #store;
                        url = "https://example.bandcamp.com";
                    }];
                };
                let next = Migration.migration({
                    presentation = {
                        var mode = #artist;
                        var artistPreset = #linerNotes;
                        var artistProfile = profile;
                    };
                });
                assert next.presentation.mode == #artist;
                assert next.presentation.artistPreset == #linerNotes;
                assert next.presentation.artistProfile == profile;
            },
        );
        test(
            "a storefront with no profile stays one",
            func() {
                let next = Migration.migration({
                    presentation = {
                        var mode = #storefront;
                        var artistPreset = #linerNotes;
                        var artistProfile = null;
                    };
                });
                assert next.presentation.mode == #storefront;
                assert next.presentation.artistProfile == null;
            },
        );
    },
);
