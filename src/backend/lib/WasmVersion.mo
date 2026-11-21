import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Order "mo:core/Order";

/// Names and versions of the wasm modules canister_factory stores, shared by the factory and core
/// (BRE-85). A version is the Unix time in seconds when the factory stored the wasm, so versions
/// order by upload time. The factory assigns it on upload and keeps it strictly increasing per name.
///
/// Whether two versions are compatible is a separate number, the interface: the factory raises it
/// when an upload is marked breaking (see `WasmStore`).
module {
    public type WasmName = { #shop; #vault };

    /// Seconds since the Unix epoch.
    public type Version = Nat;

    public func compare(a : Version, b : Version) : Order.Order {
        Nat.compare(a, b);
    };

    public func equal(a : Version, b : Version) : Bool {
        a == b;
    };

    public func compareName(a : WasmName, b : WasmName) : Order.Order {
        func rank(n : WasmName) : Nat = switch (n) {
            case (#shop) { 0 };
            case (#vault) { 1 };
        };
        Nat.compare(rank(a), rank(b));
    };

    public func nameText(name : WasmName) : Text {
        switch (name) {
            case (#shop) { "shop" };
            case (#vault) { "vault" };
        };
    };

    public func toText(v : Version) : Text {
        Nat.toText(v);
    };

    /// `name@version`, for map keys and logs.
    public func key(name : WasmName, v : Version) : Text {
        nameText(name) # "@" # toText(v);
    };

    /// The version of an upload at `now` (nanoseconds since the epoch) after `latest` (null: nothing
    /// uploaded yet). Two uploads within a second still get different versions.
    public func next(latest : ?Version, now : Int) : Version {
        let seconds = Int.abs(now) / 1_000_000_000;
        switch (latest) {
            case (null) { seconds };
            case (?v) { Nat.max(seconds, v + 1) };
        };
    };
};
