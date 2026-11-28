import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import PriorityQueue "mo:core/PriorityQueue";
import Time "mo:core/Time";

// Browser push for platform alerts (BRE-211). Every staff member's alert settings gain `push`, off:
// nobody is notified until they turn it on. Adds the notifications mixin's state, empty. The types
// are this version's (`api/alerts`, `lib/notifications`), copied here because a migration can't
// import them.
module {
    type AlertKind = {
        #userRegistered : { user : Principal };
        #shopCreated : { shop : Principal; owner : Principal };
        #shopRegistered : { shop : Principal; owner : Principal };
        #shopCreationFailed : { quoteId : Nat; owner : Principal; error : Text };
    };
    type AlertType = {
        #userRegistered;
        #shopCreated;
        #shopRegistered;
        #shopCreationFailed;
    };
    type Alert = { seq : Nat; at : Int; kind : AlertKind };
    type OldSettings = { muted : [AlertType]; lastSeen : ?Nat };
    type NewSettings = { muted : [AlertType]; lastSeen : ?Nat; push : Bool };
    type OldAlerts = {
        alerts : Map.Map<Nat, Alert>;
        var nextSeq : Nat;
        settings : Map.Map<Principal, OldSettings>;
    };
    type NewAlerts = {
        alerts : Map.Map<Nat, Alert>;
        var nextSeq : Nat;
        settings : Map.Map<Principal, NewSettings>;
    };

    type Stage = { #nowhere; #waiting; #parked; #accepted };
    type Entry = {
        id : Nat64;
        recipient : Principal;
        var lane : Nat;
        var expiresAt : Time.Time;
        var dueAt : Time.Time;
        var stage : Stage;
        var retried : Bool;
        var received : Bool;
        var opened : Bool;
        queuedHour : Time.Time;
        funnel : ?Text;
    };
    type Schedule = Map.Map<(Time.Time, Nat64), Entry>;
    type Content = { title : Text; body : Text; url : ?Text };
    type Outbox = {
        ready : { lanes : [PriorityQueue.PriorityQueue<Entry>] };
        parked : Schedule;
        accepted : Schedule;
        content : Map.Map<Nat64, Content>;
        entries : Map.Map<Nat64, Entry>;
        var counter : Nat64;
        var idSeed : Nat64;
        var bytes : Nat;
        var queued : Nat;
    };
    type Counts = {
        var queued : Nat;
        var accepted : Nat;
        var received : Nat;
        var opened : Nat;
        var dropped : Nat;
        var deferred : Nat;
    };
    type Pipeline = {
        hours : Map.Map<Time.Time, Counts>;
        funnels : Map.Map<Text, Counts>;
    };
    type Misconfigured = { #origin; #sender; #notAuthorizedSender };
    type NotificationState = {
        outbox : Outbox;
        pipeline : Pipeline;
        var batchLimit : Nat;
        var misconfigured : ?{ why : Misconfigured; since : Time.Time };
        var seeded : Bool;
    };

    // The outbox's urgency lanes and first batch size, as `lib/notifications` sets them.
    let OUTBOX_LANES = 4;
    let FIRST_BATCH_LIMIT = 1_000;

    public func migration(old : { platformAlerts : OldAlerts }) : {
        platformAlerts : NewAlerts;
        alertNotifications : NotificationState;
    } {
        {
            platformAlerts = {
                alerts = old.platformAlerts.alerts;
                var nextSeq = old.platformAlerts.nextSeq;
                settings = old.platformAlerts.settings.map<Principal, OldSettings, NewSettings>(
                    func(_, settings) = { settings with push = false }
                );
            };
            alertNotifications = {
                outbox = {
                    ready = {
                        lanes = Array.tabulate<PriorityQueue.PriorityQueue<Entry>>(OUTBOX_LANES, func(_) = PriorityQueue.empty<Entry>());
                    };
                    parked = Map.empty();
                    accepted = Map.empty();
                    content = Map.empty();
                    entries = Map.empty();
                    var counter = 0;
                    var idSeed = 0;
                    var bytes = 0;
                    var queued = 0;
                };
                pipeline = { hours = Map.empty(); funnels = Map.empty() };
                var batchLimit = FIRST_BATCH_LIMIT;
                var misconfigured = null;
                var seeded = false;
            };
        };
    };
};
