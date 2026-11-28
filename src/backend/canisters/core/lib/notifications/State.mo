import Time "mo:core/Time";

import Metrics "Internal/Metrics";
import Outbox "Internal/Outbox";
import Types "Types";

/// The stable state of the notifications mixin (`mixins/Notifications.mo`), held by the actor and
/// passed in, since core's enhanced-migration build refuses stable fields declared with initial
/// values inside a mixin. A core migration creates it with these values; a change to this type
/// needs a migration.
module {
    public type State = {
        outbox : Outbox.State;
        pipeline : Metrics.State;
        /// What Internet Identity accepts in one call, lowered when it answers `TooManyNotifications`.
        var batchLimit : Nat;
        var misconfigured : ?{ why : Types.Misconfigured; since : Time.Time };
        /// Whether the keyless id offset has been drawn from `raw_rand`.
        var seeded : Bool;
    };

    /// What Internet Identity accepts in one call, until `TooManyNotifications` says otherwise.
    public let BATCH_GUESS : Nat = 1_000;

    public func empty() : State = {
        outbox = Outbox.empty();
        pipeline = Metrics.empty();
        var batchLimit = BATCH_GUESS;
        var misconfigured = null;
        var seeded = false;
    };
};
