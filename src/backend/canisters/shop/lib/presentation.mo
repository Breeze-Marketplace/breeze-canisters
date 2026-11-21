import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import AuthService "auth";
import ShopPermissions "permissions";
import Layouts "storefront_layout";

/// How the shop is shown to buyers (BRE-197, design note `docs/artist-pages.md`): as a storefront
/// (the product grid) or as an artist page (music first, other products as merch). Only the
/// presentation changes, never what the shop can sell or the data it keeps, so the owner can switch
/// both ways.
///
/// Queries return variants inside options, like the storefront layout: a client that doesn't know a
/// mode, preset or link kind added later receives `null` for it instead of failing the whole call.
module {
    public type Presentation = { #storefront; #artist };

    /// The starting page an artist page uses while no custom layout is published (BRE-199, BRE-202).
    public type ArtistPreset = {
        /// The default: the storefront look with music first.
        #linerNotes;
        /// Built around the newest release: blurred-cover hero, tabs, docked mini-player.
        #gatefold;
        /// Text first: sticky artist sidebar and a dense discography list.
        #setlist;
    };

    /// What an outbound link in the artist header points to. The kind only chooses the link's label
    /// and icon: every kind is a plain link out, checked the same way (`Layouts.externalUrlProblems`),
    /// and none changes what the shop sells or embeds on the page.
    public type ArtistLinkKind = {
        /// The artist's own site.
        #website;
        /// Another place that sells the artist's music or merch, such as Bandcamp.
        #store;
        /// The artist's profile on a listening service, such as Spotify, Apple Music or SoundCloud.
        #streaming;
        /// A social media profile, such as Instagram.
        #social;
        #other;
    };

    public type ArtistLink = { kind : ArtistLinkKind; url : Text };

    /// The artist header on an artist page: one artist per page, named by the shop's name.
    public type ArtistProfile = {
        bio : Text;
        /// A public key in the shop's vault (`/public/…`), never a URL, like layout images.
        photoKey : ?Layouts.AssetKey;
        links : [ArtistLink];
    };

    public type Settings = {
        var mode : Presentation;
        var artistPreset : ArtistPreset;
        var artistProfile : ?ArtistProfile;
    };

    public type ArtistLinkView = { kind : ?ArtistLinkKind; url : Text };

    public type ArtistProfileView = {
        bio : Text;
        photoKey : ?Layouts.AssetKey;
        links : [ArtistLinkView];
    };

    public type PresentationView = {
        presentation : ?Presentation;
        artistPreset : ?ArtistPreset;
        artistProfile : ?ArtistProfileView;
        /// The vault the photo key is in, null until the shop has one.
        mediaCanisterId : ?Principal;
    };

    /// Caps checked by `profileProblems`. The frontend mirrors them (`src/frontend/src/lib/shopPresentation.ts`).
    public module Limits {
        public let maxBio = 2_000;
        public let maxLinks = 12;
        public let maxUrl = Layouts.Limits.maxUrl;
        public let maxAssetKey = Layouts.Limits.maxAssetKey;
    };

    public type ProfileProblem = {
        #BioTooLong : { max : Nat };
        #InvalidPhoto : Text;
        #TooManyLinks : { max : Nat };
        #InvalidLink : { index : Nat; reason : Text };
    };

    public type SetPresentationError = { #Unauthorized : Text };

    public type SetArtistProfileError = {
        #Unauthorized : Text;
        #Invalid : [ProfileProblem];
    };

    let unauthorized = "Changing how the shop is shown needs the Storefront.Edit permission";

    /// Every problem with `profile`, or `[]` when it can be stored.
    public func profileProblems(profile : ArtistProfile) : [ProfileProblem] {
        let problems = List.empty<ProfileProblem>();
        if (profile.bio.size() > Limits.maxBio) problems.add(#BioTooLong({ max = Limits.maxBio }));
        switch (profile.photoKey) {
            case (?key) {
                if (key.size() > Limits.maxAssetKey) problems.add(#InvalidPhoto("key too long"));
                if (not Layouts.isPublicAssetKey(key)) problems.add(#InvalidPhoto("must be a public file in the shop's media library"));
            };
            case null {};
        };
        if (profile.links.size() > Limits.maxLinks) {
            problems.add(#TooManyLinks({ max = Limits.maxLinks }));
        } else {
            for ((index, link) in profile.links.enumerate()) {
                for (reason in Layouts.externalUrlProblems(link.url).values()) {
                    problems.add(#InvalidLink({ index; reason }));
                };
            };
        };
        problems.toArray();
    };

    func canEdit(authService : AuthService.AuthService, caller : Principal) : Bool {
        not caller.isAnonymous() and AuthService.hasPermission(authService, caller, ShopPermissions.storefrontEdit);
    };

    /// Sets the presentation, and the artist preset unless `artistPreset` is null. Needs
    /// `Storefront.Edit` (the Owner holds it) and a signed-in caller. Returns whether the presentation
    /// changed, so the caller tells subscribers only then.
    public func setPresentation(settings : Settings, authService : AuthService.AuthService, caller : Principal, mode : Presentation, artistPreset : ?ArtistPreset) : Result<Bool, SetPresentationError> {
        if (not canEdit(authService, caller)) return #err(#Unauthorized(unauthorized));
        let changed = settings.mode != mode;
        settings.mode := mode;
        switch (artistPreset) {
            case (?preset) settings.artistPreset := preset;
            case null {};
        };
        #ok(changed);
    };

    /// Replaces the artist profile, or with null removes it. Needs `Storefront.Edit` and a signed-in
    /// caller; nothing is stored unless every limit holds.
    public func setArtistProfile(settings : Settings, authService : AuthService.AuthService, caller : Principal, profile : ?ArtistProfile) : Result<(), SetArtistProfileError> {
        if (not canEdit(authService, caller)) return #err(#Unauthorized(unauthorized));
        switch (profile) {
            case (?p) {
                let problems = profileProblems(p);
                if (problems.size() > 0) return #err(#Invalid(problems));
            };
            case null {};
        };
        settings.artistProfile := profile;
        #ok;
    };

    public func view(settings : Settings, mediaCanisterId : ?Principal) : PresentationView {
        {
            presentation = ?settings.mode;
            artistPreset = ?settings.artistPreset;
            artistProfile = switch (settings.artistProfile) {
                case (?p) ?{
                    bio = p.bio;
                    photoKey = p.photoKey;
                    links = p.links.map<ArtistLink, ArtistLinkView>(func l = { kind = ?l.kind; url = l.url });
                };
                case null null;
            };
            mediaCanisterId;
        };
    };
};
