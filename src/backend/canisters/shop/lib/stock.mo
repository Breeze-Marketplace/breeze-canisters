import Array "mo:core/Array";
import Nat32 "mo:core/Nat32";
import Map "mo:map/Map";

/// Stock held by orders (BRE-167): an unpaid order reserves its units, payment takes them out of
/// stock, and cancelling or expiring the order gives them back. Takes structural inventory and line
/// fields rather than `../types` (which imports `canister:xrc`) so it can run under `mops test`.
module Stock {
    public type Entry = {
        productId : Nat32;
        variantId : Nat32;
        stock : Nat32;
        reserved : Nat32;
        lowStockThreshold : Nat32;
    };

    public type Inventory = Map.Map<Nat32, Entry>;

    public type Line = { variantId : Nat32; quantity : Nat32 };

    /// What an order's status change does to the stock its lines hold.
    public type Change = { #reserve; #sell; #release; #none };

    /// The lines of `lines` that hold stock: `unlimited` names variants that never run out, like a
    /// digital release (BRE-185), whose lines neither reserve nor use up units.
    public func stocked(lines : [Line], unlimited : Nat32 -> Bool) : [Line] {
        lines.filter(func(line : Line) : Bool = not unlimited(line.variantId));
    };

    /// Units of `entry` that no order holds.
    public func available(entry : Entry) : Nat32 {
        if (entry.reserved >= entry.stock) 0 else entry.stock - entry.reserved;
    };

    /// The first variant in `lines` that has fewer units available than the order's lines ask for in
    /// all (a variant may appear on several lines), with what it has; `null` when every one has enough.
    public func firstShortfall(inventory : Inventory, lines : [Line]) : ?{
        variantId : Nat32;
        requested : Nat;
        available : Nat;
    } {
        let requested = Map.new<Nat32, Nat>();
        for (line in lines.vals()) {
            let sofar = switch (Map.get(requested, Map.n32hash, line.variantId)) {
                case (?n) n;
                case null 0;
            };
            Map.set(requested, Map.n32hash, line.variantId, sofar + line.quantity.toNat());
        };
        for ((variantId, quantity) in Map.entries(requested)) {
            let units = switch (Map.get(inventory, Map.n32hash, variantId)) {
                case (?entry) available(entry).toNat();
                case null 0;
            };
            if (quantity > units) return ?{
                variantId;
                requested = quantity;
                available = units;
            };
        };
        null;
    };

    /// The change from an order's previous state (`null` for a new order) to its next one, given
    /// whether each holds stock (awaiting payment) and whether the next is cancelled. An order that
    /// stops holding stock any other way (paid) has sold its units.
    public func change(previousHolds : ?Bool, nextHolds : Bool, nextCanceled : Bool) : Change {
        let held = switch (previousHolds) {
            case (?h) h;
            case null false;
        };
        if (not held and nextHolds) return #reserve;
        if (held and not nextHolds) return if (nextCanceled) #release else #sell;
        #none;
    };

    /// Applies `change` to the variants of `lines`. Saturates at zero rather than trapping, so an order
    /// placed before reservations existed (it holds none) can still be paid or cancelled. A line
    /// whose variant was deleted is skipped.
    public func apply(inventory : Inventory, lines : [Line], change : Change) {
        if (change == #none) return;
        for (line in lines.vals()) {
            switch (Map.get(inventory, Map.n32hash, line.variantId)) {
                case null {};
                case (?entry) {
                    let q = line.quantity;
                    let updated : Entry = switch (change) {
                        case (#reserve) ({
                            entry with reserved = entry.reserved + q
                        });
                        case (#sell) ({
                            entry with stock = minus(entry.stock, q);
                            reserved = minus(entry.reserved, q);
                        });
                        case (#release) ({
                            entry with reserved = minus(entry.reserved, q)
                        });
                        case (#none) entry;
                    };
                    Map.set(inventory, Map.n32hash, line.variantId, updated);
                };
            };
        };
    };

    func minus(a : Nat32, b : Nat32) : Nat32 = if (b >= a) 0 else a - b;
};
