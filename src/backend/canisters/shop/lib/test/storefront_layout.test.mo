import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import Layouts "../storefront_layout";
import ShopPermissions "../permissions";
import Fixtures "fixtures";
import {
    type Column;
    type Element;
    type LayoutInput;
    type Section;
    type StorefrontSettings;
    type StorefrontTheme;
    type ValidationError;
} "../storefront_layout";

let owner = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
let designer = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let catalogManager = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
let stranger = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");

let edgeTheme : StorefrontTheme = {
    primary = { red = 194; green = 248; blue = 61 };
    onPrimary = #dark;
    accent = { red = 220; green = 255; blue = 120 };
    onAccent = #dark;
    fonts = #archivoGrotesk;
    shape = #sharp;
    colorScheme = #dark;
    density = #regular;
    buttonStyle = #solid;
};

let heading : Element = #heading({
    text = #shopName;
    level = #h1;
    align = #start;
});
let grid : Element = #products({
    title = ?"All products";
    source = #all;
    sort = #newest;
    limit = 24;
    perRow = 4;
    showCategoryFilter = true;
});

/// Ids for tests: elements count up from 2, sections from 1002, so they never clash.
var nextId = 1;
func fresh() : Nat {
    nextId += 1;
    nextId;
};

func column(span : Nat, elements : [Element]) : Column = {
    span;
    elements = elements.map(func e = { id = fresh(); element = e });
};

func section(columns : [Column]) : Section = {
    id = 1000 + fresh();
    background = #none;
    padding = #medium;
    width = #contained;
    verticalAlign = #start;
    columns;
};

/// One section, one full-width column holding `elements`.
func single(elements : [Element]) : Section = section([column(12, elements)]);

func layoutOf(sections : [Section]) : LayoutInput = {
    theme = ?edgeTheme;
    home = sections;
};

func newStorefront() : StorefrontSettings = {
    var theme = null;
    var draft = null;
    var published = null;
    var revision = 0;
};

