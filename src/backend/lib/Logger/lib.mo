import Array "mo:core/Array";
import Bool "mo:core/Bool";
import Debug "mo:core/Debug";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import Queue "mo:core/Queue";
import Text "mo:core/Text";
import Time "mo:core/Time";

module Logger {
    /// Entries kept in memory; the oldest are dropped past this.
    public let MAX_LOGS = 1_000;

    public type Value = {
        #text : Text;
        #nat : Nat;
        #int : Int;
        #bool : Bool;
        #principal : Principal;
    };

    /// A named value attached to a log entry, e.g. `("shop", #principal shopId)`.
    public type Field = (Text, Value);

    public type BoundLogger = {
        info : (message : Text) -> ();
        warning : (message : Text) -> ();
        error : (message : Text) -> ();
        infoWith : (message : Text, fields : [Field]) -> ();
        warningWith : (message : Text, fields : [Field]) -> ();
        errorWith : (message : Text, fields : [Field]) -> ();
    };

    public type LogLevel = {
        #Info;
        #Warning;
        #Error;
    };

    public type Log = {
        timestamp : Time.Time;
        level : LogLevel;
        message : Text;
        fields : [Field];
    };

    public type Logger = {
        canisterId : Principal;
        logs : Queue.Queue<Log>;
        settings : {
            printToConsole : Bool;
        };
    };

    public func new(canisterId : Principal, printToConsole : ?Bool) : Logger {
        {
            canisterId;
            logs = Queue.empty();
            settings = {
                printToConsole = Option.get(printToConsole, false);
            };
        };
    };

    func levelText(level : LogLevel) : Text {
        switch level {
            case (#Info) "INFO";
            case (#Warning) "WARN";
            case (#Error) "ERROR";
        };
    };

    public func valueText(value : Value) : Text {
        switch value {
            case (#text t) t;
            case (#nat n) Nat.toText(n);
            case (#int i) Int.toText(i);
            case (#bool b) Bool.toText(b);
            case (#principal p) Principal.toText(p);
        };
    };

    /// `[LEVEL] message key=value key=value`, as printed to the console.
    public func format(log : Log) : Text {
        let pairs = Array.map<Field, Text>(log.fields, func((key, value)) { key # "=" # valueText(value) });
        let line = "[" # levelText(log.level) # "] " # log.message;
        if (pairs.size() == 0) line else line # " " # Text.join(pairs.values(), " ");
    };

    func add(logger : Logger, level : LogLevel, message : Text, fields : [Field]) {
        let log = { timestamp = Time.now(); level; message; fields };
        Queue.pushBack(logger.logs, log);
        if (Queue.size(logger.logs) > MAX_LOGS) {
            ignore Queue.popFront(logger.logs);
        };
        if (logger.settings.printToConsole) {
            Debug.print(format(log));
        };
    };

    public func info(logger : Logger, message : Text) : () {
        add(logger, #Info, message, []);
    };

    public func warning(logger : Logger, message : Text) : () {
        add(logger, #Warning, message, []);
    };

    public func error(logger : Logger, message : Text) : () {
        add(logger, #Error, message, []);
    };

    public func infoWith(logger : Logger, message : Text, fields : [Field]) : () {
        add(logger, #Info, message, fields);
    };

    public func warningWith(logger : Logger, message : Text, fields : [Field]) : () {
        add(logger, #Warning, message, fields);
    };

    public func errorWith(logger : Logger, message : Text, fields : [Field]) : () {
        add(logger, #Error, message, fields);
    };

    /// Up to `limit` entries (default and max `MAX_LOGS`), newest first.
    public func recent(logger : Logger, limit : ?Nat) : [Log] {
        let n = Option.get(limit, MAX_LOGS);
        Iter.toArray(Iter.take(Queue.reverseValues(logger.logs), n));
    };

    public func bind(logger : Logger) : BoundLogger {
        {
            info = func(message : Text) { info(logger, message) };
            warning = func(message : Text) { warning(logger, message) };
            error = func(message : Text) { error(logger, message) };
            infoWith = func(message : Text, fields : [Field]) {
                infoWith(logger, message, fields);
            };
            warningWith = func(message : Text, fields : [Field]) {
                warningWith(logger, message, fields);
            };
            errorWith = func(message : Text, fields : [Field]) {
                errorWith(logger, message, fields);
            };
        };
    };
};
