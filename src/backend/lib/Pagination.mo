import Array "mo:core/Array";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import { type Order } "mo:core/Order";

/// Cursor pagination for list queries. A page holds up to `limit` items and, when more remain, the
/// cursor of its last item: pass it back as `after` to get the next page. Cursors are the items' own
/// sort keys, so a page stays correct when items are added or removed between calls, including the
/// item a cursor names.
module {
    public let DEFAULT_LIMIT = 50;
    public let MAX_LIMIT = 200;

    public type Page<T, C> = {
        items : [T];
        /// The cursor to pass as `after` for the next page; null on the last page.
        next : ?C;
    };

    /// `limit`, or `DEFAULT_LIMIT` when null, clamped to 1..`MAX_LIMIT`.
    public func clampLimit(limit : ?Nat) : Nat {
        switch (limit) {
            case null { DEFAULT_LIMIT };
            case (?n) { Nat.max(1, Nat.min(n, MAX_LIMIT)) };
        };
    };

    /// The first `limit` items of `items`, which must already start after the cursor.
    public func take<T, C>(items : Iter.Iter<T>, limit : ?Nat, cursorOf : T -> C) : Page<T, C> {
        let n = clampLimit(limit);
        let out = List.empty<T>();
        label fill while (out.size() < n) {
            switch (items.next()) {
                case (?item) { out.add(item) };
                case null { break fill };
            };
        };
        let next = if (out.size() < n) { null } else {
            switch (items.next(), out.last()) {
                case (?_, ?last) { ?cursorOf(last) };
                case _ { null };
            };
        };
        { items = out.toArray(); next };
    };

    /// How many entries `scan` may pass over without keeping them, beyond the page itself, before it
    /// returns a short page.
    public let MAX_SKIPPED = 1_000;

    /// A page read from `entries`, which must be in ascending `compare` order of their cursors and start
    /// at or after `after` (an ordered map's `entriesFrom` the cursor, say): entries whose cursor is not
    /// after `after` are dropped. `keep` turns an entry into an item, or null to skip it (a hidden
    /// product, say). The work is bounded by the page size: after `MAX_SKIPPED` skipped entries the page
    /// ends early, with `next` pointing at the last entry looked at. So a page can hold fewer than
    /// `limit` items, or none, and still have a `next`; and `next` can lead to an empty last page.
    public func scan<E, T, C>(
        entries : Iter.Iter<E>,
        cursorOf : E -> C,
        compare : (C, C) -> Order,
        after : ?C,
        keep : E -> ?T,
        limit : ?Nat,
    ) : Page<T, C> {
        let n = clampLimit(limit);
        let out = List.empty<T>();
        var skipped = 0;
        var last : ?C = null;
        loop {
            let ?e = entries.next() else return {
                items = out.toArray();
                next = null;
            };
            let c = cursorOf(e);
            let isAfter = switch (after) {
                case (?a) { compare(c, a) == #greater };
                case null { true };
            };
            if (isAfter) {
                if (out.size() == n) {
                    // A further entry exists, though `keep` may yet skip it.
                    return { items = out.toArray(); next = last };
                };
                switch (keep(e)) {
                    case (?item) { out.add(item) };
                    case null {
                        skipped += 1;
                        if (skipped > MAX_SKIPPED) {
                            return { items = out.toArray(); next = ?c };
                        };
                    };
                };
                last := ?c;
            };
        };
    };

    /// The page of `items` after `after`, ordered by `compare` on their cursors, which must be
    /// unique. Sorts a copy of `items`, so it costs O(N log N) in the whole collection: use `scan` over
    /// an ordered index for anything that grows with the marketplace (BRE-96). Pass cheap keys and `map`
    /// the page when items are costly to build.
    public func page<T, C>(items : [T], cursorOf : T -> C, compare : (C, C) -> Order, after : ?C, limit : ?Nat) : Page<T, C> {
        let sorted = items.sort(func(a, b) = compare(cursorOf(a), cursorOf(b)));
        let start = switch (after) {
            case null { 0 };
            case (?c) { firstAfter(sorted, cursorOf, compare, c) };
        };
        take(sorted.sliceToArray(start, sorted.size()).values(), limit, cursorOf);
    };

    /// Index of the first item of `sorted` whose cursor is after `c` (`sorted.size()` if none).
    func firstAfter<T, C>(sorted : [T], cursorOf : T -> C, compare : (C, C) -> Order, c : C) : Nat {
        var lo = 0;
        var hi = sorted.size();
        while (lo < hi) {
            let mid = (lo + hi) / 2;
            if (compare(cursorOf(sorted[mid]), c) == #greater) { hi := mid } else {
                lo := mid + 1;
            };
        };
        lo;
    };

    public func map<T, U, C>(p : Page<T, C>, f : T -> U) : Page<U, C> {
        { items = Array.map(p.items, f); next = p.next };
    };

    /// `compare` reversed, for pages in descending order.
    public func descending<C>(compare : (C, C) -> Order) : (C, C) -> Order {
        func(a, b) = compare(b, a);
    };
};
