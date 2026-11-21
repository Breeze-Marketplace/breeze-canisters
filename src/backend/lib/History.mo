import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Order "mo:core/Order";
import Set "mo:core/Set";

import Pagination "Pagination";

/// An append-only history, shared by every canister that keeps one (shop orders now, the marketplace
/// next: BRE-133, BRE-153). Every event gets a canister-wide sequence number, so a reader that missed
/// some can page on from the last number it saw (`listAfter`). Each event belongs to a subject (an
/// order, a shop), and one subject's events read in order through `bySubject` (`ofSubject`). Events
/// never change once appended.
///
/// Generic over the subject `S` and the event `E`. Each canister defines its own event type, which
/// carries its `seq` and subject, so its Candid shows them; `append` hands it the `seq` to use.
module History {
    /// Stable state: keep one per history as a stable field.
    public type Log<S, E> = {
        events : Map.Map<Nat, E>;
        /// `(subject, seq)` for every event, so one subject's events are a contiguous, ordered range.
        bySubject : Set.Set<(S, Nat)>;
        var nextSeq : Nat;
    };

    public func empty<S, E>() : Log<S, E> {
        { events = Map.empty(); bySubject = Set.empty(); var nextSeq = 0 };
    };

    /// Orders `(subject, seq)` pairs by subject, then sequence number.
    public func compareSubjectSeq<S>(compareSubject : (S, S) -> Order.Order) : ((S, Nat), (S, Nat)) -> Order.Order {
        func((s1, n1) : (S, Nat), (s2, n2) : (S, Nat)) : Order.Order {
            switch (compareSubject(s1, s2)) {
                case (#equal) Nat.compare(n1, n2);
                case other other;
            };
        };
    };

    /// Appends the event `make(seq)` for `subject` and returns it.
    public func append<S, E>(
        log : Log<S, E>,
        compareSubject : (S, S) -> Order.Order,
        subject : S,
        make : (seq : Nat) -> E,
    ) : E {
        let seq = log.nextSeq;
        let event = make(seq);
        Map.add(log.events, Nat.compare, seq, event);
        Set.add(log.bySubject, compareSubjectSeq(compareSubject), (subject, seq));
        log.nextSeq += 1;
        event;
    };

    /// `subject`'s events, oldest first.
    public func ofSubject<S, E>(log : Log<S, E>, compareSubject : (S, S) -> Order.Order, subject : S) : [E] {
        let out = List.empty<E>();
        label scan for ((s, seq) in Set.valuesFrom(log.bySubject, compareSubjectSeq(compareSubject), (subject, 0))) {
            if (compareSubject(s, subject) != #equal) break scan;
            switch (Map.get(log.events, Nat.compare, seq)) {
                case (?event) List.add(out, event);
                case null {};
            };
        };
        List.toArray(out);
    };

    /// `subject`'s latest event, if it has one. Reads only that event.
    public func lastOfSubject<S, E>(log : Log<S, E>, compareSubject : (S, S) -> Order.Order, subject : S) : ?E {
        // The pairs from the subject's first after it (the next subject's, or none), read backwards.
        for ((s, seq) in Set.reverseValuesFrom(log.bySubject, compareSubjectSeq(compareSubject), (subject, log.nextSeq))) {
            if (compareSubject(s, subject) != #equal) return null;
            return Map.get(log.events, Nat.compare, seq);
        };
        null;
    };

    /// `subject`'s events after sequence number `after`, oldest first, a page at a time.
    public func pageOfSubject<S, E>(
        log : Log<S, E>,
        compareSubject : (S, S) -> Order.Order,
        subject : S,
        after : ?Nat,
        limit : ?Nat,
    ) : Pagination.Page<E, Nat> {
        let from = switch (after) { case (?seq) seq + 1; case null 0 };
        let pairs = Set.valuesFrom(log.bySubject, compareSubjectSeq(compareSubject), (subject, from));
        // Stop at the next subject's first pair, so the page never reads past this subject.
        let own = object {
            public func next() : ?(S, Nat) {
                switch (pairs.next()) {
                    case (?(s, seq)) if (compareSubject(s, subject) == #equal) ?(s, seq) else null;
                    case null null;
                };
            };
        };
        Pagination.scan<(S, Nat), E, Nat>(
            own,
            func((_, seq)) = seq,
            Nat.compare,
            after,
            func((_, seq)) = Map.get(log.events, Nat.compare, seq),
            limit,
        );
    };

    /// Every event after sequence number `after`, oldest first, a page at a time.
    public func listAfter<S, E>(log : Log<S, E>, after : ?Nat, limit : ?Nat) : Pagination.Page<E, Nat> {
        let from = switch (after) { case (?seq) seq + 1; case null 0 };
        Pagination.scan<(Nat, E), E, Nat>(
            Map.entriesFrom(log.events, Nat.compare, from),
            func((seq, _)) = seq,
            Nat.compare,
            after,
            func((_, event)) = ?event,
            limit,
        );
    };
};
