import Iter "mo:core/Iter";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

/// Marketplaces the Owner recognized (`recognizeMarketplace`): each one's core (backend) canister,
/// frontend canister and name, as that core reported them. Recognizing one also grants it
/// Marketplace access (`lib/auth`).
module Marketplaces {
    public type RecognizedMarketplace = {
        backendCanisterId : Principal;
        frontendCanisterId : ?Principal;
        name : Text;
        recognizedAt : Int;
        recognizedBy : Principal;
    };

    public type Store = Map.Map<Principal, RecognizedMarketplace>;

    /// What a marketplace's core answers to `getMarketplaceInfo`.
    public type MarketplaceInfo = {
        backendCanisterId : Principal;
        frontendCanisterId : ?Principal;
        name : Text;
    };

    public type RecognizeError = {
        #Unauthorized : Text;
        /// The canister didn't answer `getMarketplaceInfo`, or answered for another canister.
        #MarketplaceUnreachable : Text;
    };

    /// Seconds to wait for a marketplace's `getMarketplaceInfo`: the canister is the Owner's pick,
    /// not ours, and a silent one mustn't block stopping or upgrading the shop.
    public let CALL_TIMEOUT_SECONDS : Nat32 = 30;

    /// Longest name kept; a longer one is cut.
    public let MAX_NAME_SIZE = 100;

    /// Records `info`, answered by `backend`, as recognized by `caller` at `now`. Refuses an answer
    /// that names another canister: only a marketplace's own core may describe it.
    public func record(store : Store, backend : Principal, info : MarketplaceInfo, caller : Principal, now : Int) : {
        #ok : RecognizedMarketplace;
        #err : RecognizeError;
    } {
        if (info.backendCanisterId != backend) {
            return #err(#MarketplaceUnreachable("The canister described another marketplace (" # info.backendCanisterId.toText() # ")"));
        };
        let entry : RecognizedMarketplace = {
            backendCanisterId = backend;
            frontendCanisterId = info.frontendCanisterId;
            name = truncate(info.name.trim(#char ' '), MAX_NAME_SIZE);
            recognizedAt = now;
            recognizedBy = caller;
        };
        store.add(Principal.compare, backend, entry);
        #ok(entry);
    };

    public func forget(store : Store, backend : Principal) {
        store.remove(Principal.compare, backend);
    };

    public func list(store : Store) : [RecognizedMarketplace] {
        store.values().toArray();
    };

    func truncate(text : Text, max : Nat) : Text {
        if (text.size() <= max) return text;
        var out = "";
        var n = 0;
        label chars for (c in text.chars()) {
            if (n == max) break chars;
            out #= Text.fromChar(c);
            n += 1;
        };
        out;
    };
};
