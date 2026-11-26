import Array "mo:core/Array";
import Nat32 "mo:core/Nat32";
import { type Result } "mo:core/Result";
import Map "mo:map/Map";

import Logger "../../../lib/Logger";
import Pagination "../../../lib/Pagination";
import AuthService "../lib/auth";
import Music "../lib/music";
import PubSubService "../lib/pubsub";
import ProductService "../lib/products";
import ReleaseSales "../lib/release_sales";

import {
    type Order;
    type OrderId;
    type Product;
    type ProductId;
    type ProductVariant;
    type VariantId;
} "../types";

/// The music library (BRE-182): tracks and the releases that list them, edited by staff with
/// `Music.Edit`, read publicly without private file keys, and sold through a variant's `deliverable`.
mixin (
    music : Music.Library,
    products : Map.Map<ProductId, Product>,
    productVariants : Map.Map<VariantId, ProductVariant>,
    orders : Map.Map<OrderId, Order>,
    productService : ProductService.ProductService,
    authService : AuthService.AuthService,
    // Whether an order awaiting payment holds a variant (`OrdersApi`, BRE-185).
    unpaidOrderHolds : VariantId -> Bool,
    pubSubService : PubSubService.PubSubService,
    logger : Logger.BoundLogger,
) {
    /// A page of active releases that have a track, without their tracks (`getPublicRelease` has
    /// them), in ID order. No caller check: it's the storefront's catalog, and holds no private file
    /// keys.
    public query func listPublicReleases(after : ?Music.ReleaseId, limit : ?Nat) : async Pagination.Page<Music.PublicReleaseSummary, Music.ReleaseId> {
        Music.listPublicReleases(music, after, limit);
    };

    /// The lyrics of track `id`, if a release lists it. No caller check: listed tracks are public.
    public query func getTrackLyrics(id : Music.TrackId) : async ?Text {
        Music.getTrackLyrics(music, id);
    };

    /// Release `id` with its tracks, archived or not, or null. No caller check: past buyers see what
    /// they bought, and it holds no private file keys.
    public query func getPublicRelease(id : Music.ReleaseId) : async ?Music.PublicRelease {
        Music.getPublicRelease(music, id);
    };

    /// A page of every track, with private file keys and lyrics, for the editor: at most
    /// `Music.Limits.MAX_TRACKS_PAGE` tracks. Needs `Music.Edit`.
    public shared query ({ caller }) func listTracks(after : ?Music.TrackId, limit : ?Nat) : async Result<Pagination.Page<Music.Track, Music.TrackId>, Music.MusicError> {
        Music.listTracks(music, authService, caller, after, limit);
    };

    /// A page of every release, archived ones included, for the editor. Needs `Music.Edit`.
    public shared query ({ caller }) func listReleases(after : ?Music.ReleaseId, limit : ?Nat) : async Result<Pagination.Page<Music.Release, Music.ReleaseId>, Music.MusicError> {
        Music.listReleases(music, authService, caller, after, limit);
    };

    /// Whether release `id` has sold, so it can't lose a track or be deleted. Needs `Music.Edit`.
    public shared query ({ caller }) func isReleaseSold(id : Music.ReleaseId) : async Result<Bool, Music.MusicError> {
        if (not Music.canEdit(authService, caller)) return #err(#Unauthorized("Needs the Music.Edit permission"));
        #ok(Music.isSold(music, id));
    };

    /// Adds a track. Needs `Music.Edit` and a signed-in caller. Every track needs an MP3 file
    /// (`#mp3_320`); files are private vault keys, the preview a public one.
    public shared ({ caller }) func createTrack(input : Music.TrackInput) : async Result<Music.Track, Music.MusicError> {
        let result = Music.createTrack(music, authService, caller, input);
        switch (result) {
            case (#ok(t)) logger.info("Created track " # Nat32.toText(t.id));
            case (#err(_)) {};
        };
        result;
    };

    /// Replaces a track's details and files; buyers of releases listing it get the new files. Needs
    /// `Music.Edit` and a signed-in caller.
    public shared ({ caller }) func updateTrack(id : Music.TrackId, input : Music.TrackInput) : async Result<Music.Track, Music.MusicError> {
        let result = Music.updateTrack(music, authService, caller, id, input);
        switch (result) {
            case (#ok(_)) logger.info("Updated track " # Nat32.toText(id));
            case (#err(_)) {};
        };
        result;
    };

    /// Archives (`#Archived`) or restores (`#Active`) a track. Needs `Music.Edit` and a signed-in caller.
    public shared ({ caller }) func setTrackStatus(id : Music.TrackId, status : Music.MusicStatus) : async Result<Music.Track, Music.MusicError> {
        let result = Music.setTrackStatus(music, authService, caller, id, status);
        switch (result) {
            case (#ok(_)) logger.info("Set track " # Nat32.toText(id) # " to " # debug_show (status));
            case (#err(_)) {};
        };
        result;
    };

    /// Deletes a track that no release lists (`#InUse` otherwise). Needs `Music.Edit` and a signed-in
    /// caller. Its vault files stay until deleted there.
    public shared ({ caller }) func deleteTrack(id : Music.TrackId) : async Result<(), Music.MusicError> {
        let result = Music.deleteTrack(music, authService, caller, id);
        switch (result) {
            case (#ok) logger.info("Deleted track " # Nat32.toText(id));
            case (#err(_)) {};
        };
        result;
    };

    /// Adds a release listing existing tracks in order. It may start with none while the artist
    /// uploads them: it's listed, and can be sold, once it has one. Needs `Music.Edit` and a signed-in
    /// caller.
    public shared ({ caller }) func createRelease(input : Music.ReleaseInput) : async Result<Music.Release, Music.MusicError> {
        let result = Music.createRelease(music, authService, caller, input);
        switch (result) {
            case (#ok(r)) logger.info("Created release " # Nat32.toText(r.id) # " with " # debug_show (r.tracks.size()) # " tracks");
            case (#err(_)) {};
        };
        result;
    };

    /// Replaces a release's details and track list. Once it has sold, every track must stay
    /// (`#ReleaseSold`); reordering and adding are fine. A release a variant sells keeps at least one
    /// track (`#InUse`). Needs `Music.Edit` and a signed-in caller.
    public shared ({ caller }) func updateRelease(id : Music.ReleaseId, input : Music.ReleaseInput) : async Result<Music.Release, Music.MusicError> {
        let result = Music.updateRelease(music, authService, caller, id, input, isReleaseLinked);
        switch (result) {
            case (#ok(_)) {
                logger.info("Updated release " # Nat32.toText(id));
                // The marketplace shows the release's kind, artist and genre with each product selling it.
                for (product in activeProducts(Music.productsSelling(Map.vals(productVariants), id)).values()) {
                    try { ignore pubSubService.notifyProductUpdated(product) } catch (e) {
                        pubSubService.logUnsent("ProductUpdated", e);
                    };
                };
            };
            case (#err(_)) {};
        };
        result;
    };

    /// Archives (`#Archived`) or restores (`#Active`) a release. Archived releases leave the public list
    /// but past buyers keep them. Needs `Music.Edit` and a signed-in caller.
    public shared ({ caller }) func setReleaseStatus(id : Music.ReleaseId, status : Music.MusicStatus) : async Result<Music.Release, Music.MusicError> {
        let result = Music.setReleaseStatus(music, authService, caller, id, status);
        switch (result) {
            case (#ok(_)) logger.info("Set release " # Nat32.toText(id) # " to " # debug_show (status));
            case (#err(_)) {};
        };
        result;
    };

    /// Deletes a release that never sold (`#ReleaseSold`: archive it instead) and no variant sells
    /// (`#InUse`). Needs `Music.Edit` and a signed-in caller.
    public shared ({ caller }) func deleteRelease(id : Music.ReleaseId) : async Result<(), Music.MusicError> {
        let result = Music.deleteRelease(music, authService, caller, id, isReleaseLinked);
        switch (result) {
            case (#ok) logger.info("Deleted release " # Nat32.toText(id));
            case (#err(_)) {};
        };
        result;
    };

    /// Sets the release variant `variantId` sells, or with null goes back to its single media key.
    /// The release must exist, be active and have a track. A variant that has sold can't move off its release
    /// (`#ReleaseSold`): its buyers would lose it. Linking a sold variant marks the release sold. Needs
    /// `Music.Edit` and a signed-in caller.
    public shared ({ caller }) func setVariantDeliverable(variantId : VariantId, deliverable : ?Music.Deliverable) : async Result<(), Music.MusicError> {
        if (not Music.canEdit(authService, caller)) return #err(#Unauthorized("Linking a variant to a release needs the Music.Edit permission"));
        let ?variant = Map.get(productVariants, Map.n32hash, variantId) else return #err(#NotFound("Variant " # Nat32.toText(variantId) # " not found"));
        if (variant.deliverable == deliverable) return #ok;
        switch (Music.checkDeliverable(music, deliverable)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        // Whether the variant holds stock depends on its release, and an unpaid order settles the
        // stock it reserved by that, so wait for it to be paid or expire.
        if (unpaidOrderHolds(variantId)) {
            return #err(#InUse("An order awaiting payment holds variant " # Nat32.toText(variantId) # "; try again once it's paid or expires"));
        };
        let sold = variantHasSold(variantId);
        switch (variant.deliverable) {
            case (?#release(r)) if (sold) {
                return #err(#ReleaseSold("Variant " # Nat32.toText(variantId) # " has sold with release " # Nat32.toText(r) # "; its buyers would lose it"));
            };
            case null {};
        };
        switch (ProductService.setVariantDeliverable(productService, variantId, deliverable)) {
            case (#err(msg)) return #err(#NotFound(msg));
            case (#ok(_)) {};
        };
        switch (deliverable) {
            case (?#release(r)) if (sold) Music.markSold(music, r);
            case null {};
        };
        logger.info("Set variant " # Nat32.toText(variantId) # " to deliver " # debug_show (deliverable));
        for (product in activeProducts([variant.productId]).values()) {
            try { ignore pubSubService.notifyProductUpdated(product) } catch (e) {
                pubSubService.logUnsent("ProductUpdated", e);
            };
        };
        #ok;
    };

    /// The active ones of `ids`: the product-updated subscribers get them, so the marketplace sees their
    /// variants' releases (BRE-187).
    private func activeProducts(ids : [ProductId]) : [Product] {
        ids.filterMap(
            func(id : ProductId) : ?Product = switch (Map.get(products, Map.n32hash, id)) {
                case (?p) if (p.status == #Active) ?p else null;
                case null null;
            }
        );
    };

    /// Records the releases a paid order delivers as sold. `OrdersApi.storeOrder` calls it on every write.
    private func recordReleaseSales(order : Order) {
        if (not ReleaseSales.isSale(order.status)) return;
        for (item in order.items.values()) {
            switch (Map.get(productVariants, Map.n32hash, item.variantId)) {
                case (?{ deliverable = ?#release(r) }) Music.markSold(music, r);
                case _ {};
            };
        };
    };

    /// Whether a paid order holds variant `variantId`. Scans every order: only a merchant's relinking
    /// pays for it.
    private func variantHasSold(variantId : VariantId) : Bool {
        ReleaseSales.hasSold(Map.vals(orders), variantId);
    };

    /// The first of `variants` a buyer gets, or will once their order is paid, a release through,
    /// which `CatalogApi` won't delete or drop (BRE-192). Scans every order only when one of them
    /// sells a sold release.
    private func heldReleaseVariant(variants : [ProductVariant]) : ?(ProductVariant, ReleaseSales.Hold) {
        ReleaseSales.heldReleaseVariant(music, Map.vals(orders), unpaidOrderHolds, variants);
    };

    private func isReleaseLinked(id : Music.ReleaseId) : Bool {
        for (v in Map.vals(productVariants)) {
            if (v.deliverable == ?#release(id)) return true;
        };
        false;
    };
};