func kinds(errors : [ValidationError]) : [Text] {
    errors.map(
        func e = switch (e) {
            case (#TooManySections(_)) "TooManySections";
            case (#TooManyElements(_)) "TooManyElements";
            case (#DuplicateId(_)) "DuplicateId";
            case (#ColumnsTooWide(_)) "ColumnsTooWide";
            case (#TextTooLong(_)) "TextTooLong";
            case (#EmptyText(_)) "EmptyText";
            case (#TooManyItems(_)) "TooManyItems";
            case (#OutOfRange(_)) "OutOfRange";
            case (#InvalidLink(_)) "InvalidLink";
            case (#InvalidImage(_)) "InvalidImage";
            case (#LayoutTooLarge(_)) "LayoutTooLarge";
        }
    );
};

func texts(actual : [Text]) : { equal : [Text] -> () } {
    {
        equal = func(expected : [Text]) = expect.array(actual, func(t : Text) : Text = t, func(a : Text, b : Text) : Bool = a == b).equal(expected);
    };
};

func errorsOf(sections : [Section]) : [Text] = kinds(Layouts.validate(layoutOf(sections)));
func errorsOfElements(elements : [Element]) : [Text] = errorsOf([single(elements)]);

func saveError(r : { #ok : Nat; #err : Layouts.SaveDraftError }) : Text {
    switch (r) {
        case (#ok(_)) "ok";
        case (#err(#Unauthorized(_))) "Unauthorized";
        case (#err(#RevisionConflict(_))) "RevisionConflict";
        case (#err(#Invalid(_))) "Invalid";
        case (#err(#ContrastTooLow(_))) "ContrastTooLow";
    };
};

func publishError(r : { #ok; #err : Layouts.PublishError }) : Text {
    switch (r) {
        case (#ok) "ok";
        case (#err(#Unauthorized(_))) "Unauthorized";
        case (#err(#RevisionConflict(_))) "RevisionConflict";
        case (#err(#NoDraft)) "NoDraft";
    };
};

func long(n : Nat) : Text = Array.repeat<Text>("a", n).values().join("");

suite(
    "validate",
    func() {
        test(
            "accepts every element type, in sections with columns and backgrounds",
            func() {
                let hero : Section = {
                    section([column(6, [#image({ source = #shopBanner; alt = ""; aspect = #wide; link = null })]), column(6, [heading, #shopInfo({ showDescription = true; showLocation = true }), #button({ text = "Shop tees"; link = #category("Tees"); style = #primary; align = #start })])]) with
                    background = #image(#asset("/public/banners/summer.png"));
                    width = #full;
                };
                let body = single([
                    #text({
                        content = [#heading("About us"), #paragraph([{ text = "Hand-printed in "; bold = false; italic = false; link = null }, { text = "Lisbon"; bold = true; italic = false; link = ?#external("https://example.com/lisbon") }]), #bulletList([[{ text = "Organic cotton"; bold = false; italic = false; link = null }]])];
                        align = #start;
                    }),
                    #products({
                        title = ?"Picks";
                        source = #picked([1, 2, 3]);
                        sort = #manual;
                        limit = 3;
                        perRow = 3;
                        showCategoryFilter = false;
                    }),
                    grid,
                    #faq({
                        entries = [{
                            question = "Do you ship abroad?";
                            answer = "Yes, worldwide.";
                        }];
                    }),
                    #divider,
                    #spacer({ size = #medium }),
                    #image({
                        source = #asset("/images/studio.jpg");
                        alt = "Our studio";
                        aspect = #square;
                        link = ?#product(7);
                    }),
                ]);
                let music = single([
                    #releases({
                        title = ?"New on the label";
                        source = #kind(#EP);
                        sort = #newest;
                        style = #grid;
                        limit = 10;
                        perRow = 5;
                        showArtist = true;
                    }),
                    #featuredRelease({
                        release = #picked(4);
                        tracks = #first(6);
                        showBuy = true;
                    }),
                ]);
                texts(errorsOf([hero, body, music])).equal([]);
                // Every element kind plus "section".
                expect.nat(Layouts.elementTypes.size()).equal(12);
            },
        );
        test(
            "caps sections, columns, elements per column and in all",
            func() {
                texts(errorsOf(Array.tabulate<Section>(Layouts.Limits.maxSections + 1, func _ = single([heading])))).equal(["TooManySections"]);
                texts(errorsOf(Array.tabulate<Section>(Layouts.Limits.maxSections, func _ = single([heading])))).equal([]);
                texts(errorsOf([section(Array.tabulate<Column>(Layouts.Limits.maxColumns + 1, func _ = column(2, [])))])).equal(["TooManyElements"]);
                texts(errorsOfElements(Array.repeat<Element>(#divider, Layouts.Limits.maxElementsPerColumn + 1))).equal(["TooManyElements"]);
                // Under the per-column cap, over the layout's.
                let full = Array.repeat<Element>(#divider, Layouts.Limits.maxElementsPerColumn);
                let sections = Array.tabulate<Section>(Layouts.Limits.maxElements / Layouts.Limits.maxElementsPerColumn + 1, func _ = single(full));
                texts(errorsOf(sections)).equal(["TooManyElements"]);
            },
        );
        test(
            "columns must fit the 12-column grid, and a section needs one",
            func() {
                texts(errorsOf([section([column(8, []), column(6, [])])])).equal(["ColumnsTooWide"]);
                texts(errorsOf([section([column(0, [])])])).equal(["OutOfRange"]);
                texts(errorsOf([section([])])).equal(["OutOfRange"]);
                texts(errorsOf([section([column(4, []), column(4, []), column(4, [])])])).equal([]);
            },
        );
        test(
            "ids are unique across sections and elements",
            func() {
                let s = single([heading]);
                texts(errorsOf([s, s])).equal(["DuplicateId", "DuplicateId"]);
                let clash : Section = {
                    section([{
                        span = 12;
                        elements = [{ id = 5; element = heading }];
                    }]) with id = 5
                };
                texts(errorsOf([clash])).equal(["DuplicateId"]);
            },
        );
        test(
            "caps text lengths and requires button and FAQ text",
            func() {
                texts(errorsOfElements([#heading({ text = #literal(long(Layouts.Limits.maxShortText + 1)); level = #h2; align = #start })])).equal(["TextTooLong"]);
                texts(errorsOfElements([#faq({ entries = [{ question = " "; answer = "x" }] })])).equal(["EmptyText"]);
                texts(errorsOfElements([#button({ text = ""; link = #product(1); style = #primary; align = #start })])).equal(["EmptyText"]);
            },
        );
        test(
            "caps nested collections and keeps product grids in range",
            func() {
                let ids = Array.tabulate<Nat32>(Layouts.Limits.maxPickedProducts + 1, func i = Nat32.fromNat(i));
                texts(errorsOfElements([#products({ title = null; source = #picked(ids); sort = #manual; limit = 4; perRow = 4; showCategoryFilter = false })])).equal(["TooManyItems"]);
                let entry = { question = "Q"; answer = "A" };
                texts(errorsOfElements([#faq({ entries = Array.repeat(entry, Layouts.Limits.maxFaqEntries + 1) })])).equal(["TooManyItems"]);
                let nodes = Array.repeat<Layouts.RichTextNode>(#heading("x"), Layouts.Limits.maxRichTextNodes + 1);
                texts(errorsOfElements([#text({ content = nodes; align = #start })])).equal(["TooManyItems"]);
                texts(errorsOfElements([#products({ title = null; source = #all; sort = #newest; limit = 0; perRow = 5; showCategoryFilter = false })])).equal(["OutOfRange", "OutOfRange"]);
                texts(errorsOfElements([#products({ title = null; source = #category(""); sort = #newest; limit = 4; perRow = 2; showCategoryFilter = false })])).equal(["EmptyText"]);
            },
        );
        test(
            "caps picked releases and keeps release grids and featured tracklists in range (BRE-198)",
            func() {
                func releases(source : Layouts.ReleaseSource, limit : Nat, perRow : Nat) : [Text] = errorsOfElements([
                    #releases({
                        title = null;
                        source;
                        sort = #manual;
                        style = #row;
                        limit;
                        perRow;
                        showArtist = false;
                    })
                ]);
                let ids = Array.tabulate<Nat32>(Layouts.Limits.maxPickedReleases + 1, func i = Nat32.fromNat(i));
                texts(releases(#picked(ids), 4, 4)).equal(["TooManyItems"]);
                texts(releases(#picked(ids.sliceToArray(0, Layouts.Limits.maxPickedReleases)), 4, 4)).equal([]);
                texts(releases(#all, 0, 0)).equal(["OutOfRange", "OutOfRange"]);
                texts(releases(#all, Layouts.Limits.maxReleases + 1, Layouts.Limits.maxReleasesPerRow + 1)).equal(["OutOfRange", "OutOfRange"]);
                texts(releases(#kind(#Single), Layouts.Limits.maxReleases, Layouts.Limits.maxReleasesPerRow)).equal([]);
                let longTitle : Element = #releases({
                    title = ?long(Layouts.Limits.maxShortText + 1);
                    source = #all;
                    sort = #newest;
                    style = #list;
                    limit = 4;
                    perRow = 4;
                    showArtist = true;
                });
                texts(errorsOfElements([longTitle])).equal(["TextTooLong"]);

                func featured(tracks : Layouts.TrackCount) : [Text] = errorsOfElements([
                    #featuredRelease({
                        release = #latest;
                        tracks;
                        showBuy = false;
                    })
                ]);
                texts(featured(#all)).equal([]);
                texts(featured(#none)).equal([]);
                texts(featured(#first(0))).equal(["OutOfRange"]);
                texts(featured(#first(Layouts.Limits.maxFeaturedTracks))).equal([]);
                texts(featured(#first(Layouts.Limits.maxFeaturedTracks + 1))).equal(["OutOfRange"]);
            },
        );
        test(
            "counts picked releases in the encoded size",
            func() {
                let small = Layouts.sizeOf(layoutOf([single([#releases({ title = null; source = #picked([1]); sort = #manual; style = #grid; limit = 1; perRow = 1; showArtist = true })])]));
                let big = Layouts.sizeOf(layoutOf([single([#releases({ title = null; source = #picked([1, 2, 3, 4]); sort = #manual; style = #grid; limit = 1; perRow = 1; showArtist = true })])]));
                expect.nat(big).greater(small);
            },
        );
        test(
            "allows only https external links",
            func() {
                func withLink(url : Text) : [Text] {
                    errorsOfElements([#button({ text = "Go"; link = #external(url); style = #secondary; align = #center })]);
                };
                texts(withLink("https://example.com")).equal([]);
                texts(withLink("http://example.com")).equal(["InvalidLink"]);
                texts(withLink("javascript:alert(1)")).equal(["InvalidLink"]);
                texts(withLink("https://example.com/a b")).equal(["InvalidLink"]);
            },
        );
        test(
            "allows only the vault's public files as images, in elements and backgrounds",
            func() {
                func withImage(key : Text) : [Text] {
                    errorsOfElements([#image({ source = #asset(key); alt = ""; aspect = #original; link = null })]);
                };
                texts(withImage("/public/products/tee.png")).equal([]);
                texts(withImage("/private/download.zip")).equal(["InvalidImage"]);
                texts(withImage("https://evil.example/x.png")).equal(["InvalidImage"]);
                texts(withImage("/public/../private/x.zip")).equal(["InvalidImage"]);
                let background : Section = {
                    single([]) with background = #image(#asset("/private/x.png"))
                };
                texts(errorsOf([background])).equal(["InvalidImage"]);
            },
        );
        test(
            "caps the encoded size",
            func() {
                let span = {
                    text = long(Layouts.Limits.maxLongText);
                    bold = false;
                    italic = false;
                    link = null;
                };
                let text : Element = #text({
                    content = [#paragraph(Array.repeat(span, Layouts.Limits.maxSpans))];
                    align = #start;
                });
                texts(errorsOfElements(Array.repeat(text, 10))).equal(["LayoutTooLarge"]);
            },
        );
    },
);

suite(
    "saveDraft, publish and discard",
    func() {
        test(
            "a member with Storefront.Edit saves and publishes; buyers see only the published layout",
            func() {
                let auth = Fixtures.newAuthService(owner);
                Fixtures.grantRole(auth, designer, "Designer", [ShopPermissions.storefrontEdit]);
                let storefront = newStorefront();
                storefront.theme := ?Layouts.toShopTheme(edgeTheme, #split);
                expect.text(saveError(Layouts.saveDraft(storefront, auth, designer, layoutOf([single([heading]), single([grid])]), 0))).equal("ok");
                expect.nat(storefront.revision).equal(1);
                expect.bool(Layouts.publishedView(storefront, null) == null).isTrue();
                expect.bool(Layouts.editorState(storefront).hasUnpublishedChanges).isTrue();

                expect.text(publishError(Layouts.publish(storefront, auth, designer, 1))).equal("ok");
                let published = switch (Layouts.publishedView(storefront, null)) {
                    case (?p) p;
                    case null { expect.bool(false).isTrue(); return };
                };
                expect.nat(published.home.size()).equal(2);
                expect.bool(Layouts.editorState(storefront).hasUnpublishedChanges).isFalse();
                // The BRE-171 theme follows, keeping the shop's hero style.
                switch (storefront.theme) {
                    case (?t) expect.bool(t.hero == #split and t.primary == edgeTheme.primary).isTrue();
                    case null expect.bool(false).isTrue();
                };
            },
        );
        test(
            "other members, strangers and the anonymous principal can't save, publish, discard or read the draft",
            func() {
                let auth = Fixtures.newAuthService(owner);
                Fixtures.grantRole(auth, catalogManager, "Catalog", [ShopPermissions.productsEdit, ShopPermissions.settingsEdit]);
                let storefront = newStorefront();
                for (caller in [catalogManager, stranger, Principal.anonymous()].values()) {
                    expect.text(saveError(Layouts.saveDraft(storefront, auth, caller, layoutOf([single([grid])]), 0))).equal("Unauthorized");
                    expect.text(publishError(Layouts.publish(storefront, auth, caller, 0))).equal("Unauthorized");
                    let discarded = switch (Layouts.discardDraft(storefront, auth, caller, 0)) {
                        case (#ok(_)) "ok";
                        case (#err(#Unauthorized(_))) "Unauthorized";
                        case (#err(_)) "other";
                    };
                    expect.text(discarded).equal("Unauthorized");
                    expect.bool(Layouts.canReadDraft(auth, caller)).isFalse();
                };
                expect.bool(Layouts.canReadDraft(auth, owner)).isTrue();
                expect.bool(storefront.draft == null).isTrue();
                expect.nat(storefront.revision).equal(0);
            },
        );
        test(
            "a stale revision is a conflict and changes nothing",
            func() {
                let auth = Fixtures.newAuthService(owner);
                let storefront = newStorefront();
                ignore Layouts.saveDraft(storefront, auth, owner, layoutOf([single([grid])]), 0);
                expect.text(saveError(Layouts.saveDraft(storefront, auth, owner, layoutOf([single([heading]), single([grid])]), 0))).equal("RevisionConflict");
                expect.text(publishError(Layouts.publish(storefront, auth, owner, 0))).equal("RevisionConflict");
                switch (storefront.draft) {
                    case (?d) expect.nat(d.home.size()).equal(1);
                    case null expect.bool(false).isTrue();
                };
                expect.bool(storefront.published == null).isTrue();
            },
        );
        test(
            "an invalid layout or unreadable theme is rejected",
            func() {
                let auth = Fixtures.newAuthService(owner);
                let storefront = newStorefront();
                let bad = layoutOf([single([#faq({ entries = [{ question = ""; answer = "" }] })])]);
                expect.text(saveError(Layouts.saveDraft(storefront, auth, owner, bad, 0))).equal("Invalid");
                let unreadable = {
                    layoutOf([single([grid])]) with theme = ?{
                        edgeTheme with onPrimary = #light
                    }
                };
                expect.text(saveError(Layouts.saveDraft(storefront, auth, owner, unreadable, 0))).equal("ContrastTooLow");
                expect.nat(storefront.revision).equal(0);
                expect.bool(storefront.draft == null).isTrue();
            },
        );
        test(
            "publishing needs a draft; discarding goes back to the published layout",
            func() {
                let auth = Fixtures.newAuthService(owner);
                let storefront = newStorefront();
                expect.text(publishError(Layouts.publish(storefront, auth, owner, 0))).equal("NoDraft");
                ignore Layouts.saveDraft(storefront, auth, owner, layoutOf([single([grid])]), 0);
                ignore Layouts.publish(storefront, auth, owner, 1);
                ignore Layouts.saveDraft(storefront, auth, owner, layoutOf([single([heading]), single([grid])]), 1);
                expect.bool(Layouts.editorState(storefront).hasUnpublishedChanges).isTrue();
                switch (Layouts.discardDraft(storefront, auth, owner, 2)) {
                    case (#ok(revision)) expect.nat(revision).equal(3);
                    case (#err(_)) expect.bool(false).isTrue();
                };
                expect.bool(Layouts.editorState(storefront).hasUnpublishedChanges).isFalse();
                switch (storefront.draft) {
                    case (?d) expect.nat(d.home.size()).equal(1);
                    case null expect.bool(false).isTrue();
                };
            },
        );
        test(
            "publishing a layout with no theme clears the BRE-171 theme",
            func() {
                let auth = Fixtures.newAuthService(owner);
                let storefront = newStorefront();
                storefront.theme := ?Layouts.toShopTheme(edgeTheme, #banner);
                ignore Layouts.saveDraft(storefront, auth, owner, { theme = null; home = [] }, 0);
                ignore Layouts.publish(storefront, auth, owner, 1);
                expect.bool(storefront.theme == null).isTrue();
            },
        );
        test(
            "views wrap every section and element as an option",
            func() {
                let auth = Fixtures.newAuthService(owner);
                let storefront = newStorefront();
                ignore Layouts.saveDraft(storefront, auth, owner, layoutOf([section([column(6, [heading]), column(6, [grid, #divider])])]), 0);
                switch (Layouts.editorState(storefront).draft) {
                    case (?d) switch (d.home[0]) {
                        case (?s) {
                            expect.nat(s.columns.size()).equal(2);
                            expect.nat(s.columns[1].elements.size()).equal(2);
                            expect.bool(s.columns[1].elements[1] != null).isTrue();
                        };
                        case null expect.bool(false).isTrue();
                    };
                    case null expect.bool(false).isTrue();
                };
            },
        );
    },
);
