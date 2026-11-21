import CoreMap "mo:core/Map";
import CoreSet "mo:core/Set";
import Map "mo:map/Map";

// Music on the marketplace (BRE-187):
// - Adds an optional `genre` to every release, null for the releases already stored.
// - Product-updated events now carry each variant's `release` (kind, artist, genre). The subscribers'
//   callbacks are stored with the event type, so they are re-typed: a callback that took the old event
//   takes the new one (its extra field is dropped by a subscriber that doesn't know it).
module {
    type ProductId = Nat32;
    type VariantId = Nat32;

    type Money = {
        currency : {
            class_ : { #FiatCurrency; #Cryptocurrency };
            symbol : Text;
        };
        amount : Nat64;
        metadata : { decimals : Nat32 };
    };
    type ProductStatus = { #Draft; #Active; #Inactive; #Archived };
    type ProductType = { #Physical; #Digital; #Service };
    type ProductAttribute = { key : Text; value : Text };

    type OldEventVariant = {
        variantId : VariantId;
        name : Text;
        sku : Text;
        priceCatalog : [Money];
        status : ProductStatus;
        attributes : [ProductAttribute];
        imageUrls : [Text];
    };

    type NewEventVariant = OldEventVariant and {
        release : ?{
            kind : { #Single; #EP; #Album };
            artist : Text;
            genre : ?Text;
        };
    };

    type OldListener = shared {
        data : {
            productId : ProductId;
            title : Text;
            description : Text;
            productType : ProductType;
            tags : [Text];
            category : ?Text;
            variants : [OldEventVariant];
        };
    } -> async ();

    type NewListener = shared {
        data : {
            productId : ProductId;
            title : Text;
            description : Text;
            productType : ProductType;
            tags : [Text];
            category : ?Text;
            variants : [NewEventVariant];
        };
    } -> async ();

    type TrackId = Nat32;
    type ReleaseId = Nat32;

    type AudioFormat = { #mp3_320; #flac; #wav; #aiff; #alac; #aac_256 };
    type MusicStatus = { #Active; #Archived };

    type Track = {
        id : TrackId;
        title : Text;
        artists : [Text];
        durationMs : Nat32;
        isrc : ?Text;
        explicit : Bool;
        files : [{ format : AudioFormat; mediaKey : Text; bytes : Nat }];
        previewKey : ?Text;
        credits : [(Text, Text)];
        lyrics : ?Text;
        status : MusicStatus;
    };

    type OldRelease = {
        id : ReleaseId;
        kind : { #Single; #EP; #Album };
        title : Text;
        artist : Text;
        artworkKey : Text;
        releaseDate : ?Int;
        upc : ?Text;
        tracks : [TrackId];
        status : MusicStatus;
    };

    type NewRelease = OldRelease and { genre : ?Text };

    type OldLibrary = {
        tracks : CoreMap.Map<TrackId, Track>;
        releases : CoreMap.Map<ReleaseId, OldRelease>;
        soldReleases : CoreSet.Set<ReleaseId>;
        var nextTrackId : TrackId;
        var nextReleaseId : ReleaseId;
    };

    type NewLibrary = {
        tracks : CoreMap.Map<TrackId, Track>;
        releases : CoreMap.Map<ReleaseId, NewRelease>;
        soldReleases : CoreSet.Set<ReleaseId>;
        var nextTrackId : TrackId;
        var nextReleaseId : ReleaseId;
    };

    type OldActor = {
        music : OldLibrary;
        productUpdatedSubscribers : Map.Map<Principal, OldListener>;
    };
    type NewActor = {
        music : NewLibrary;
        productUpdatedSubscribers : Map.Map<Principal, NewListener>;
    };

    public func migration(old : OldActor) : NewActor {
        let productUpdatedSubscribers = Map.new<Principal, NewListener>();
        for ((subscriber, listener) in Map.entries(old.productUpdatedSubscribers)) {
            Map.set<Principal, NewListener>(productUpdatedSubscribers, Map.phash, subscriber, listener);
        };
        {
            productUpdatedSubscribers;
            music = {
                tracks = old.music.tracks;
                releases = CoreMap.map<ReleaseId, OldRelease, NewRelease>(old.music.releases, func(_, r) = { r with genre = null : ?Text });
                soldReleases = old.music.soldReleases;
                var nextTrackId = old.music.nextTrackId;
                var nextReleaseId = old.music.nextReleaseId;
            };
        };
    };
};
