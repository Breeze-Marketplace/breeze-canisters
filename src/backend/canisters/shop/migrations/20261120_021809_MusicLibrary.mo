import Array "mo:core/Array";
import CoreMap "mo:core/Map";
import Nat "mo:core/Nat";
import CoreSet "mo:core/Set";
import Map "mo:map/Map";

// Adds the music library (BRE-182): an empty `music` record of tracks, releases and the set of sold
// releases. Every product variant gains `deliverable = null` (today's one-media-key delivery) and
// `pricing = ?#fixed` (optional only so clients can read shops not yet upgraded), both in `productVariants` and in each product's `variants`.
//
// Also adds the new `Music.Edit` permission to the "Admin" preset (role 1) while it still holds every
// permission of the previous catalog, and to the "Catalog manager" preset (role 2) while it still holds
// its seeded permissions: a role an Owner trimmed or renamed meant otherwise. Nothing else changes in
// the team.
module {
    type ProductId = Nat32;
    type VariantId = Nat32;
    type TrackId = Nat32;
    type ReleaseId = Nat32;

    type Money = {
        amount : Nat64;
        currency : {
            class_ : { #Cryptocurrency; #FiatCurrency };
            symbol : Text;
        };
        metadata : { decimals : Nat32 };
    };

    type ProductStatus = { #Draft; #Active; #Inactive; #Archived };

    type ProductType = { #Physical; #Digital; #Service };

    type OldVariant = {
        id : VariantId;
        productId : ProductId;
        name : Text;
        sku : Text;
        price : { catalog : [Money] };
        status : ProductStatus;
        attributes : [{ key : Text; value : Text }];
        imageUrls : [Text];
    };

    type NewVariant = OldVariant and {
        deliverable : ?{ #release : ReleaseId };
        pricing : ?{ #fixed; #minimum };
    };

    type OldProduct = {
        id : ProductId;
        title : Text;
        description : Text;
        status : ProductStatus;
        productType : ProductType;
        tags : [Text];
        category : ?Text;
        variants : [OldVariant];
        createdAt : Int;
    };

    type NewProduct = {
        id : ProductId;
        title : Text;
        description : Text;
        status : ProductStatus;
        productType : ProductType;
        tags : [Text];
        category : ?Text;
        variants : [NewVariant];
        createdAt : Int;
    };

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

    type Release = {
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

    type MusicLibrary = {
        tracks : CoreMap.Map<TrackId, Track>;
        releases : CoreMap.Map<ReleaseId, Release>;
        soldReleases : CoreSet.Set<ReleaseId>;
        var nextTrackId : TrackId;
        var nextReleaseId : ReleaseId;
    };

    type TeamRole = { name : Text; permissions : [Text] };
    type Team = {
        roles : CoreMap.Map<Nat, TeamRole>;
        members : CoreMap.Map<Principal, [Nat]>;
        counter : { var nextRoleId : Nat };
    };

    /// The catalog before this version (`lib/permissions.mo`), copied because a migration can't import it.
    let previousCatalog = [
        "Dashboard.View",
        "Products.Edit",
        "Inventory.View",
        "Inventory.Edit",
        "Orders.View",
        "Orders.Fulfill",
        "Orders.Cancel",
        "Funds.View",
        "DigitalAssets.View",
        "DigitalAssets.Edit",
        "Settings.Edit",
        "Events.View",
        "Events.Manage",
        "Logs.View",
        "Storefront.Edit",
        "Team.View",
        "Team.AssignRoles",
        "Team.EditRoles",
    ];
    /// The "Catalog manager" preset as the permissions migration seeded it.
    let catalogManagerPreset = ["Products.Edit", "Inventory.Edit", "DigitalAssets.Edit", "Dashboard.View"];
    let MUSIC_EDIT = "Music.Edit";
    let ADMIN_ROLE_ID = 1;
    let CATALOG_MANAGER_ROLE_ID = 2;

    type OldActor = {
        team : Team;
        products : Map.Map<ProductId, OldProduct>;
        productVariants : Map.Map<VariantId, OldVariant>;
    };
    type NewActor = {
        team : Team;
        products : Map.Map<ProductId, NewProduct>;
        productVariants : Map.Map<VariantId, NewVariant>;
        music : MusicLibrary;
    };

    func withNewFields(v : OldVariant) : NewVariant {
        { v with deliverable = null; pricing = ?#fixed };
    };

    func holdsAll(role : TeamRole, ids : [Text]) : Bool {
        ids.all(func(id : Text) : Bool = role.permissions.any(func(p : Text) : Bool = p == id));
    };

    /// Adds `Music.Edit` to role `id` if it is still the preset named `name` holding `preset`.
    func grantToPreset(team : Team, id : Nat, name : Text, preset : [Text]) {
        switch (team.roles.get(id)) {
            case (?role) {
                if (role.name == name and holdsAll(role, preset) and not holdsAll(role, [MUSIC_EDIT])) {
                    team.roles.add(id, { role with permissions = role.permissions.concat([MUSIC_EDIT]) });
                };
            };
            case null {};
        };
    };

    public func migration(old : OldActor) : NewActor {
        grantToPreset(old.team, ADMIN_ROLE_ID, "Admin", previousCatalog);
        grantToPreset(old.team, CATALOG_MANAGER_ROLE_ID, "Catalog manager", catalogManagerPreset);
        {
            team = old.team;
            products = Map.map<ProductId, OldProduct, NewProduct>(
                old.products,
                Map.n32hash,
                func(_, product) = {
                    product with variants = product.variants.map(withNewFields)
                },
            );
            productVariants = Map.map<VariantId, OldVariant, NewVariant>(
                old.productVariants,
                Map.n32hash,
                func(_, variant) = withNewFields(variant),
            );
            music = {
                tracks = CoreMap.empty();
                releases = CoreMap.empty();
                soldReleases = CoreSet.empty();
                var nextTrackId = 1;
                var nextReleaseId = 1;
            };
        };
    };
};
