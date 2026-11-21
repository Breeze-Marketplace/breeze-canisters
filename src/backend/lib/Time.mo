import Nat "mo:core/Nat";
import T "mo:core/Time";

module {
    public func toSeconds(time : T.Time) : Int {
        time / 1_000_000_000;
    };

    public func toMinutes(time : T.Time) : Int {
        time / 60_000_000_000;
    };

    /// Nanoseconds from `now` until `deadline`, or 0 once `deadline` has passed. Fits a timer delay.
    public func remainingUntil(deadline : T.Time, now : T.Time) : Nat {
        if (deadline <= now) 0 else Nat.fromInt(deadline - now);
    };

    public func diff(endTime : T.Time, startTime : T.Time) : T.Time {
        endTime - startTime;
    };

    public func fromSeconds(seconds : Int) : T.Time {
        seconds * 1_000_000_000;
    };

    public func fromMinutes(minutes : Int) : T.Time {
        minutes * 60 * 1_000_000_000;
    };

    public func fromHours(hours : Int) : T.Time {
        hours * 60 * 60 * 1_000_000_000;
    };

    public func fromDays(days : Int) : T.Time {
        days * 24 * 60 * 60 * 1_000_000_000;
    };
};
