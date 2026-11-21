import Principal "mo:core/Principal";
import Queue "mo:core/Queue";

// Keeps the shop's log across upgrades: `logState` becomes a stable field, starting empty.
module {
    // Inlined copy of `Logger.Log` and `Logger.Logger` (src/backend/lib/Logger) as of this migration.
    type LogLevel = {
        #Info;
        #Warning;
        #Error;
    };

    type Log = {
        timestamp : Int;
        level : LogLevel;
        message : Text;
    };

    type Logger = {
        canisterId : Principal;
        logs : Queue.Queue<Log>;
        settings : {
            printToConsole : Bool;
        };
    };

    // Only the new field; every other field carries over unchanged.
    type OldActor = {};

    type NewActor = {
        var logState : Logger;
    };

    public func migration(_old : OldActor) : NewActor {
        {
            // A migration can't see the canister's own principal: main.mo sets `canisterId` and
            // `settings` right after the stable fields, on every install and upgrade.
            var logState = {
                canisterId = Principal.anonymous();
                logs = Queue.empty<Log>();
                settings = { printToConsole = false };
            };
        };
    };
};
