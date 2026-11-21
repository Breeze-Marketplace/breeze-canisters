import Principal "mo:core/Principal";
import Queue "mo:core/Queue";

// Adds structured `fields` to each log entry; entries already kept have none.
module {
    // Inlined copies of `Logger.Log` and `Logger.Logger` (src/backend/lib/Logger) before and
    // after this migration.
    type LogLevel = {
        #Info;
        #Warning;
        #Error;
    };

    type Value = {
        #text : Text;
        #nat : Nat;
        #int : Int;
        #bool : Bool;
        #principal : Principal;
    };

    type OldLog = {
        timestamp : Int;
        level : LogLevel;
        message : Text;
    };

    type NewLog = OldLog and { fields : [(Text, Value)] };

    type Settings = { printToConsole : Bool };

    type OldActor = {
        var logState : {
            canisterId : Principal;
            logs : Queue.Queue<OldLog>;
            settings : Settings;
        };
    };

    type NewActor = {
        var logState : {
            canisterId : Principal;
            logs : Queue.Queue<NewLog>;
            settings : Settings;
        };
    };

    public func migration(old : OldActor) : NewActor {
        {
            var logState = {
                old.logState with
                logs = Queue.map<OldLog, NewLog>(old.logState.logs, func(log) { { log with fields = [] } });
            };
        };
    };
};
