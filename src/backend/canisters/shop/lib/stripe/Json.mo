import Array "mo:core/Array";
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";

/// A small JSON reader for Stripe API responses: enough to pick fields out of an object. Numbers
/// are kept as their source text, so callers decide how to read them (Stripe amounts are integers).
module Json {
    public type Value = {
        #null_;
        #bool : Bool;
        #number : Text;
        #string : Text;
        #array : [Value];
        #object_ : [(Text, Value)];
    };

    /// Deepest nesting accepted, so a hostile body can't exhaust the stack.
    let MAX_DEPTH = 32;

    /// Parses `text` as one JSON value, or null if it isn't valid JSON.
    public func parse(text : Text) : ?Value {
        let chars = Iter.toArray(text.chars());
        let pos = { var i = 0 };
        let ?value = parseValue(chars, pos, 0) else return null;
        skipWhitespace(chars, pos);
        if (pos.i != chars.size()) return null;
        ?value;
    };

    /// The value at `key` in an object, or null if `value` isn't an object or has no such key.
    public func field(value : Value, key : Text) : ?Value {
        let #object_(entries) = value else return null;
        for ((k, v) in entries.values()) {
            if (k == key) return ?v;
        };
        null;
    };

    /// The string at `key`, or null if missing, JSON null or not a string.
    public func text(value : Value, key : Text) : ?Text {
        switch (field(value, key)) {
            case (?#string(s)) ?s;
            case _ null;
        };
    };

    /// The non-negative integer at `key`, or null if missing or not one.
    public func nat(value : Value, key : Text) : ?Nat {
        switch (field(value, key)) {
            case (?#number(n)) Nat.fromText(n);
            case _ null;
        };
    };

    /// The boolean at `key`, or null if missing or not a boolean.
    public func bool(value : Value, key : Text) : ?Bool {
        switch (field(value, key)) {
            case (?#bool(b)) ?b;
            case _ null;
        };
    };

    type Pos = { var i : Nat };

    func skipWhitespace(chars : [Char], pos : Pos) {
        while (pos.i < chars.size() and (chars[pos.i] == ' ' or chars[pos.i] == '\n' or chars[pos.i] == '\r' or chars[pos.i] == '\t')) {
            pos.i += 1;
        };
    };

    func expectWord(chars : [Char], pos : Pos, word : Text) : Bool {
        for (c in word.chars()) {
            if (pos.i >= chars.size() or chars[pos.i] != c) return false;
            pos.i += 1;
        };
        true;
    };

    func parseValue(chars : [Char], pos : Pos, depth : Nat) : ?Value {
        if (depth > MAX_DEPTH) return null;
        skipWhitespace(chars, pos);
        if (pos.i >= chars.size()) return null;
        switch (chars[pos.i]) {
            case '{' parseObject(chars, pos, depth);
            case '[' parseArray(chars, pos, depth);
            case '\"' {
                let ?s = parseString(chars, pos) else return null;
                ?#string(s);
            };
            case 't' if (expectWord(chars, pos, "true")) ?#bool(true) else null;
            case 'f' if (expectWord(chars, pos, "false")) ?#bool(false) else null;
            case 'n' if (expectWord(chars, pos, "null")) ?#null_ else null;
            case _ parseNumber(chars, pos);
        };
    };

    func parseObject(chars : [Char], pos : Pos, depth : Nat) : ?Value {
        pos.i += 1; // '{'
        let entries = List.empty<(Text, Value)>();
        skipWhitespace(chars, pos);
        if (pos.i < chars.size() and chars[pos.i] == '}') {
            pos.i += 1;
            return ?#object_([]);
        };
        loop {
            skipWhitespace(chars, pos);
            if (pos.i >= chars.size() or chars[pos.i] != '\"') return null;
            let ?key = parseString(chars, pos) else return null;
            skipWhitespace(chars, pos);
            if (pos.i >= chars.size() or chars[pos.i] != ':') return null;
            pos.i += 1;
            let ?value = parseValue(chars, pos, depth + 1) else return null;
            List.add(entries, (key, value));
            skipWhitespace(chars, pos);
            if (pos.i >= chars.size()) return null;
            if (chars[pos.i] == '}') {
                pos.i += 1;
                return ?#object_(List.toArray(entries));
            };
            if (chars[pos.i] != ',') return null;
            pos.i += 1;
        };
    };

    func parseArray(chars : [Char], pos : Pos, depth : Nat) : ?Value {
        pos.i += 1; // '['
        let items = List.empty<Value>();
        skipWhitespace(chars, pos);
        if (pos.i < chars.size() and chars[pos.i] == ']') {
            pos.i += 1;
            return ?#array([]);
        };
        loop {
            let ?value = parseValue(chars, pos, depth + 1) else return null;
            List.add(items, value);
            skipWhitespace(chars, pos);
            if (pos.i >= chars.size()) return null;
            if (chars[pos.i] == ']') {
                pos.i += 1;
                return ?#array(List.toArray(items));
            };
            if (chars[pos.i] != ',') return null;
            pos.i += 1;
        };
    };

    func parseNumber(chars : [Char], pos : Pos) : ?Value {
        let start = pos.i;
        while (pos.i < chars.size() and isNumberChar(chars[pos.i])) {
            pos.i += 1;
        };
        if (pos.i == start) return null;
        ?#number(Text.fromIter(Iter.fromArray(chars.sliceToArray(start, pos.i))));
    };

    func isNumberChar(c : Char) : Bool {
        Char.isDigit(c) or c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E';
    };

    func parseString(chars : [Char], pos : Pos) : ?Text {
        pos.i += 1; // opening quote
        var out = "";
        while (pos.i < chars.size()) {
            let c = chars[pos.i];
            pos.i += 1;
            if (c == '\"') return ?out;
            if (c != '\\') {
                out #= Char.toText(c);
            } else {
                if (pos.i >= chars.size()) return null;
                let e = chars[pos.i];
                pos.i += 1;
                switch (e) {
                    case '\"' out #= "\"";
                    case '\\' out #= "\\";
                    case '/' out #= "/";
                    case 'b' out #= "\u{08}";
                    case 'f' out #= "\u{0C}";
                    case 'n' out #= "\n";
                    case 'r' out #= "\r";
                    case 't' out #= "\t";
                    case 'u' {
                        let ?unit = parseHex4(chars, pos) else return null;
                        let codePoint : Nat32 = if (unit >= 0xD800 and unit <= 0xDBFF) {
                            // A high surrogate must be followed by `\u` and a low surrogate.
                            if (not expectWord(chars, pos, "\\u")) return null;
                            let ?low = parseHex4(chars, pos) else return null;
                            if (low < 0xDC00 or low > 0xDFFF) return null;
                            0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
                        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
                            return null;
                        } else unit;
                        out #= Char.toText(Char.fromNat32(codePoint));
                    };
                    case _ return null;
                };
            };
        };
        null;
    };

    func parseHex4(chars : [Char], pos : Pos) : ?Nat32 {
        if (pos.i + 4 > chars.size()) return null;
        var n : Nat32 = 0;
        for (k in Nat.range(0, 4)) {
            let ?d = hexDigit(chars[pos.i + k]) else return null;
            n := n * 16 + d;
        };
        pos.i += 4;
        ?n;
    };

    func hexDigit(c : Char) : ?Nat32 {
        let n = Char.toNat32(c);
        if (c >= '0' and c <= '9') ?(n - 0x30) else if (c >= 'a' and c <= 'f') ?(n - 0x57) else if (c >= 'A' and c <= 'F') ?(n - 0x37) else null;
    };
};
