import Array "mo:core/Array";
import Iter "mo:core/Iter";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Time "mo:core/Time";

import Pagination "../../../../lib/Pagination";

/// Platform alerts (BRE-210): events staff want to hear about, recorded where they happen, read
/// newest first on `/admin/alerts`. Unlike the marketplace history (an append-only audit of who did
/// what), alerts are a bounded feed: past `MAX_ALERTS` the oldest go. Each staff member keeps their
/// own settings (muted types) and how far they have read. Alerts name principals, so only staff with
/// `Alerts.View` read them.
///
/// A new alert type is a tag in both `AlertKind` and `AlertType`, a case in `typeOf`, a
/// `record` call where it happens, and a line in the frontend's `lib/alerts.ts`.
module {
    public type AlertKind = {
        #userRegistered : { user : Principal };
        #shopCreated : { shop : Principal; owner : Principal };
        /// A shop made outside the paid flow and registered with core (BRE-119).
        #shopRegistered : { shop : Principal; owner : Principal };
        /// A paid quote's shop wasn't created; the quote stays paid for a retry or refund.
        #shopCreationFailed : { quoteId : Nat; owner : Principal; error : Text };
    };

    /// `AlertKind`'s tags, which staff mute by.
    public type AlertType = {
        #userRegistered;
        #shopCreated;
        #shopRegistered;
        #shopCreationFailed;
    };

    public type Alert = { seq : Nat; at : Int; kind : AlertKind };

    /// One staff member's settings. Types are stored muted, so a type added later is on for everyone.
    public type AlertSettings = {
        muted : [AlertType];
        /// The newest alert they have marked read.
        lastSeen : ?Nat;
    };

    public type State = {
        alerts : Map.Map<Nat, Alert>;
        var nextSeq : Nat;
        settings : Map.Map<Principal, AlertSettings>;
    };

    public type AlertSummary = {
        /// Unmuted alerts after `lastSeen`, at most `MAX_UNREAD`.
        unread : Nat;
        /// The newest alert's `seq`, muted or not: pass it to `markSeen`.
        latest : ?Nat;
    };

    /// How many alerts are kept; recording one more drops the oldest.
    public let MAX_ALERTS = 10_000;

    /// `summary` counts no further. It reads at most `MAX_ALERTS` alerts, so muted ones can't hide
    /// older unread ones.
    public let MAX_UNREAD = 100;

    /// The longest error text an alert keeps.
    public let MAX_ERROR_LENGTH = 300;

    public let allTypes : [AlertType] = [
        #userRegistered,
        #shopCreated,
        #shopRegistered,
        #shopCreationFailed,
    ];

    public func empty() : State {
        { alerts = Map.empty(); var nextSeq = 0; settings = Map.empty() };
    };

    public func typeOf(kind : AlertKind) : AlertType {
        switch (kind) {
            case (#userRegistered(_)) #userRegistered;
            case (#shopCreated(_)) #shopCreated;
            case (#shopRegistered(_)) #shopRegistered;
            case (#shopCreationFailed(_)) #shopCreationFailed;
        };
    };

    /// `text` cut to `MAX_ERROR_LENGTH` characters, so an error can't grow an alert without bound.
    public func clip(text : Text) : Text {
        if (text.size() <= MAX_ERROR_LENGTH) return text;
        Text.fromIter(text.chars().take(MAX_ERROR_LENGTH)) # "…";
    };

    public func record(state : State, kind : AlertKind) : Alert {
        let alert = { seq = state.nextSeq; at = Time.now(); kind };
        state.alerts.add(Nat.compare, alert.seq, alert);
        state.nextSeq += 1;
        if (state.alerts.size() > MAX_ALERTS) {
            switch (state.alerts.minEntry()) {
                case (?(oldest, _)) state.alerts.remove(Nat.compare, oldest);
                case null {};
            };
        };
        alert;
    };

    public func getSettings(state : State, staff : Principal) : AlertSettings {
        switch (state.settings.get(Principal.compare, staff)) {
            case (?settings) settings;
            case null ({ muted = []; lastSeen = null });
        };
    };

    /// Sets which types `staff` mutes, keeping how far they have read.
    public func setMuted(state : State, staff : Principal, muted : [AlertType]) {
        let deduped = allTypes.filter(func(t : AlertType) : Bool = muted.any(func(m : AlertType) : Bool = m == t));
        state.settings.add(Principal.compare, staff, { getSettings(state, staff) with muted = deduped });
    };

    /// Marks every alert up to `upTo` read for `staff`. Never moves backwards or past the newest.
    public func markSeen(state : State, staff : Principal, upTo : Nat) {
        if (state.nextSeq == 0) return;
        let capped = Nat.min(upTo, state.nextSeq - 1);
        let settings = getSettings(state, staff);
        let lastSeen = switch (settings.lastSeen) {
            case (?seen) Nat.max(seen, capped);
            case null capped;
        };
        state.settings.add(Principal.compare, staff, { settings with lastSeen = ?lastSeen });
    };

    func mutes(settings : AlertSettings, alert : Alert) : Bool {
        let t = typeOf(alert.kind);
        settings.muted.any(func(m : AlertType) : Bool = m == t);
    };

    /// The alerts `staff` hasn't muted, newest first: pass a page's `next` as `after` for older ones.
    public func page(state : State, staff : Principal, after : ?Nat, limit : ?Nat) : Pagination.Page<Alert, Nat> {
        let settings = getSettings(state, staff);
        let entries = switch (after) {
            case (?seq) state.alerts.reverseEntriesFrom(Nat.compare, seq);
            case null state.alerts.reverseEntries();
        };
        Pagination.scan<(Nat, Alert), Alert, Nat>(
            entries,
            func((seq, _)) = seq,
            Pagination.descending(Nat.compare),
            after,
            func((_, alert)) = if (mutes(settings, alert)) null else ?alert,
            limit,
        );
    };

    public func summary(state : State, staff : Principal) : AlertSummary {
        let settings = getSettings(state, staff);
        let latest = switch (state.alerts.maxEntry()) {
            case (?(seq, _)) ?seq;
            case null null;
        };
        var unread = 0;
        label count for ((seq, alert) in state.alerts.reverseEntries()) {
            switch (settings.lastSeen) {
                case (?seen) if (seq <= seen) break count;
                case null {};
            };
            if (not mutes(settings, alert)) {
                unread += 1;
                if (unread == MAX_UNREAD) break count;
            };
        };
        { unread; latest };
    };
};
