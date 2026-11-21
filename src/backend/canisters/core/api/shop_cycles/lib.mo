import Array "mo:core/Array";
import Error "mo:core/Error";
import Int "mo:core/Int";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

/// Cycle balances of shop and vault canisters and how long each has before it freezes (BRE-13).
///
/// Core controls every shop and vault it created, so it reads their `canister_status`: once a day
/// for every registered shop (a timer in `main.mo`), and when a merchant refreshes the shop admin.
/// The burn rate comes from consecutive samples, so it includes message execution and storage, not
/// just the idle burn `canister_status` reports. A sample with more cycles than the one before
/// means a top-up (from the shop admin, the CLI or anyone else), so measuring restarts there.
module {
    public type Sample = {
        /// Nanoseconds since the epoch.
        time : Int;
        cycles : Nat;
    };

    public type Tracker = {
        latest : Sample;
        /// The balance at which the canister freezes, as of the latest sample.
        freezingThresholdCycles : Nat;
        /// The idle burn `canister_status` reported with the latest sample: a lower bound on the
        /// real burn, used until a measured rate exists.
        idleBurnPerDay : Nat;
        /// Where the current measurement started: the sample after the last top-up, or the last
        /// sample a rate was measured from.
        base : Sample;
        /// The measured burn, averaged over measurements. Null until two samples at least
        /// `minMeasureNanos` apart, with no top-up between them.
        measuredBurnPerDay : ?Nat;
    };

    public type State = {
        trackers : Map.Map<Principal, Tracker>;
    };

    public func emptyState() : State {
        { trackers = Map.empty<Principal, Tracker>() };
    };

    /// The subset of `canister_status` this module reads.
    public type RawStatus = {
        cycles : Nat;
        idleCyclesBurnedPerDay : Nat;
        freezingThresholdSeconds : Nat;
    };

    public type ShopCanisterKind = { #shop; #vault };

    public type Runway = {
        cycles : Nat;
        freezingThresholdCycles : Nat;
        /// The measured burn, or the idle burn until one is measured, whichever is higher.
        burnPerDay : Nat;
        /// False while `burnPerDay` is still the idle burn: the real burn is likely higher.
        burnMeasured : Bool;
        /// Whole days until the balance reaches the freezing threshold. 0 when it already has;
        /// null when the canister burns nothing.
        daysLeft : ?Nat;
        /// When the balance was read (nanoseconds since the epoch).
        sampledAt : Int;
    };

    public type CanisterRunway = {
        kind : ShopCanisterKind;
        canisterId : Principal;
        /// The merchant took control of the canister (BRE-79): core can no longer read its status,
        /// so `runway` is null. Anyone can still top it up through the CMC.
        selfManaged : Bool;
        /// Null until core has read the canister's status once, and for a self-managed canister.
        runway : ?Runway;
    };

    let secondsPerDay = 86_400;
    let nanosPerDay : Nat = 86_400_000_000_000;

    /// How often core samples every shop and vault (daily).
    public let sampleIntervalSeconds = 86_400;

    /// Canister status reads one user may make core do through `refreshShopCycles` per hour: 10 shops
    /// and their vaults (BRE-120).
    public let refreshReadsPerHour = 20;

    /// Two samples closer together than this don't yield a rate: the balance moves too little in a
    /// few minutes to measure (12 hours).
    public let minMeasureNanos : Nat = 43_200_000_000_000;

    /// A refresh reads a canister's status only when its latest sample is older than this (5
    /// minutes). It bounds the `canister_status` calls outside callers can make core pay for.
    public let refreshIntervalNanos : Nat = 300_000_000_000;

    /// Under this many days left, the shop admin warns the merchant.
    public let lowRunwayDays = 30;

    public func freezingThresholdCycles(idleBurnPerDay : Nat, thresholdSeconds : Nat) : Nat {
        idleBurnPerDay * thresholdSeconds / secondsPerDay;
    };

    func elapsed(from : Int, to : Int) : Nat {
        if (to > from) Int.abs(to - from) else 0;
    };

    /// Records a status read at `now`.
    public func record(state : State, canisterId : Principal, raw : RawStatus, now : Int) {
        let sample = { time = now; cycles = raw.cycles };
        let freezing = freezingThresholdCycles(raw.idleCyclesBurnedPerDay, raw.freezingThresholdSeconds);
        let tracker : Tracker = switch (Map.get(state.trackers, Principal.compare, canisterId)) {
            case null {
                {
                    latest = sample;
                    freezingThresholdCycles = freezing;
                    idleBurnPerDay = raw.idleCyclesBurnedPerDay;
                    base = sample;
                    measuredBurnPerDay = null;
                };
            };
            case (?prev) {
                let (base, measured) = if (raw.cycles > prev.latest.cycles) {
                    // Topped up since the last sample: start measuring again from here.
                    (sample, prev.measuredBurnPerDay);
                } else {
                    let span = elapsed(prev.base.time, now);
                    if (span < minMeasureNanos) {
                        (prev.base, prev.measuredBurnPerDay);
                    } else {
                        let burned : Nat = if (prev.base.cycles > raw.cycles) prev.base.cycles - raw.cycles else 0;
                        let rate = burned * nanosPerDay / span;
                        let averaged = switch (prev.measuredBurnPerDay) {
                            case null rate;
                            case (?old) (old + rate) / 2;
                        };
                        (sample, ?averaged);
                    };
                };
                {
                    latest = sample;
                    freezingThresholdCycles = freezing;
                    idleBurnPerDay = raw.idleCyclesBurnedPerDay;
                    base;
                    measuredBurnPerDay = measured;
                };
            };
        };
        Map.add(state.trackers, Principal.compare, canisterId, tracker);
    };

    public func runway(tracker : Tracker) : Runway {
        let (burnPerDay, burnMeasured) = switch (tracker.measuredBurnPerDay) {
            case (?m) if (m >= tracker.idleBurnPerDay) (m, true) else (tracker.idleBurnPerDay, true);
            case null (tracker.idleBurnPerDay, false);
        };
        let cycles = tracker.latest.cycles;
        let daysLeft : ?Nat = if (cycles <= tracker.freezingThresholdCycles) ?0 else if (burnPerDay == 0) null else ?((cycles - tracker.freezingThresholdCycles : Nat) / burnPerDay);
        {
            cycles;
            freezingThresholdCycles = tracker.freezingThresholdCycles;
            burnPerDay;
            burnMeasured;
            daysLeft;
            sampledAt = tracker.latest.time;
        };
    };

    public func get(state : State, kind : ShopCanisterKind, canisterId : Principal, selfManaged : Bool) : CanisterRunway {
        {
            kind;
            canisterId;
            selfManaged;
            runway = if (selfManaged) null else switch (Map.get(state.trackers, Principal.compare, canisterId)) {
                case null null;
                case (?t) ?runway(t);
            };
        };
    };

    /// Whether a refresh should read `canisterId`'s status again (see `refreshIntervalNanos`).
    public func isStale(state : State, canisterId : Principal, now : Int) : Bool {
        switch (Map.get(state.trackers, Principal.compare, canisterId)) {
            case null true;
            case (?t) elapsed(t.latest.time, now) >= refreshIntervalNanos;
        };
    };

    /// Forgets a canister that is no longer a shop or vault.
    public func forget(state : State, canisterId : Principal) {
        Map.remove(state.trackers, Principal.compare, canisterId);
    };

    public type Operations = {
        /// canister_status of each of `canisterIds` (canisters core controls), in order, or why it
        /// failed. `sample` passes at most `batchSize`; an implementation should send every call
        /// before awaiting any, and directly rather than through local `async` functions (which
        /// are self-calls).
        canisterStatuses : ([Principal]) -> async* [Result<RawStatus, Text>];
        now : () -> Int;
    };

    /// How many status calls `sample` has in flight at once. Every call in flight holds a
    /// prepayment of core's cycles (about 60B on mainnet), and too many at once leave too few for
    /// the next call (BRE-109).
    public let batchSize = 4;

    /// Reads and records the status of each of `canisterIds`, `batchSize` at a time. Returns the
    /// failures, as (canister, message). One canister failing doesn't stop the rest.
    public func sample(state : State, ops : Operations, canisterIds : [Principal]) : async* [(Principal, Text)] {
        let failures = List.empty<(Principal, Text)>();
        var start = 0;
        while (start < canisterIds.size()) {
            let batch = canisterIds.sliceToArray(start, Nat.min(start + batchSize, canisterIds.size()));
            let statuses = await* ops.canisterStatuses(batch);
            for (i in batch.keys()) {
                switch (statuses[i]) {
                    case (#ok(raw)) record(state, batch[i], raw, ops.now());
                    case (#err(msg)) List.add(failures, (batch[i], msg));
                };
            };
            start += batch.size();
        };
        List.toArray(failures);
    };

    type ManagementStatusResult = {
        cycles : Nat;
        idle_cycles_burned_per_day : Nat;
        settings : { freezing_threshold : Nat };
    };

    type ManagementStatus = actor {
        canister_status : ({ canister_id : Principal }) -> async ManagementStatusResult;
    };

    /// Seconds before a bounded-wait status call gives up, so a slow call can't block core's
    /// upgrades.
    let callTimeoutSeconds : Nat32 = 30;

    public func managementOperations(now : () -> Int) : Operations {
        let ic = actor "aaaaa-aa" : ManagementStatus;
        {
            canisterStatuses = func(canisterIds : [Principal]) : async* [Result<RawStatus, Text>] {
                let calls = List.empty<Result<async ManagementStatusResult, Text>>();
                for (canisterId in canisterIds.vals()) {
                    calls.add(
                        try {
                            #ok((with timeout = callTimeoutSeconds) ic.canister_status({ canister_id = canisterId }));
                        } catch (e) { #err(Error.message(e)) }
                    );
                };
                let statuses = List.empty<Result<RawStatus, Text>>();
                for (call in calls.values()) {
                    statuses.add(
                        switch (call) {
                            case (#ok(call)) {
                                try {
                                    let status = await call;
                                    #ok({
                                        cycles = status.cycles;
                                        idleCyclesBurnedPerDay = status.idle_cycles_burned_per_day;
                                        freezingThresholdSeconds = status.settings.freezing_threshold;
                                    });
                                } catch (e) { #err(Error.message(e)) };
                            };
                            case (#err(msg)) #err(msg);
                        }
                    );
                };
                statuses.toArray();
            };
            now;
        };
    };
};
