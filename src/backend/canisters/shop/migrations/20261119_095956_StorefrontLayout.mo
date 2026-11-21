// Adds the storefront's draft and published home page layouts, made of sections and elements (BRE-172),
// and the revision that guards concurrent editors. Every shop starts with neither, so its storefront shows
// the default layout built from its BRE-171 theme until staff publish one; the theme is kept as it is.
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

    type Element = {
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

    type ElementNode = { id : Nat; element : Element };

    type Column = { span : Nat; elements : [ElementNode] };

    type Section = {
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
        columns : [Column];
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

    type StorefrontLayout = {
        theme : ?StorefrontTheme; // null: the marketplace's look
        home : [Section];
        updatedAt : Int;
        updatedBy : Principal;
    };

    type StorefrontSettings = {
        var theme : ?ShopTheme;
        var draft : ?StorefrontLayout;
        var published : ?StorefrontLayout;
        var revision : Nat;
    };

    type OldActor = { storefront : { var theme : ?ShopTheme } };
    type NewActor = { storefront : StorefrontSettings };

    public func migration(old : OldActor) : NewActor {
        {
            storefront = {
                var theme = old.storefront.theme;
                var draft = null;
                var published = null;
                var revision = 0;
            };
        };
    };
};
