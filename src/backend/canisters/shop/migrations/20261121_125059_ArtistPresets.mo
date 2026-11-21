// Artist presets (BRE-202): the artist preset gains `#gatefold` and `#setlist`. Every shop keeps the
// preset it has; the presentation record is re-typed because `artistPreset` is a `var` field, whose
// type must match exactly.
module {
    type ArtistProfile = {
        bio : Text;
        photoKey : ?Text;
        links : [{
            kind : { #website; #store; #streaming; #social; #other };
            url : Text;
        }];
    };
    type Presentation = { #storefront; #artist };

    type OldActor = {
        presentation : {
            var mode : Presentation;
            var artistPreset : { #linerNotes };
            var artistProfile : ?ArtistProfile;
        };
    };
    type NewActor = {
        presentation : {
            var mode : Presentation;
            var artistPreset : { #linerNotes; #gatefold; #setlist };
            var artistProfile : ?ArtistProfile;
        };
    };

    public func migration(old : OldActor) : NewActor {
        {
            presentation = {
                var mode = old.presentation.mode;
                var artistPreset = switch (old.presentation.artistPreset) {
                    case (#linerNotes) #linerNotes;
                };
                var artistProfile = old.presentation.artistProfile;
            };
        };
    };
};
