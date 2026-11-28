import Array "mo:core/Array";
import Int "mo:core/Int";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Set "mo:core/Set";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import CallerInfo "../lib/notifications/Internal/CallerInfo";
import Config "../lib/notifications/Internal/Config";
import Flush "../lib/notifications/Internal/Flush";
import Ids "../lib/notifications/Internal/Ids";
import II "../lib/notifications/Internal/II";
import Metrics "../lib/notifications/Internal/Metrics";
import NotificationState "../lib/notifications/State";
import Origin "../lib/notifications/Internal/Origin";
import Outbox "../lib/notifications/Internal/Outbox";
import Types "../lib/notifications/Types";

/// Notify Internet Identity users: browser notifications, delivered by II to the devices where
/// the user gave consent (BRE-211). Vendored from `identity-notifications` 0.3.2 (see
/// `lib/notifications/README.md` for what differs).
///
/// Configured by environment variables: `notification_sender` (the II canister),
/// `notification_origin` (the frontend's primary origin, which must list core in its
/// `/.well-known/ii-notification-senders`), and optionally `notification_capacity_mb`.
///
/// The three `_internet_identity_notification_*` methods are called by II, not by people: each
/// answers only a call whose caller info II signed for this origin and for the notification's own
/// recipient, and does nothing for anyone else.
mixin <system>(
    state : NotificationState.State,
    // Whether the app still wants this notification delivered to this recipient, asked again
    // before each send or retry and on each pull, since what the app wants can change while it
    // waits (a staff member turns push off or loses access). Must not trap.
    wanted : (recipient : Principal, id : Nat64) -> Bool,
) {

    // Transient, so an upgraded canister takes the values this version carries.

    /// How long sends accumulate before one call carries them. Urgency decides
    /// which lane drains first, not call timing, so everything waits for it.
    transient let COALESCE : Nat = 2_000_000_000;

    /// Internet Identity's own default, mirrored so the outbox orders and
    /// expires notifications by the window they actually have.
    transient let II_DEFAULT_RETENTION : Int = 3_600_000_000_000;

    /// II is a canister we don't control: a bounded-wait call can't block core from stopping or
    /// upgrading. A call that times out may still have been taken; resending the same ids is
    /// harmless, since II keys notifications by id.
    transient let II_CALL_TIMEOUT_SECONDS : Nat32 = 60;

    /// Read again on an upgrade, so a canister takes the environment it came
    /// back with.
    transient let configured = Config.read<system>();
    transient let randomness = actor "aaaaa-aa" : actor {
        raw_rand : () -> async Blob;
    };

    /// The wake-up that is set, and when it fires, so a nearer one can take its
    /// place. Transient because a timer does not survive an upgrade: a canister
    /// that came back believing one was armed would never arm another.
    transient var armed : ?(Timer.TimerId, Time.Time) = null;
    transient var flushing : Bool = false;
    transient var senderOverride : ?Principal = null;
    /// The ids in the batch II is answering right now, and those of them a send replaced meanwhile.
    /// A replaced one that II then accepts carries the old window, so it is sent again. Transient: a
    /// call in flight doesn't survive an upgrade either.
    transient let inFlight = Set.empty<Nat64>();
    transient let replacedInFlight = Set.empty<Nat64>();

    transient let notifications = object {

        /// Sends a notification, or updates the one this recipient's `key` already
        /// names. Never traps, never awaits: a notification is an aside to
        /// whatever the app was actually doing.
        public func send<system>(recipient : Principal, notification : Types.Notification) {
            let now = Time.now();
            let hour = Metrics.hourOf(now);
            switch (notification.funnel) {
                case (?name) state.pipeline.openFunnel(name);
                case null {};
            };
            countAsk(hour, notification.funnel, #queued);

            switch configured {
                case (#err(why)) {
                    note(why);
                    countAsk(hour, notification.funnel, #dropped);
                };
                case (#ok(config)) {
                    if (sender(config) == null) {
                        note(#sender);
                        countAsk(hour, notification.funnel, #dropped);
                        return;
                    };
                    let added = state.outbox.add(
                        recipient,
                        notification,
                        now + II_DEFAULT_RETENTION,
                        config.capacityBytes,
                        now,
                    );
                    switch added {
                        case null countAsk(hour, notification.funnel, #dropped);
                        case (?id) {
                            if (inFlight.contains(Nat64.compare, id)) replacedInFlight.add(Nat64.compare, id);
                            arm<system>();
                        };
                    };
                };
            };
        };

        /// The configured `notification_origin`, for building `url`s on it; `null` when unset, in
        /// which case `send` drops everything anyway.
        public func origin() : ?Text = switch configured {
            case (#ok(config)) ?config.origin;
            case (#err(_)) null;
        };

        /// Sends through this canister, and trusts it on a pull, in place of the
        /// `notification_sender` variable; `null` goes back to the variable. Not
        /// remembered across an upgrade.
        public func setSender(sender : ?Principal) {
            senderOverride := sender;
        };

        /// This notification no longer needs anyone's attention. Its content goes,
        /// so a pull finds nothing and a channel that sweeps can close it.
        public func dismiss(recipient : Principal, key : Text) {
            state.outbox.dismiss(recipient, key);
        };

        /// The id a notification sent to `recipient` under `key` has, to compare in `wanted`.
        public func idFor(recipient : Principal, key : Text) : Nat64 = Ids.keyed(recipient, key);

        public func metrics() : Types.Metrics = {
            hours = state.pipeline.snapshot();
            funnels = state.pipeline.funnels();
            backlog = state.outbox.backlog();
            misconfigured = state.misconfigured;
        };

        /// Drops a funnel's row. What it counted goes with it, and notifications
        /// still carrying it are counted in their hour alone.
        public func forgetFunnel(name : Text) {
            state.pipeline.forgetFunnel(name);
        };
    };

    /// A step of a notification that has no entry yet: the ask itself.
    func countAsk(hour : Time.Time, funnel : ?Text, event : Metrics.Event) {
        state.pipeline.record(hour, event, 1);
        switch funnel {
            case (?name) state.pipeline.recordFunnel(name, event, 1);
            case null {};
        };
    };

    /// Called by Internet Identity once a channel has a notification to render. Answers only the
    /// notification's own recipient, through II (see the mixin's doc comment).
    public shared query func _internet_identity_notification_content(
        id : Nat64
    ) : async ?Types.Content {
        let ?_ = senderInfoFor(id) else return null;
        state.outbox.contentOf(id);
    };

    /// Called by Internet Identity: delivered. Content stays until it expires, because another of
    /// the user's devices may still pull it. Ignores calls II didn't sign for the recipient.
    public shared func _internet_identity_notification_received(id : Nat64) : async () {
        let ?_ = senderInfoFor(id) else return;
        if (not state.outbox.holds(id)) return;
        if (not state.outbox.markReceived(id)) return;
        switch (state.outbox.entryOf(id)) {
            case (?entry) Flush.count(state.pipeline, entry, #received);
            case null {};
        };
    };

    /// Called by Internet Identity: somebody acted on the notification a channel showed them.
    /// Ignores calls II didn't sign for the recipient.
    public shared func _internet_identity_notification_opened(id : Nat64) : async () {
        let ?_ = senderInfoFor(id) else return;
        if (not state.outbox.markOpened(id)) return;
        switch (state.outbox.entryOf(id)) {
            case (?entry) Flush.count(state.pipeline, entry, #opened);
            case null {};
        };
    };

    /// Internet Identity signed this call's caller info, it names our own
    /// origin, and this notification is the account's own.
    ///
    /// Every holder of a notification-pull delegation for this app satisfies the
    /// first two on their own account, so the account is what separates them: an
    /// id is derived from the recipient and a key, so whoever knows both can
    /// name another account's notification.
    func senderInfoFor(id : Nat64) : ?CallerInfo.SenderInfo {
        let ?info = senderInfo() else return null;
        let ?entry = state.outbox.entryOf(id) else return null;
        if (entry.recipient != info.account) return null;
        if (state.outbox.expired(id, Time.now()) or not wanted(entry.recipient, id)) return null;
        ?info;
    };

    /// Internet Identity signed this call's caller info, and it names our own
    /// origin. Anything else is not ours to answer.
    func senderInfo() : ?CallerInfo.SenderInfo {
        let #ok(config) = configured else return null;
        let ?signer = sender(config) else return null;
        let ?info = CallerInfo.read(signer) else return null;
        if (Origin.fold(info.origin) != Origin.fold(config.origin)) return null;
        ?info;
    };

    /// Who this canister sends through, and whose caller info it trusts: what
    /// `setSender` was given, or the configured variable.
    func sender(config : Config.Config) : ?Principal = switch senderOverride {
        case (?override_) ?override_;
        case null config.sender;
    };

    func note(why : Types.Misconfigured) {
        switch (state.misconfigured) {
            case (?current) if (current.why == why) return;
            case null {};
        };
        state.misconfigured := ?{ why; since = Time.now() };
    };

    /// Sets the wake-up for when the outbox next has something to do: the
    /// coalesce window where anything is waiting, the due time where an entry is
    /// parked for later, and no timer at all for an empty outbox. A call in
    /// flight carries its own wake-up, and one already set for later gives way to
    /// a nearer one.
    func arm<system>() {
        if (flushing) return;
        let ?due = state.outbox.nextDue() else return;

        let now = Time.now();
        let soonest = now + COALESCE;
        let at = if (due > soonest) due else soonest;
        switch armed {
            case (?(_, when)) if (when <= at) return;
            case null {};
        };
        switch armed {
            case (?(timer, _)) Timer.cancelTimer(timer);
            case null {};
        };
        armed := ?(
            Timer.setTimer<system>(
                #nanoseconds(Int.abs(at - now)),
                func() : async () { await flush() },
            ),
            at,
        );
    };

    func flush() : async () {
        armed := null;
        if (flushing) return;

        let config = switch configured {
            case (#err(why)) { note(why); return };
            case (#ok(c)) c;
        };
        let ?signer = sender(config) else { note(#sender); return };

        if (not state.seeded) {
            state.seeded := true;
            try {
                state.outbox.seed(await randomness.raw_rand());
            } catch (_) {};
        };

        let now = Time.now();
        // Internet Identity held them and no channel ever showed them, which is the
        // delivery pipeline's quietest loss.
        for (entry in state.outbox.sweep(now).values()) {
            Flush.count(state.pipeline, entry, #dropped);
        };
        state.outbox.promote(now);
        let (sendable, expired) = state.outbox.sendable(state.outbox.take(state.batchLimit), now);
        for (entry in expired.values()) {
            Flush.count(state.pipeline, entry, #dropped);
        };
        // No longer wanted since it was queued: dropped rather than sent.
        let batch = sendable.filter(
            func(entry : Outbox.Entry) : Bool {
                if (wanted(entry.recipient, entry.id)) return true;
                state.outbox.discard(entry.id);
                Flush.count(state.pipeline, entry, #dropped);
                false;
            }
        );

        // Nothing is sendable yet: a parked entry still has its turn coming.
        if (batch.size() == 0) return arm<system>();

        flushing := true;
        for (entry in batch.values()) inFlight.add(Nat64.compare, entry.id);
        let outcome = try {
            let ii = II.service(signer);
            switch (await (with timeout = II_CALL_TIMEOUT_SECONDS) ii.app_send_notification(Flush.arg(config.origin, batch))) {
                case (#Ok(response)) #answered(response.not_accepted);
                case (#Err(#TooManyNotifications { limit })) #tooMany(limit.toNat());
                case (#Err(#NoSuchSender)) #notAuthorized;
                case (#Err(#InternalCanisterError(_))) #unreachable;
            };
        } catch (_) {
            #unreachable;
        };
        flushing := false;

        switch outcome {
            case (#tooMany(limit)) state.batchLimit := limit;
            case (#notAuthorized) note(#notAuthorizedSender);
            case (_) {};
        };

        Flush.apply(state.outbox, state.pipeline, batch, outcome, now);
        for (id in replacedInFlight.values()) {
            switch (state.outbox.entryOf(id)) {
                case (?entry) state.outbox.resend(entry, now);
                case null {};
            };
        };
        inFlight.clear();
        replacedInFlight.clear();
        arm<system>();
    };

    // Runs on every install and every upgrade. A timer does not survive one, so
    // an outbox that did is picked up here rather than waiting for a send. A
    // fresh install has nothing queued, which arming answers with no timer.
    arm<system>();
};
