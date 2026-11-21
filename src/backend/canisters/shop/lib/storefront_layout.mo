import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Time "mo:core/Time";

import AuthService "auth";
import ShopPermissions "permissions";
import ShopThemes "shop_theme";

/// The storefront home page built from sections and elements (BRE-172, design note
/// `docs/customizable-storefronts.md`): a page is a list of sections, each a row of columns, each a
/// stack of elements.
///
/// Staff edit a draft layout and publish it; buyers only ever see the published one. Every value is a
/// variant, a number or bounded text, and `validate` caps every collection and text before anything is
/// stored, which bounds both storage and what a single save can cost.
///
/// The wire format differs from the stable one: queries return sections and elements as options, so a
/// client that can't decode one added later receives `null` for it instead of failing the whole call.
module {
    public type ProductId = Nat32;

    /// A key in the shop's own vault (`/public/...`), never a full URL: the frontend builds the URL from
    /// the vault core registered for the shop, so a layout can't point at another origin.
    public type AssetKey = Text;

    /// Where a link goes. Product and category links stay on the storefront.
    public type Link = {
        #product : ProductId;
        #category : Text;
        #external : Text; // https only
    };

    /// Text the merchant types, or text taken from the shop's details when the page renders.
    public type TextSource = {
        #literal : Text;
        #shopName;
        #shopDescription;
    };

    public type CallToAction = { text : Text; link : Link };

    /// Restricted rich text: a flat list of nodes, never HTML, so its depth is fixed by the type.
    public type TextSpan = {
        text : Text;
        bold : Bool;
        italic : Bool;
        link : ?Link;
    };

    public type RichTextNode = {
        #heading : Text;
        #paragraph : [TextSpan];
        #bulletList : [[TextSpan]];
    };

    /// Which products a products element shows. Resolved against the catalog when the page renders,
    /// so prices and stock are always current.
    public type ProductSource = {
        #all;
        #category : Text;
        #tag : Text;
        #picked : [ProductId];
    };

    /// `#manual` keeps the picked order (or newest first for other sources).
    public type ProductSort = {
        #manual;
        #newest;
        #priceLowToHigh;
        #priceHighToLow;
    };

    /// An image from the shop's vault, or one of the shop's own images, read when the page renders.
    public type ImageSource = {
        #asset : AssetKey;
        #shopBanner;
        #shopLogo;
    };

    public type Align = { #start; #center; #end };

    /// A release in the shop's music library (`lib/music`).
    public type ReleaseId = Nat32;
    public type ReleaseKind = { #Single; #EP; #Album };

    /// Which releases a releases element shows (BRE-198). Resolved against the music library and
    /// the catalog when the page renders: only releases an active variant sells appear.
    public type ReleaseSource = {
        #all;
        #kind : ReleaseKind;
        #picked : [ReleaseId];
    };

    /// `#manual` keeps the picked order (newest first for other sources).
    public type ReleaseSort = { #newest; #manual };

    /// `#row` is one line that scrolls sideways; `#list` is a row per release.
    public type ReleaseStyle = { #grid; #row; #list };

    /// `#latest`: the newest release on sale, so the element follows new releases without edits.
    public type FeaturedReleaseChoice = { #latest; #picked : ReleaseId };

    /// How much of the tracklist a featured release lists.
    public type TrackCount = { #all; #first : Nat; #none };

    /// The parts a section's columns are made of. Each is small and does one thing;
    /// sections and columns arrange them.
    public type Element = {
        #heading : {
            text : TextSource;
            level : { #h1; #h2; #h3 };
            align : Align;
        };
        #text : { content : [RichTextNode]; align : Align };
        #image : {
            source : ImageSource;
            alt : Text;
            aspect : { #original; #banner; #wide; #square; #tall };
            link : ?Link;
        };
        #button : {
            text : Text;
            link : Link;
            style : { #primary; #secondary };
            align : Align;
        };
        #products : {
            title : ?Text;
            source : ProductSource;
            sort : ProductSort;
            limit : Nat;
            perRow : Nat;
            showCategoryFilter : Bool;
        };
        /// The shop's logo, name, description and location, as the storefront header always showed them.
        #shopInfo : { showDescription : Bool; showLocation : Bool };
        #faq : { entries : [{ question : Text; answer : Text }] };
        #divider;
        #spacer : { size : { #small; #medium; #large } };
        /// Releases as artwork-led cards that play a preview (BRE-198).
        #releases : {
            title : ?Text;
            source : ReleaseSource;
            sort : ReleaseSort;
            style : ReleaseStyle;
            limit : Nat;
            perRow : Nat; // in the grid style
            showArtist : Bool;
        };
        /// One release with its artwork, details, preview player, tracklist and a buy button for the
        /// variant that sells it (BRE-198).
        #featuredRelease : {
            release : FeaturedReleaseChoice;
            tracks : TrackCount;
            showBuy : Bool;
        };
    };

    /// An element and its id, unique within the layout (the editor selects and moves by it).
    public type ElementNode = { id : Nat; element : Element };

    /// A column on the section's 12-column grid. Columns stack on small screens.
    public type Column = { span : Nat; elements : [ElementNode] };

    /// A full-width band of the page: its background, spacing and width, and the
    /// columns its elements sit in.
    public type Section = {
        id : Nat;
        background : {
            #none;
            #muted;
            #card;
            #primary;
            #accent;
            /// Under a scrim of the page color, so text on it stays readable.
            #image : ImageSource;
        };
        padding : { #none; #small; #medium; #large };
        width : { #contained; #full };
        verticalAlign : { #start; #center; #end };
        columns : [Column];
    };

    /// Style tokens for the storefront: the BRE-171 theme without `hero` (sections now lay out the
    /// header), plus spacing between sections and button style. Every value is a variant or a byte, and the colors must pass
    /// the same WCAG AA check as `ShopTheme`.
    public type StorefrontTheme = {
        primary : ShopThemes.ThemeColor;
        onPrimary : ShopThemes.TextTone;
        accent : ShopThemes.ThemeColor;
        onAccent : ShopThemes.TextTone;
        fonts : { #archivoGrotesk; #grotesk; #monoGrotesk; #mono };
        shape : { #sharp; #rounded; #soft };
        colorScheme : { #dark; #light };
        density : { #compact; #regular; #airy };
        buttonStyle : { #solid; #outline };
    };

    /// A layout as stored.
    public type StorefrontLayout = {
        theme : ?StorefrontTheme; // null: the marketplace's look
        home : [Section];
        updatedAt : Time.Time;
        updatedBy : Principal;
    };

    /// Storefront customization (BRE-170). A record of `var` fields so the mixin can update it.
    public type StorefrontSettings = {
        /// The BRE-171 theme. Publishing a layout writes it too, so clients that only know
        /// `getShopTheme` (and checkout on older frontends) show the published colors.
        var theme : ?ShopThemes.ShopTheme;
        /// What the editor saves. Null until staff first save.
        var draft : ?StorefrontLayout;
        /// What buyers see. Null until staff first publish: the storefront then shows its default layout.
        var published : ?StorefrontLayout;
        /// Bumped by every change to the draft, so two editors can't overwrite each other unknowingly.
        var revision : Nat;
    };

    /// What a save sends: the server stamps the time and author.
    public type LayoutInput = {
        theme : ?StorefrontTheme;
        home : [Section];
    };

    /// Sections and elements as queries return them: optional, so an older client skips what it
    /// can't decode.
    public type ColumnView = { span : Nat; elements : [?ElementNode] };
    public type SectionView = {
        id : Nat;
        background : {
            #none;
            #muted;
            #card;
            #primary;
            #accent;
            #image : ImageSource;
        };
        padding : { #none; #small; #medium; #large };
        width : { #contained; #full };
        verticalAlign : { #start; #center; #end };
        columns : [ColumnView];
    };

    /// The published layout as anyone may read it. No author: staff principals aren't public.
    public type PublishedLayoutView = {
        theme : ?StorefrontTheme;
        home : [?SectionView];
        updatedAt : Time.Time;
        /// The vault its `AssetKey`s are in, so signed-out buyers (who can't read `getMediaCanisterId`)
        /// see the images.
        vaultId : ?Principal;
    };

    public type DraftView = {
        theme : ?StorefrontTheme;
        home : [?SectionView];
        updatedAt : Time.Time;
        updatedBy : Principal;
    };

    public type EditorState = {
        draft : ?DraftView;
        revision : Nat;
        publishedAt : ?Time.Time;
        /// False when the draft is what buyers already see (or there is neither).
        hasUnpublishedChanges : Bool;
    };

    /// An element type (or `"section"`) this shop accepts, and the version of its settings record.
    public type ElementType = { kind : Text; version : Nat };

    /// What's wrong, and where: `id` is the section's or element's.
    public type ValidationError = {
        #TooManySections : { max : Nat };
        #TooManyElements : { max : Nat };
        #DuplicateId : Nat;
        #ColumnsTooWide : { id : Nat; total : Nat };
        #TextTooLong : { id : Nat; field : Text; max : Nat };
        #EmptyText : { id : Nat; field : Text };
        #TooManyItems : { id : Nat; field : Text; max : Nat };
        #OutOfRange : { id : Nat; field : Text; min : Nat; max : Nat };
        #InvalidLink : { id : Nat; reason : Text };
        #InvalidImage : { id : Nat; reason : Text };
        #LayoutTooLarge : { bytes : Nat; max : Nat };
    };

    public type SaveDraftError = {
        #Unauthorized : Text;
        /// Someone saved since this editor loaded; holds the current revision.
        #RevisionConflict : Nat;
        #Invalid : [ValidationError];
        #ContrastTooLow : [ShopThemes.ContrastFailure];
    };

    public type PublishError = {
        #Unauthorized : Text;
        #RevisionConflict : Nat;
        #NoDraft;
    };

    /// Caps checked by `validate`. The frontend mirrors them (`LIMITS` in `src/frontend/src/lib/storefront/model.ts`).
    public module Limits {
        public let maxSections = 30;
        public let maxColumns = 4; // per section
        public let gridColumns = 12; // the spans of a section's columns add up to at most this
        public let maxElementsPerColumn = 20;
        public let maxElements = 150; // in the whole layout
        public let maxShortText = 120; // headings, titles, button text, questions, alt text
        public let maxLongText = 2_000; // a span, an FAQ answer
        public let maxCategory = 100;
        public let maxUrl = 2_048;
        public let maxAssetKey = 512;
        public let maxRichTextNodes = 40;
        public let maxSpans = 40;
        public let maxListItems = 30;
        public let maxPickedProducts = 24;
        public let maxFaqEntries = 30;
        public let maxProducts = 48; // a products element's limit
        public let maxPerRow = 4;
        public let maxPickedReleases = 24;
        public let maxReleases = 48; // a releases element's limit
        public let maxReleasesPerRow = 6;
        /// A featured release's `#first` tracks: the music library's tracks per release.
        public let maxFeaturedTracks = 100;
        /// Upper bound on a layout's size (`sizeOf`: its text in UTF-8 plus a fixed cost per value).
        /// Also bounds what `publish` copies.
        public let maxLayoutBytes = 131_072; // 128 KiB
    };

    /// The element types this version accepts, and the section record's version. Bump a version when
    /// its settings record changes.
    public let elementTypes : [ElementType] = [
        { kind = "section"; version = 1 },
        { kind = "heading"; version = 1 },
        { kind = "text"; version = 1 },
        { kind = "image"; version = 1 },
        { kind = "button"; version = 1 },
        { kind = "products"; version = 1 },
        { kind = "shopInfo"; version = 1 },
        { kind = "faq"; version = 1 },
        { kind = "divider"; version = 1 },
        { kind = "spacer"; version = 1 },
        { kind = "releases"; version = 1 },
        { kind = "featuredRelease"; version = 1 },
    ];

    // ---- Validation ---------------------------------------------------------------------------------

    /// Collects every problem in a layout instead of stopping at the first, so the editor can show all.
    class Checker() {
        let errors = Set.empty<Text>();
        var list : [ValidationError] = [];

        public func add(error : ValidationError) {
            // The same rule broken twice in one field reports once.
            let key = debug_show (error);
            if (not errors.contains(key)) {
                errors.add(key);
                list := list.concat([error]);
            };
        };

        public func result() : [ValidationError] = list;

        public func text(id : Nat, field : Text, value : Text, max : Nat, required : Bool) {
            if (required and value.trim(#char ' ') == "") add(#EmptyText({ id; field }));
            if (value.size() > max) add(#TextTooLong({ id; field; max }));
        };

        public func count(id : Nat, field : Text, n : Nat, max : Nat) {
            if (n > max) add(#TooManyItems({ id; field; max }));
        };

        public func range(id : Nat, field : Text, n : Nat, min : Nat, max : Nat) {
            if (n < min or n > max) add(#OutOfRange({ id; field; min; max }));
        };

        public func link(id : Nat, value : Link) {
            switch (value) {
                case (#product(_)) {};
                case (#category(c)) text(id, "link category", c, Limits.maxCategory, true);
                case (#external(url)) {
                    for (reason in externalUrlProblems(url).values()) add(#InvalidLink({ id; reason }));
                };
            };
        };

        public func image(id : Nat, key : AssetKey) {
            if (key.size() > Limits.maxAssetKey) add(#InvalidImage({ id; reason = "key too long" }));
            if (not isPublicAssetKey(key)) add(#InvalidImage({ id; reason = "must be a public file in the shop's media library" }));
        };

        public func textSource(id : Nat, field : Text, source : TextSource) {
            switch (source) {
                case (#literal(t)) text(id, field, t, Limits.maxShortText, false);
                case (#shopName or #shopDescription) {};
            };
        };

        public func callToAction(id : Nat, cta : ?CallToAction) {
            switch (cta) {
                case (?c) {
                    text(id, "button text", c.text, Limits.maxShortText, true);
                    link(id, c.link);
                };
                case null {};
            };
        };

        public func spans(id : Nat, field : Text, spans : [TextSpan]) {
            count(id, field, spans.size(), Limits.maxSpans);
            for (span in spans.values()) {
                text(id, field, span.text, Limits.maxLongText, false);
                switch (span.link) {
                    case (?l) link(id, l);
                    case null {};
                };
            };
        };

        public func richText(id : Nat, field : Text, nodes : [RichTextNode]) {
            count(id, field, nodes.size(), Limits.maxRichTextNodes);
            for (node in nodes.values()) {
                switch (node) {
                    case (#heading(h)) text(id, field # " heading", h, Limits.maxShortText, true);
                    case (#paragraph(p)) spans(id, field, p);
                    case (#bulletList(items)) {
                        count(id, field # " list", items.size(), Limits.maxListItems);
                        for (item in items.values()) spans(id, field, item);
                    };
                };
            };
        };

        public func optionalTitle(id : Nat, title : ?Text) {
            switch (title) {
                case (?t) text(id, "title", t, Limits.maxShortText, false);
                case null {};
            };
        };
    };

    /// Why `url` can't be an external link, or `[]` when it can: https only, bounded, and nothing a URL
    /// can't hold. Also used for an artist's links (`lib/presentation`).
    public func externalUrlProblems(url : Text) : [Text] {
        let problems = List.empty<Text>();
        if (url.size() > Limits.maxUrl) problems.add("longer than " # Limits.maxUrl.toText() # " characters");
        if (not url.startsWith(#text "https://") or url.size() <= 8) problems.add("must start with https://");
        if (url.contains(#predicate(func c = c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == '<' or c == '>' or c == '\"'))) {
            problems.add("contains spaces or characters a URL can't hold");
        };
        problems.toArray();
    };

    /// True for a key the vault serves publicly. `/private/` files need a delivery ticket, so a layout
    /// can't reference them; `..` and query strings could escape the intended file.
    public func isPublicAssetKey(key : AssetKey) : Bool {
        (key.startsWith(#text "/public/") or key.startsWith(#text "/images/")) and not key.contains(#text "..") and not key.contains(#char '?') and not key.contains(#char '#') and not key.contains(#char '\\');
    };

    func imageSource(c : Checker, id : Nat, source : ImageSource) {
        switch (source) {
            case (#asset(key)) c.image(id, key);
            case (#shopBanner or #shopLogo) {};
        };
    };

    func checkElement(c : Checker, { id; element } : ElementNode) {
        switch (element) {
            case (#heading(h)) c.textSource(id, "heading", h.text);
            case (#text(t)) c.richText(id, "text", t.content);
            case (#image(i)) {
                imageSource(c, id, i.source);
                c.text(id, "image description", i.alt, Limits.maxShortText, false);
                switch (i.link) {
                    case (?l) c.link(id, l);
                    case null {};
                };
            };
            case (#button(b)) {
                c.text(id, "button text", b.text, Limits.maxShortText, true);
                c.link(id, b.link);
            };
            case (#products(p)) {
                c.optionalTitle(id, p.title);
                switch (p.source) {
                    case (#all) {};
                    case (#category(v)) c.text(id, "category", v, Limits.maxCategory, true);
                    case (#tag(v)) c.text(id, "tag", v, Limits.maxCategory, true);
                    case (#picked(ids)) c.count(id, "products", ids.size(), Limits.maxPickedProducts);
                };
                c.range(id, "number of products", p.limit, 1, Limits.maxProducts);
                c.range(id, "products per row", p.perRow, 1, Limits.maxPerRow);
            };
            case (#shopInfo(_) or #divider or #spacer(_)) {};
            case (#releases(r)) {
                c.optionalTitle(id, r.title);
                switch (r.source) {
                    case (#all or #kind(_)) {};
                    case (#picked(ids)) c.count(id, "releases", ids.size(), Limits.maxPickedReleases);
                };
                c.range(id, "number of releases", r.limit, 1, Limits.maxReleases);
                c.range(id, "releases per row", r.perRow, 1, Limits.maxReleasesPerRow);
            };
            case (#featuredRelease(f)) {
                switch (f.tracks) {
                    case (#first(n)) c.range(id, "number of tracks", n, 1, Limits.maxFeaturedTracks);
                    case (#all or #none) {};
                };
            };
            case (#faq(f)) {
                c.count(id, "questions", f.entries.size(), Limits.maxFaqEntries);
                for (entry in f.entries.values()) {
                    c.text(id, "question", entry.question, Limits.maxShortText, true);
                    c.text(id, "answer", entry.answer, Limits.maxLongText, true);
                };
            };
        };
    };

    func checkSection(c : Checker, section : Section) {
        switch (section.background) {
            case (#image(source)) imageSource(c, section.id, source);
            case (_) {};
        };
        c.range(section.id, "columns", section.columns.size(), 1, Limits.maxColumns);
        var total = 0;
        for (column in section.columns.values()) {
            c.range(section.id, "column width", column.span, 1, Limits.gridColumns);
            total += column.span;
            c.count(section.id, "elements in a column", column.elements.size(), Limits.maxElementsPerColumn);
            for (node in column.elements.values()) checkElement(c, node);
        };
        if (total > Limits.gridColumns) c.add(#ColumnsTooWide({ id = section.id; total }));
    };

    func elementCount(home : [Section]) : Nat = home.foldLeft(
        0,
        func(acc, s) = acc + s.columns.foldLeft(0, func(a, col) = a + col.elements.size()),
    );

    /// An upper bound on a layout's stored size: every text in UTF-8 plus `perValue` bytes for each
    /// record, number and variant. Not `to_candid`, which the test interpreter can't run, but it bounds
    /// the same thing. Runs before the per-field checks, so it also caps their cost.
    public func sizeOf(layout : LayoutInput) : Nat {
        let perValue = 16;
        func t(value : Text) : Nat = value.encodeUtf8().size() + perValue;
        func link(l : Link) : Nat = switch (l) {
            case (#product(_)) perValue;
            case (#category(c)) t(c);
            case (#external(u)) t(u);
        };
        func optLink(l : ?Link) : Nat = switch (l) {
            case (?v) link(v);
            case null perValue;
        };
        func optText(v : ?Text) : Nat = switch (v) {
            case (?x) t(x);
            case null perValue;
        };
        func source(s : TextSource) : Nat = switch (s) {
            case (#literal(x)) t(x);
            case (_) perValue;
        };
        func image(s : ImageSource) : Nat = switch (s) {
            case (#asset(k)) t(k);
            case (_) perValue;
        };
        func spans(xs : [TextSpan]) : Nat = xs.foldLeft(perValue, func(acc, s) = acc + t(s.text) + optLink(s.link) + 2 * perValue);
        func rich(nodes : [RichTextNode]) : Nat = nodes.foldLeft(
            perValue,
            func(acc, n) = acc + (
                switch (n) {
                    case (#heading(h)) t(h);
                    case (#paragraph(p)) spans(p);
                    case (#bulletList(items)) items.foldLeft(perValue, func(a, item) = a + spans(item));
                }
            ),
        );
        func element(e : Element) : Nat = switch (e) {
            case (#heading(h)) source(h.text) + 2 * perValue;
            case (#text(x)) rich(x.content) + perValue;
            case (#image(i)) image(i.source) + t(i.alt) + optLink(i.link) + perValue;
            case (#button(b)) t(b.text) + link(b.link) + 2 * perValue;
            case (#products(p)) optText(p.title) + (
                switch (p.source) {
                    case (#category(c) or #tag(c)) t(c);
                    case (#picked(ids)) perValue * (ids.size() + 1);
                    case (#all) perValue;
                }
            ) + 4 * perValue;
            case (#faq(f)) f.entries.foldLeft(perValue, func(a, x) = a + t(x.question) + t(x.answer));
            case (#shopInfo(_) or #divider or #spacer(_)) 2 * perValue;
            case (#releases(r)) optText(r.title) + (
                switch (r.source) {
                    case (#picked(ids)) perValue * (ids.size() + 1);
                    case (#all or #kind(_)) perValue;
                }
            ) + 5 * perValue;
            case (#featuredRelease(_)) 4 * perValue;
        };
        layout.home.foldLeft(
            perValue * 12, // the theme
            func(acc, s) = acc + (
                switch (s.background) {
                    case (#image(i)) image(i);
                    case (_) perValue;
                }
            ) + 5 * perValue + s.columns.foldLeft(
                0,
                func(a, col) = a + 2 * perValue + col.elements.foldLeft(0, func(b, node) = b + 2 * perValue + element(node.element)),
            ),
        );
    };

    /// Every limit the layout breaks; empty when it may be stored.
    public func validate(layout : LayoutInput) : [ValidationError] {
        let c = Checker();
        // Don't walk an oversized layout: the counts alone reject it.
        if (layout.home.size() > Limits.maxSections) return [#TooManySections({ max = Limits.maxSections })];
        if (layout.home.any(func s = s.columns.size() > Limits.maxColumns or s.columns.any(func col = col.elements.size() > Limits.maxElementsPerColumn))) {
            return [#TooManyElements({ max = Limits.maxElementsPerColumn })];
        };
        if (elementCount(layout.home) > Limits.maxElements) return [#TooManyElements({ max = Limits.maxElements })];
        let bytes = sizeOf(layout);
        if (bytes > Limits.maxLayoutBytes) {
            return [#LayoutTooLarge({ bytes; max = Limits.maxLayoutBytes })];
        };
        let ids = Set.empty<Nat>();
        func claim(id : Nat) {
            if (ids.contains(id)) c.add(#DuplicateId(id)) else ids.add(id);
        };
        for (section in layout.home.values()) {
            claim(section.id);
            for (column in section.columns.values()) {
                for (node in column.elements.values()) claim(node.id);
            };
            checkSection(c, section);
        };
        c.result();
    };

    // ---- Theme --------------------------------------------------------------------------------------

    /// The BRE-171 theme matching a layout's. Its `hero` only shapes the home page of clients that don't
    /// know layouts, so it keeps the shop's last choice.
    public func toShopTheme(theme : StorefrontTheme, hero : { #banner; #split; #minimal }) : ShopThemes.ShopTheme {
        {
            primary = theme.primary;
            onPrimary = theme.onPrimary;
            accent = theme.accent;
            onAccent = theme.onAccent;
            fonts = theme.fonts;
            shape = theme.shape;
            colorScheme = theme.colorScheme;
            hero;
        };
    };

    // ---- Views --------------------------------------------------------------------------------------

    func wire(home : [Section]) : [?SectionView] = home.map<Section, ?SectionView>(
        func s = ?{
            id = s.id;
            background = s.background;
            padding = s.padding;
            width = s.width;
            verticalAlign = s.verticalAlign;
            columns = s.columns.map<Column, ColumnView>(
                func col = {
                    span = col.span;
                    elements = col.elements.map<ElementNode, ?ElementNode>(func e = ?e);
                }
            );
        }
    );

    public func publishedView(storefront : StorefrontSettings, vaultId : ?Principal) : ?PublishedLayoutView {
        switch (storefront.published) {
            case (?l) ?{
                theme = l.theme;
                home = wire(l.home);
                updatedAt = l.updatedAt;
                vaultId;
            };
            case null null;
        };
    };

    func sameContent(a : StorefrontLayout, b : StorefrontLayout) : Bool {
        a.theme == b.theme and a.home == b.home;
    };

    public func editorState(storefront : StorefrontSettings) : EditorState {
        let draft = switch (storefront.draft) {
            case (?l) ?{
                theme = l.theme;
                home = wire(l.home);
                updatedAt = l.updatedAt;
                updatedBy = l.updatedBy;
            };
            case null null;
        };
        let hasUnpublishedChanges = switch (storefront.draft, storefront.published) {
            case (?d, ?p) not sameContent(d, p);
            case (?_, null) true;
            case (null, _) false;
        };
        {
            draft;
            revision = storefront.revision;
            publishedAt = switch (storefront.published) {
                case (?p) ?p.updatedAt;
                case null null;
            };
            hasUnpublishedChanges;
        };
    };

    // ---- Updates ------------------------------------------------------------------------------------

    func canEdit(authService : AuthService.AuthService, caller : Principal) : Bool {
        not caller.isAnonymous() and AuthService.hasPermission(authService, caller, ShopPermissions.storefrontEdit);
    };

    let unauthorized = "Editing the storefront needs the Storefront.Edit permission";

    public func canReadDraft(authService : AuthService.AuthService, caller : Principal) : Bool = canEdit(authService, caller);

    /// Saves the draft, returning the new revision. Needs `Storefront.Edit` and a signed-in caller, and
    /// `expectedRevision` to match the last revision this editor saw. Nothing changes on any error.
    public func saveDraft(storefront : StorefrontSettings, authService : AuthService.AuthService, caller : Principal, layout : LayoutInput, expectedRevision : Nat) : Result<Nat, SaveDraftError> {
        if (not canEdit(authService, caller)) return #err(#Unauthorized(unauthorized));
        if (expectedRevision != storefront.revision) return #err(#RevisionConflict(storefront.revision));
        let errors = validate(layout);
        if (errors.size() > 0) return #err(#Invalid(errors));
        switch (layout.theme) {
            case (?t) {
                let failures = ShopThemes.contrastFailures(t);
                if (failures.size() > 0) return #err(#ContrastTooLow(failures));
            };
            case null {};
        };
        storefront.draft := ?{
            theme = layout.theme;
            home = layout.home;
            updatedAt = Time.now();
            updatedBy = caller;
        };
        storefront.revision += 1;
        #ok(storefront.revision);
    };

    /// Makes the draft what buyers see, and writes the BRE-171 theme to match. The draft was validated
    /// when it was saved, so it isn't checked again.
    public func publish(storefront : StorefrontSettings, authService : AuthService.AuthService, caller : Principal, expectedRevision : Nat) : Result<(), PublishError> {
        if (not canEdit(authService, caller)) return #err(#Unauthorized(unauthorized));
        if (expectedRevision != storefront.revision) return #err(#RevisionConflict(storefront.revision));
        let draft = switch (storefront.draft) {
            case (?d) d;
            case null return #err(#NoDraft);
        };
        storefront.published := ?{
            draft with updatedAt = Time.now();
            updatedBy = caller;
        };
        let hero = switch (storefront.theme) {
            case (?old) old.hero;
            case null #banner;
        };
        storefront.theme := switch (draft.theme) {
            case (?t) ?toShopTheme(t, hero);
            case null null;
        };
        #ok;
    };

    /// Throws the draft away: it goes back to the published layout (or to none).
    public func discardDraft(storefront : StorefrontSettings, authService : AuthService.AuthService, caller : Principal, expectedRevision : Nat) : Result<Nat, PublishError> {
        if (not canEdit(authService, caller)) return #err(#Unauthorized(unauthorized));
        if (expectedRevision != storefront.revision) return #err(#RevisionConflict(storefront.revision));
        storefront.draft := storefront.published;
        storefront.revision += 1;
        #ok(storefront.revision);
    };
};
