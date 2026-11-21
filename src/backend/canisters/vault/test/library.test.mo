import { expect; suite; test } "mo:test";

import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Assets "mo:assets";

import Folders "../lib/Folders";
import Move "../lib/Move";

let vault = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");

func showOpt(t : ?Text) : Text = switch t { case (?v) v; case null "null" };

func folderErr(r : { #ok : Text; #err : Folders.Error }) : Text = switch r {
    case (#ok(_)) "ok";
    case (#err(e)) Folders.errorMessage(e);
};

func deleteErr(r : { #ok; #err : Folders.Error }) : Text = switch r {
    case (#ok) "ok";
    case (#err(e)) Folders.errorMessage(e);
};

func moveErr(r : { #ok; #err : Move.Error }) : Text = switch r {
    case (#ok) "ok";
    case (#err(e)) Move.errorMessage(e);
};

func storeWith(keys : [Text]) : Assets.Assets {
    let assets = Assets.Assets({ serializedEntries = ([], [vault]) });
    for (key in keys.values()) {
        assets.store({
            caller = vault;
            arg = {
                key;
                content_type = "text/plain";
                content_encoding = "identity";
                content = key.encodeUtf8();
                sha256 = null;
            };
        });
    };
    assets;
};

func contentOf(assets : Assets.Assets, key : Text) : ?Text {
    switch (assets.assets.get(key)) {
        case null null;
        case (?_) assets.retrieve(key).decodeUtf8();
    };
};

suite(
    "Folders.normalize",
    func() {
        test(
            "trims surrounding slashes",
            func() {
                expect.text(showOpt(Folders.normalize("/docs/contracts/"))).equal("docs/contracts");
            },
        );
        test(
            "refuses empty, dot and unservable paths",
            func() {
                for (bad in ["", "/", "a//b", "a/./b", "../a", "a?b", "a#b", "a%20b", "a\\b", "caf\u{e9}", "a\tb"].values()) {
                    expect.text(showOpt(Folders.normalize(bad))).equal("null");
                };
            },
        );
        test(
            "refuses paths deeper than the limit",
            func() {
                var deep = "a";
                for (_ in Nat.range(0, Folders.maxDepth)) { deep #= "/a" };
                expect.text(showOpt(Folders.normalize(deep))).equal("null");
            },
        );
    },
);

suite(
    "Folders.libraryPath",
    func() {
        test(
            "drops the visibility prefix, or the leading slash for older keys",
            func() {
                expect.text(Folders.libraryPath("/private/docs/a.pdf")).equal("docs/a.pdf");
                expect.text(Folders.libraryPath("/public/docs/b.png")).equal("docs/b.png");
                expect.text(Folders.libraryPath("/images/logo.png")).equal("images/logo.png");
            },
        );
    },
);

suite(
    "Folders.create and delete",
    func() {
        test(
            "creating a folder creates the folders above it",
            func() {
                let folders = Set.empty<Text>();
                expect.text(folderErr(Folders.create(folders, "docs/contracts/2026"))).equal("ok");
                expect.bool(folders.contains(Text.compare, "docs")).isTrue();
                expect.bool(folders.contains(Text.compare, "docs/contracts")).isTrue();
                expect.bool(folders.contains(Text.compare, "docs/contracts/2026")).isTrue();
                expect.nat(folders.size()).equal(3);
            },
        );
        test(
            "refuses to delete a folder holding a folder or a file",
            func() {
                let folders = Set.empty<Text>();
                ignore Folders.create(folders, "docs/contracts");
                expect.text(deleteErr(Folders.delete(folders, [].values(), "docs"))).equal("folder isn't empty");
                expect.text(deleteErr(Folders.delete(folders, ["/private/docs/contracts/a.pdf"].values(), "docs/contracts"))).equal("folder isn't empty");
                expect.text(deleteErr(Folders.delete(folders, ["/public/docs/contractsX.pdf"].values(), "docs/contracts"))).equal("ok");
                expect.text(deleteErr(Folders.delete(folders, [].values(), "docs"))).equal("ok");
                expect.nat(folders.size()).equal(0);
            },
        );
    },
);

suite(
    "Move.moveAsset",
    func() {
        test(
            "files the content under the new key and removes the old one",
            func() {
                let assets = storeWith(["/private/docs/a.pdf"]);
                expect.text(moveErr(Move.moveAsset(assets, "/private/docs/a.pdf", "/public/docs/a.pdf"))).equal("ok");
                expect.text(showOpt(contentOf(assets, "/public/docs/a.pdf"))).equal("/private/docs/a.pdf");
                expect.text(showOpt(contentOf(assets, "/private/docs/a.pdf"))).equal("null");
            },
        );
        test(
            "refuses to replace an existing asset",
            func() {
                let assets = storeWith(["/private/a", "/public/a"]);
                expect.text(moveErr(Move.moveAsset(assets, "/private/a", "/public/a"))).equal("an asset already has that key");
                expect.text(showOpt(contentOf(assets, "/private/a"))).equal("/private/a");
            },
        );
        test(
            "refuses a missing source and keys HTTP can't serve",
            func() {
                let assets = storeWith(["/private/a"]);
                expect.text(moveErr(Move.moveAsset(assets, "/private/missing", "/public/b"))).equal("asset not found");
                for (bad in ["public/b", "/", "/b?x", "/b#x", "/b%41", "/caf\u{e9}.png"].values()) {
                    expect.text(moveErr(Move.moveAsset(assets, "/private/a", bad))).equal("invalid asset key");
                };
            },
        );
    },
);
