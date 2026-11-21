import Order "mo:core/Order";
import Principal "mo:core/Principal";
import Time "mo:core/Time";

import History "../../../../lib/History";
import Pagination "../../../../lib/Pagination";

/// The marketplace's history (BRE-153): an append-only record of what staff, merchants and core did
/// to the marketplace, with who did it and when. Kept in the shared `History` log; an event about a
/// shop (or its vault) has that shop as its subject, so one shop's timeline is a single read.
/// Unlike order events, events name the acting principal: only staff with `History.View` read them.
module {
    public type WasmName = { #shop; #vault };
    public type Version = Nat;

    /// How a call that changes a canister ended: these are recorded either way, because a failed
    /// upgrade or restore can leave the canister changed or stopped.
    public type Outcome = { #ok; #err : Text };

    public type EventKind = {
        // Shops
        #shopCreated : { owner : Principal; quoteId : Nat };
        #shopRegistered : { owner : Principal };
        #shopUnregistered;
        #shopSlugChanged : { slug : Text };
        #vaultLinked : { vault : ?Principal };
        // Upgrades and releases
        #upgraded : { canister : Principal; name : WasmName; version : Version; outcome : Outcome };
        #snapshotRestored : { canister : Principal; outcome : Outcome };
        #canisterStarted : { canister : Principal; outcome : Outcome };
        #canaryEligibilitySet : { eligible : Bool };
        #rolloutApproved : { name : WasmName; version : Version };
        #initialVersionSet : { name : WasmName; version : Version };
        #wasmYanked : { name : WasmName; version : Version };
        #wasmUnyanked : { name : WasmName; version : Version };
        #releasePublished : { name : WasmName; version : Version };
        // Handover (BRE-79)
        #handoverStarted : { controller : Principal };
        #handoverConfirmed;
        #handoverCancelled;
        #handedBack;
        // Staff (BRE-152)
        #roleCreated : { roleId : Nat; name : Text; permissions : [Text] };
        #roleUpdated : { roleId : Nat; name : Text; permissions : [Text] };
        #roleDeleted : { roleId : Nat };
        #roleAssigned : { principal : Principal; roleId : Nat };
        #roleUnassigned : { principal : Principal; roleId : Nat };
        // Settings
        #shopCreationPriceSet : { usdCents : Nat };
        #shopCallFeesEnforcedSet : { enforced : Bool };
        #stuckQuoteReleased : { quoteId : Nat };
    };

    public type Event = {
        seq : Nat;
        /// The shop the event is about, or null for marketplace-wide events (settings, staff, versions).
        shop : ?Principal;
        at : Int;
        by : Principal;
        kind : EventKind;
    };

    public type State = History.Log<?Principal, Event>;

    public func empty() : State = History.empty();

    /// Marketplace-wide events (null) sort before every shop's.
    public func compareShop(a : ?Principal, b : ?Principal) : Order.Order {
        switch (a, b) {
            case (null, null) #equal;
            case (null, ?_) #less;
            case (?_, null) #greater;
            case (?x, ?y) Principal.compare(x, y);
        };
    };

    public func record(state : State, by : Principal, shop : ?Principal, kind : EventKind) : Event {
        History.append<?Principal, Event>(state, compareShop, shop, func seq = { seq; shop; at = Time.now(); by; kind });
    };

    /// `result` as an `Outcome`, its error shown with `show` (`debug_show` at the caller: it can't
    /// show a generic type here).
    public func outcome<T, E>(result : { #ok : T; #err : E }, show : E -> Text) : Outcome {
        switch (result) {
            case (#ok(_)) #ok;
            case (#err(e)) #err(show(e));
        };
    };

    /// Every event after `after`, oldest first.
    public func page(state : State, after : ?Nat, limit : ?Nat) : Pagination.Page<Event, Nat> {
        History.listAfter(state, after, limit);
    };

    /// `shop`'s events after `after`, oldest first.
    public func pageShop(state : State, shop : Principal, after : ?Nat, limit : ?Nat) : Pagination.Page<Event, Nat> {
        History.pageOfSubject(state, compareShop, ?shop, after, limit);
    };
};
