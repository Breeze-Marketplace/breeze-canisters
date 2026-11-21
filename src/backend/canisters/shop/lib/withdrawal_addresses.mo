import Array "mo:core/Array";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import Map "mo:core/Map";
import Order "mo:core/Order";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Text "mo:core/Text";

import Withdrawals "withdrawals";

/// The Owner's saved withdrawal addresses, each with a name (BRE-150). Pure, so it runs under
/// `mops test`; `WalletApi` checks the caller. Saving an address doesn't restrict `withdrawFunds`.
module WithdrawalAddresses {
    public type Destination = Withdrawals.Destination;

    /// What's stored per address. The address itself is the key.
    public type Saved = { name : Text; addedAt : Int };

    public type Book = Map.Map<Destination, Saved>;

    /// A saved address as `listWithdrawalAddresses` returns it.
    public type WithdrawalAddress = Destination and Saved;

    public type SaveAddressError = {
        #Unauthorized : Text;
        #InvalidDestination : Text;
        #InvalidName : Text;
        /// The book already holds `MAX_ADDRESSES`; remove one first.
        #LimitReached : Nat;
    };

    public type RemoveError = { #Unauthorized : Text; #NotFound };

    public let MAX_ADDRESSES = 50;
    public let MAX_NAME_CHARS = 40;

    public func empty() : Book = Map.empty();

    /// An all-zero subaccount names the same ICRC-1 account as none, so both are stored as none.
    public func normalize(to : Destination) : Destination {
        switch (to.subaccount) {
            case (?s) {
                if (s.vals().all(func(b : Nat8) : Bool { b == 0 })) {
                    { owner = to.owner; subaccount = null };
                } else to;
            };
            case null to;
        };
    };

    public func compareDestination(a : Destination, b : Destination) : Order.Order {
        switch (Principal.compare(a.owner, b.owner)) {
            case (#equal) {
                switch (a.subaccount, b.subaccount) {
                    case (null, null) #equal;
                    case (null, ?_) #less;
                    case (?_, null) #greater;
                    case (?x, ?y) Blob.compare(x, y);
                };
            };
            case (order) order;
        };
    };

    /// The name trimmed, or why it can't be one: empty, longer than `MAX_NAME_CHARS`, or with a
    /// control character (a newline would let a name pass for two lines of the form).
    public func checkName(name : Text) : Result<Text, Text> {
        let trimmed = name.trim(#predicate(Char.isWhitespace));
        if (trimmed.size() == 0) {
            return #err("Enter a name");
        };
        if (trimmed.size() > MAX_NAME_CHARS) {
            return #err("A name can be at most " # debug_show (MAX_NAME_CHARS) # " characters");
        };
        for (c in trimmed.chars()) {
            if (c < ' ' or c == '\u{7F}') {
                return #err("A name can't contain control characters");
            };
        };
        #ok(trimmed);
    };

    /// Adds `to` with `name`, or renames it if it's already saved (keeping when it was added).
    public func save(book : Book, to : Destination, name : Text, shopId : Principal, now : Int) : Result<WithdrawalAddress, SaveAddressError> {
        switch (Withdrawals.checkDestination(to, shopId)) {
            case (#ok) {};
            case (#err(message)) { return #err(#InvalidDestination(message)) };
        };
        let checkedName = switch (checkName(name)) {
            case (#ok(l)) l;
            case (#err(message)) { return #err(#InvalidName(message)) };
        };
        let key = normalize(to);
        let saved : Saved = switch (book.get(compareDestination, key)) {
            case (?existing) { { existing with name = checkedName } };
            case null {
                if (book.size() >= MAX_ADDRESSES) {
                    return #err(#LimitReached(MAX_ADDRESSES));
                };
                { name = checkedName; addedAt = now };
            };
        };
        book.add(compareDestination, key, saved);
        #ok(entry(key, saved));
    };

    /// Removes `to`. False if it wasn't saved.
    public func remove(book : Book, to : Destination) : Bool {
        book.delete(compareDestination, normalize(to));
    };

    /// Every saved address, oldest first.
    public func list(book : Book) : [WithdrawalAddress] {
        let entries = book.entries().map<(Destination, Saved), WithdrawalAddress>(func((k, v)) = entry(k, v)).toArray();
        entries.sort(func(a : WithdrawalAddress, b : WithdrawalAddress) : Order.Order { Int.compare(a.addedAt, b.addedAt) });
    };

    func entry(key : Destination, saved : Saved) : WithdrawalAddress {
        {
            owner = key.owner;
            subaccount = key.subaccount;
            name = saved.name;
            addedAt = saved.addedAt;
        };
    };
};
