// Music elements for the storefront layout (BRE-198): elements gain `#releases` (a grid, row or list of
// releases) and `#featuredRelease` (one release with its player, tracklist and buy button). Every
// stored layout is valid as it is; the settings record is re-typed because its draft and published
// layouts are `var` fields, whose type must match exactly.
module {
    type ThemeColor = { red : Nat8; green : Nat8; blue : Nat8 };
    type TextTone = { #dark; #light };
    type ShopTheme = {
        primary : ThemeColor;
        onPrimary : TextTone;
        accent : ThemeColor;
        onAccent : TextTone;
        fonts : { #archivoGrotesk; #grotesk; #monoGrotesk; #mono };
        shape : { #sharp; #rounded; #soft };
        colorScheme : { #dark; #light };
        hero : { #banner; #split; #minimal };
    };

    type ProductId = Nat32;

    type AssetKey = Text;

    type Link = {
        #product : ProductId;
        #category : Text;
        #external : Text; // https only
    };

    type TextSource = {
        #literal : Text;
        #shopName;
        #shopDescription;
    };

    type CallToAction = { text : Text; link : Link };

    type TextSpan = {
        text : Text;
        bold : Bool;
        italic : Bool;
        link : ?Link;
    };

    type RichTextNode = {
        #heading : Text;
        #paragraph : [TextSpan];
        #bulletList : [[TextSpan]];
    };

    type ProductSource = {
        #all;
        #category : Text;
        #tag : Text;
        #picked : [ProductId];
    };

    type ProductSort = { #manual; #newest; #priceLowToHigh; #priceHighToLow };

    type ImageSource = {
        #asset : AssetKey;
        #shopBanner;
        #shopLogo;
    };

    type Align = { #start; #center; #end };

    type ReleaseId = Nat32;
    type ReleaseKind = { #Single; #EP; #Album };

    type OldElement = {
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
        #shopInfo : { showDescription : Bool; showLocation : Bool };
        #faq : { entries : [{ question : Text; answer : Text }] };
        #divider;
        #spacer : { size : { #small; #medium; #large } };
    };

    type OldElementNode = { id : Nat; element : OldElement };

    type OldColumn = { span : Nat; elements : [OldElementNode] };

    type OldSection = {
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
        columns : [OldColumn];
    };

    type StorefrontTheme = {
        primary : ThemeColor;
        onPrimary : TextTone;
        accent : ThemeColor;
        onAccent : TextTone;
        fonts : { #archivoGrotesk; #grotesk; #monoGrotesk; #mono };
        shape : { #sharp; #rounded; #soft };
        colorScheme : { #dark; #light };
        density : { #compact; #regular; #airy };
        buttonStyle : { #solid; #outline };
    };

    type OldStorefrontLayout = {
        theme : ?StorefrontTheme; // null: the marketplace's look
        home : [OldSection];
        updatedAt : Int;
        updatedBy : Principal;
    };

    type OldStorefrontSettings = {
        var theme : ?ShopTheme;
        var draft : ?OldStorefrontLayout;
        var published : ?OldStorefrontLayout;
        var revision : Nat;
    };

    type NewElement = {
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
        #shopInfo : { showDescription : Bool; showLocation : Bool };
        #faq : { entries : [{ question : Text; answer : Text }] };
        #divider;
        #spacer : { size : { #small; #medium; #large } };
        #releases : {
            title : ?Text;
            source : {
                #all;
                #kind : ReleaseKind;
                #picked : [ReleaseId];
            };
            sort : { #newest; #manual };
            style : { #grid; #row; #list };
            limit : Nat;
            perRow : Nat;
            showArtist : Bool;
        };
        #featuredRelease : {
            release : { #latest; #picked : ReleaseId };
            tracks : { #all; #first : Nat; #none };
            showBuy : Bool;
        };
    };

    type NewElementNode = { id : Nat; element : NewElement };

    type NewColumn = { span : Nat; elements : [NewElementNode] };

    type NewSection = {
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
        columns : [NewColumn];
    };

    type NewStorefrontLayout = {
        theme : ?StorefrontTheme; // null: the marketplace's look
        home : [NewSection];
        updatedAt : Int;
        updatedBy : Principal;
    };

    type NewStorefrontSettings = {
        var theme : ?ShopTheme;
        var draft : ?NewStorefrontLayout;
        var published : ?NewStorefrontLayout;
        var revision : Nat;
    };

    type OldActor = { storefront : OldStorefrontSettings };
    type NewActor = { storefront : NewStorefrontSettings };

    public func migration(old : OldActor) : NewActor {
        {
            storefront = {
                var theme = old.storefront.theme;
                var draft = old.storefront.draft;
                var published = old.storefront.published;
                var revision = old.storefront.revision;
            };
        };
    };
};
