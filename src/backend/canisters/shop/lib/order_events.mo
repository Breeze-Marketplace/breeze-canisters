import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Order "mo:core/Order";
import Set "mo:core/Set";

import History "../../../lib/History";
import Pagination "../../../lib/Pagination";

/// Each order's history: what happened to it and when (BRE-133), kept in the shared append-only
/// `History` log. Every event gets a shop-wide sequence number, so a subscriber that missed
/// notifications (core) can page the log from the last number it applied (`listAfter`).
module {
    public type OrderId = Nat32;

    public type DeliveryMethod = {
        #shipped : { carrier : ?Text; trackingNumber : ?Text };
        /// The buyer's first successful `requestDigitalDelivery` for the line.
        #digital;
        /// Pickup, hand-over, or a service performed.
        #inPerson;
    };

    public type CancelReason = { #expired; #buyer; #merchant; #paymentMismatch };

    public type OrderEventKind = {
        #created;
        #awaitingPayment : { provider : { #ICRC1; #Manual; #Stripe } };
        #paid : { provider : { #ICRC1; #Manual; #Stripe } };
        #lineDelivered : { lineIndex : Nat; method : DeliveryMethod };
        /// `method` is null when lines went out in different ways, or for history rebuilt from an
        /// order stored before events existed.
        #fulfilled : { method : ?DeliveryMethod };
        #partiallyFulfilled;
        /// `reason` is null only for history rebuilt from an order stored before events existed.
        #canceled : { reason : ?CancelReason };
        #refunded;
    };

    /// Who caused an event: a role, never a principal, so the history can be shown to the buyer
    /// without revealing who on the shop's staff acted.
    public type Initiator = { #buyer; #merchant; #automatic };

    public type OrderEvent = {
        seq : Nat;
        orderId : OrderId;
        at : Int;
        by : Initiator;
        kind : OrderEventKind;
    };

    /// The shop's order history: the shared `History` log, with orders as subjects.
    public type Log = History.Log<OrderId, OrderEvent>;

    public func empty() : Log = History.empty();

    /// Appends an event to the log and returns it.
    public func append(log : Log, orderId : OrderId, at : Int, by : Initiator, kind : OrderEventKind) : OrderEvent {
        History.append<OrderId, OrderEvent>(log, Nat32.compare, orderId, func seq = { seq; orderId; at; by; kind });
    };

    /// Order `orderId`'s events, oldest first.
    public func history(log : Log, orderId : OrderId) : [OrderEvent] {
        History.ofSubject(log, Nat32.compare, orderId);
    };

    /// Order `orderId`'s latest event, if it has one.
    public func latest(log : Log, orderId : OrderId) : ?OrderEvent {
        History.lastOfSubject(log, Nat32.compare, orderId);
    };

    /// The shop-wide log after sequence number `after`, oldest first, a page at a time.
    public func listAfter(log : Log, after : ?Nat, limit : ?Nat) : Pagination.Page<OrderEvent, Nat> {
        History.listAfter(log, after, limit);
    };

    /// The line indexes of order `orderId` recorded as delivered.
    public func deliveredLines(log : Log, orderId : OrderId) : Set.Set<Nat> {
        let lines = Set.empty<Nat>();
        for (event in history(log, orderId).values()) {
            switch (event.kind) {
                case (#lineDelivered({ lineIndex })) Set.add(lines, Nat.compare, lineIndex);
                case _ {};
            };
        };
        lines;
    };

    /// How each of order `orderId`'s delivered lines went out, in the order they were recorded.
    public func deliveryMethods(log : Log, orderId : OrderId) : [DeliveryMethod] {
        let out = List.empty<DeliveryMethod>();
        for (event in history(log, orderId).values()) {
            switch (event.kind) {
                case (#lineDelivered({ method })) List.add(out, method);
                case _ {};
            };
        };
        List.toArray(out);
    };

    /// The order status once `delivered` of its `lineCount` lines have gone out: fulfilled when all
    /// have, partially fulfilled when some have, unchanged (null) when none have.
    public func fulfilmentStatus(lineCount : Nat, delivered : Set.Set<Nat>) : ?{
        #fulfilled;
        #partiallyFulfilled;
    } {
        let n = Iter.size(Iter.filter(Set.values(delivered), func(i : Nat) : Bool = i < lineCount));
        if (n == 0) null else if (n >= lineCount) ?#fulfilled else ?#partiallyFulfilled;
    };

    /// The one method all `methods` share, or null when they differ (or there are none).
    public func commonMethod(methods : [DeliveryMethod]) : ?DeliveryMethod {
        if (methods.size() == 0) return null;
        let first = methods[0];
        for (m in methods.values()) {
            if (m != first) return null;
        };
        ?first;
    };
};
