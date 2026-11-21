import Queue "mo:core/Queue";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import { type Logger; type BoundLogger; type Field } "./lib";

module MockLogger {
    public func new(canisterId : Principal) : Logger {
        {
            canisterId;
            logs = Queue.empty();
            settings = {
                printToConsole = false; // Keeps test output clean
            };
        };
    };

    /// Discards every entry.
    public func bind(_logger : Logger) : BoundLogger {
        {
            info = func(_ : Text) {};
            warning = func(_ : Text) {};
            error = func(_ : Text) {};
            infoWith = func(_ : Text, _ : [Field]) {};
            warningWith = func(_ : Text, _ : [Field]) {};
            errorWith = func(_ : Text, _ : [Field]) {};
        };
    };
};
