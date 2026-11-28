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
/// own settings (muted types, browser push) and how far they have read. Alerts name principals, so only
/// staff with `Alerts.View` read them, and push text never names one (BRE-211).
///
/// A new alert type is a tag in both `AlertKind` and `AlertType`, a case in `typeOf`, a
/// `record` call where it happens, a case in `pushMessage`, and a line in the frontend's
/// `lib/alerts.ts`.
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
        /// Whether unmuted alerts are also pushed to their browsers through Internet Identity
        /// (BRE-211). Pushes arrive only where they also gave II their consent.
        push : Bool;
    };

    /// What a browser notification for an alert says. Never a principal or an error text: a push
    /// shows on a lock screen, outside `Alerts.View`.
    public type PushMessage = { title : Text; body : Text };

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

    /// How long a pushed alert is still worth delivering: a staff member who is offline overnight
    /// still gets it the next working day, not a week later.
    public let PUSH_LIFETIME : Int = 86_400_000_000_000;

    /// The shortest gap between two pushes of one alert type. Owners can repeat some alerts at will
    /// (re-registering a shop, retrying a failed quote), and each push wakes every opted-in staff
    /// member's devices and costs core a call to II. The feed still records every alert.
    public let PUSH_COOLDOWN : Int = 300_000_000_000;

    /// When each alert type was last pushed, by `pushKey`. Transient in the actor: an upgrade
    /// forgets it, which at worst allows one early push.
    public type PushTimes = Map.Map<Text, Int>;

    public func emptyPushTimes() : PushTimes = Map.empty();

    /// Whether an alert of `alertType` may be pushed at `now`, at most once per `PUSH_COOLDOWN`;
    /// records the push when it may.
    public func takePushTurn(pushTimes : PushTimes, alertType : AlertType, now : Int) : Bool {
        let key = pushKey(alertType);
        switch (pushTimes.get(Text.compare, key)) {
            case (?last) if (now - last < PUSH_COOLDOWN) return false;
            case null {};
        };
        pushTimes.add(Text.compare, key, now);
        true;
    };

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
            case null ({ muted = []; lastSeen = null; push = false });
        };
    };

    /// Sets which types `staff` mutes, keeping how far they have read.
    public func setMuted(state : State, staff : Principal, muted : [AlertType]) {
        let deduped = allTypes.filter(func(t : AlertType) : Bool = muted.any(func(m : AlertType) : Bool = m == t));
        state.settings.add(Principal.compare, staff, { getSettings(state, staff) with muted = deduped });
    };

    /// Turns browser push on or off for `staff`, keeping their other settings.
    public func setPush(state : State, staff : Principal, enabled : Bool) {
        state.settings.add(Principal.compare, staff, { getSettings(state, staff) with push = enabled });
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

    /// Staff to push `alert` to: push on, its type not muted, and still allowed to read alerts
    /// (`canReadAlerts`, so someone who lost `Alerts.View` stops getting them).
    public func pushRecipients(state : State, alert : Alert, canReadAlerts : Principal -> Bool) : [Principal] {
        state.settings.entries().filter(
            func((staff, settings) : (Principal, AlertSettings)) : Bool = settings.push and not mutes(settings, alert) and canReadAlerts(staff)
        ).map(func((staff, _) : (Principal, AlertSettings)) : Principal = staff).toArray();
    };

    /// Whether a notification already queued for `staff` should still be delivered: push on, still
    /// allowed to read alerts, and not for a type they have since muted. `isNotificationOf` says
    /// whether the notification is the one for a given type.
    public func pushWanted(state : State, staff : Principal, canReadAlerts : Bool, isNotificationOf : AlertType -> Bool) : Bool {
        let settings = getSettings(state, staff);
        settings.push and canReadAlerts and not settings.muted.any(isNotificationOf);
    };

    /// The notification key for an alert type: each staff member has one browser notification per
    /// type, which the next alert of that type replaces.
    public func pushKey(alertType : AlertType) : Text {
        "alert-" # (
            switch (alertType) {
                case (#userRegistered) "userRegistered";
                case (#shopCreated) "shopCreated";
                case (#shopRegistered) "shopRegistered";
                case (#shopCreationFailed) "shopCreationFailed";
            }
        );
    };

    public func pushMessage(kind : AlertKind) : PushMessage {
        switch (kind) {
            case (#userRegistered(_)) ({
                title = "New user";
                body = "Someone signed up to the marketplace.";
            });
            case (#shopCreated(_)) ({
                title = "New shop";
                body = "A merchant created a hosted shop.";
            });
            case (#shopRegistered(_)) ({
                title = "Shop registered";
                body = "A shop made outside the paid flow was registered.";
            });
            case (#shopCreationFailed({ quoteId })) ({
                title = "Shop creation failed";
                body = "Quote " # Nat.toText(quoteId) # " is paid but its shop wasn't created.";
            });
        };
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
