import Array "mo:core/Array";
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import Set "mo:core/Set";
import Text "mo:core/Text";

import Move "Move";

/// The media library's folders. A folder is a path such as `docs/contracts`, the same for private and
/// public files: `/private/docs/contracts/a.pdf` and `/public/docs/contracts/b.png` are both in it.
/// Files' keys imply their folders; this set keeps the ones created while empty.
module {
    public type Folders = Set.Set<Text>;

    public let maxFolders = 10_000;
    public let maxPathLength = 256;
    public let maxDepth = 16;

    public type Error = {
        #invalidPath;
        #tooMany;
        #notEmpty;
    };

    public func errorMessage(error : Error) : Text = switch error {
        case (#invalidPath) "invalid folder path";
        case (#tooMany) "too many folders";
        case (#notEmpty) "folder isn't empty";
    };

    /// The folder path for `path` with surrounding slashes trimmed, or null when it is empty, too long
    /// or too deep, has an empty, `.` or `..` segment, or has a character a URL path can't carry as is.
    /// Only printable ASCII: `mo:assets` decodes a URL's `%XX` escapes byte by byte, not as UTF-8, so
    /// a key with `é` in it couldn't be served or matched to a ticket.
    public func normalize(path : Text) : ?Text {
        let trimmed = path.trim(#char '/');
        if (trimmed.size() == 0 or trimmed.size() > maxPathLength) return null;
        var depth = 0;
        for (segment in trimmed.split(#char '/')) {
            if (segment.size() == 0 or segment == "." or segment == "..") return null;
            depth += 1;
        };
        if (depth > maxDepth) return null;
        for (c in trimmed.chars()) {
            if (not Move.isUrlSafeChar(c) or c == '\\') return null;
        };
        ?trimmed;
    };

    /// The library path of an asset key: the key without its `/private/` or `/public/` prefix, or
    /// without its leading slash for keys from before the library (`/images/…`).
    public func libraryPath(key : Text) : Text {
        for (prefix in ["/private/", "/public/"].values()) {
            switch (key.stripStart(#text prefix)) {
                case (?rest) return rest;
                case null {};
            };
        };
        key.trimStart(#char '/');
    };

    /// Adds `path` and every folder above it.
    public func create(folders : Folders, path : Text) : {
        #ok : Text;
        #err : Error;
    } {
        let ?folder = normalize(path) else return #err(#invalidPath);
        let ancestors = withAncestors(folder);
        let added = ancestors.filter(func f = not folders.contains(Text.compare, f)).size();
        if (folders.size() + added > maxFolders) return #err(#tooMany);
        for (f in ancestors.values()) {
            folders.add(Text.compare, f);
        };
        #ok(folder);
    };

    /// Removes `path` when no folder or file is inside it. `keys` are every asset's key.
    public func delete(folders : Folders, keys : Iter.Iter<Text>, path : Text) : {
        #ok;
        #err : Error;
    } {
        let ?folder = normalize(path) else return #err(#invalidPath);
        let inside = folder # "/";
        for (f in folders.values()) {
            if (f.startsWith(#text inside)) return #err(#notEmpty);
        };
        for (key in keys) {
            if (libraryPath(key).startsWith(#text inside)) return #err(#notEmpty);
        };
        folders.remove(Text.compare, folder);
        #ok;
    };

    func withAncestors(folder : Text) : [Text] {
        var path = "";
        folder.split(#char '/').map(
            func(segment : Text) : Text {
                path := if (path == "") segment else path # "/" # segment;
                path;
            }
        ).toArray();
    };
};
