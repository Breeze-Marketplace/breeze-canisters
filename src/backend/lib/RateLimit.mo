import Array "mo:core/Array";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Time "mo:core/Time";

/// Fixed-window counters, for capping what callers can make a canister spend (BRE-120).
/// Keep the state in a `transient` field: a reset on upgrade only forgives the current window.
module {
    type Window = { start : Time.Time; used : Nat };

    /// Per-principal counters: each caller gets `limit` units per `windowNanos`.
    public type PerCaller = {
        limit : Nat;
        windowNanos : Int;
        windows : Map.Map<Principal, Window>;
        var lastSweep : Time.Time;
    };

    public func perCaller(limit : Nat, windowNanos : Int) : PerCaller {
        {
            limit;
            windowNanos;
            windows = Map.empty<Principal, Window>();
            var lastSweep = 0;
        };
    };

    /// How many units `caller` has left in the window containing `now`.
    public func remaining(state : PerCaller, caller : Principal, now : Time.Time) : Nat {
        switch (Map.get(state.windows, Principal.compare, caller)) {
            case (?w) {
                if (now - w.start >= state.windowNanos) { state.limit } else if (w.used >= state.limit) {
                    0;
                } else { state.limit - w.used };
            };
            case null state.limit;
        };
    };

    /// Spends `units` from `caller`'s window. False, spending nothing, if fewer are left.
    public func take(state : PerCaller, caller : Principal, units : Nat, now : Time.Time) : Bool {
        if (units > remaining(state, caller, now)) return false;
        sweep(state, now);
        let (start, used) = switch (Map.get(state.windows, Principal.compare, caller)) {
            case (?w) if (now - w.start < state.windowNanos) (w.start, w.used) else (now, 0);
            case null (now, 0);
        };
        Map.add(state.windows, Principal.compare, caller, { start; used = used + units });
        true;
    };

    /// Drops expired windows, at most once per window length, so the map holds only callers who
    /// spent recently and `take` stays cheap.
    func sweep(state : PerCaller, now : Time.Time) {
        if (now - state.lastSweep < state.windowNanos) return;
        state.lastSweep := now;
        let expired = Array.filterMap<(Principal, Window), Principal>(
            Map.toArray(state.windows),
            func((id, w)) = if (now - w.start >= state.windowNanos) ?id else null,
        );
        for (id in expired.vals()) {
            Map.remove(state.windows, Principal.compare, id);
        };
    };

    /// A budget shared by all callers: `limit` units per `windowNanos`.
    public type Global = {
        limit : Nat;
        windowNanos : Int;
        var start : Time.Time;
        var used : Nat;
    };

    public func global(limit : Nat, windowNanos : Int) : Global {
        { limit; windowNanos; var start = 0; var used = 0 };
    };

    /// Spends one unit at `now`; false when the window's budget is spent.
    public func takeGlobal(state : Global, now : Time.Time) : Bool {
        if (now - state.start >= state.windowNanos) {
            state.start := now;
            state.used := 0;
        };
        if (state.used >= state.limit) return false;
        state.used += 1;
        true;
    };
};
