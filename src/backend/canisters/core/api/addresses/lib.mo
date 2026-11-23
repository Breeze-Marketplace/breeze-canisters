import Char "mo:core/Char";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import { type Result } "mo:core/Result";

import Pagination "../../../../lib/Pagination";
import ShippingAddressRules "../../../../lib/ShippingAddress";

/// Each user's saved shipping addresses, for picking one at checkout instead of typing it (BRE-209).
/// Pure, so it runs under `mops test`; the `Addresses` mixin checks the caller. Addresses are private
/// buyer data: only the user they belong to may read or change them, and nothing here is logged to
/// history or sent in events.
module {
    public type ShippingAddress = ShippingAddressRules.ShippingAddress;

    public type AddressId = Nat;

    public type StoredAddress = {
        nickname : Text;
        address : ShippingAddress;
        updatedAt : Int;
    };

    /// One user's saved addresses. Ids are never reused, so a stale id can't name a newer address.
    public type UserAddresses = {
        var nextId : AddressId;
        var defaultId : ?AddressId;
        byId : Map.Map<AddressId, StoredAddress>;
    };

    /// Every user's saved addresses: core's `savedAddresses` stable field.
    public type AddressesByUser = Map.Map<Principal, UserAddresses>;

    /// A saved address as the public methods return it.
    public type SavedAddress = StoredAddress and {
        id : AddressId;
        isDefault : Bool;
    };

    public type AddressError = {
        #Unauthenticated;
        /// Only registered users (`createUser`) may save addresses, which bounds how much is stored.
        #NotRegistered;
        #InvalidNickname : Text;
        #InvalidAddress : Text;
        /// The user already has `MAX_ADDRESSES`; delete one first.
        #LimitReached : Nat;
        #NotFound;
    };

    public let MAX_ADDRESSES = 10;
    public let MAX_NICKNAME_CHARS = 40;

    public func empty() : AddressesByUser = Map.empty();

    /// The nickname trimmed, or why it can't be one: empty, longer than `MAX_NICKNAME_CHARS`, or with a
    /// control character.
    public func checkNickname(nickname : Text) : Result<Text, Text> {
        let trimmed = nickname.trim(#predicate(Char.isWhitespace));
        if (trimmed.size() == 0) return #err("Enter a name for this address");
        if (trimmed.size() > MAX_NICKNAME_CHARS) {
            return #err("A name for an address can be at most " # Nat.toText(MAX_NICKNAME_CHARS) # " characters");
        };
        for (c in trimmed.chars()) {
            if (c < ' ' or c == '\u{7F}') return #err("A name for an address can't contain control characters");
        };
        #ok(trimmed);
    };

    func checkEntry(nickname : Text, address : ShippingAddress) : Result<Text, AddressError> {
        let checkedNickname = switch (checkNickname(nickname)) {
            case (#ok(l)) l;
            case (#err(message)) return #err(#InvalidNickname(message));
        };
        switch (ShippingAddressRules.validate(address)) {
            case (#ok) #ok(checkedNickname);
            case (#err(message)) #err(#InvalidAddress(message));
        };
    };

    func toSaved(user : UserAddresses, id : AddressId, stored : StoredAddress) : SavedAddress {
        { stored with id; isDefault = user.defaultId == ?id };
    };

    /// Saves a new address for `owner`. It becomes the default with `makeDefault`, or when `owner`
    /// had no saved addresses; a default the owner deleted or cleared stays unset otherwise.
    public func add(state : AddressesByUser, owner : Principal, nickname : Text, address : ShippingAddress, makeDefault : Bool, now : Int) : Result<SavedAddress, AddressError> {
        let checkedNickname = switch (checkEntry(nickname, address)) {
            case (#ok(l)) l;
            case (#err(e)) return #err(e);
        };
        let user = switch (state.get(owner)) {
            case (?u) u;
            case null {
                let u : UserAddresses = {
                    var nextId = 0;
                    var defaultId = null;
                    byId = Map.empty();
                };
                u;
            };
        };
        if (user.byId.size() >= MAX_ADDRESSES) return #err(#LimitReached(MAX_ADDRESSES));
        let id = user.nextId;
        user.nextId += 1;
        let stored = { nickname = checkedNickname; address; updatedAt = now };
        user.byId.add(id, stored);
        if (makeDefault or user.byId.size() == 1) user.defaultId := ?id;
        state.add(owner, user);
        #ok(toSaved(user, id, stored));
    };

    /// Replaces the nickname and address of `owner`'s address `id`. Its default status is unchanged.
    public func update(state : AddressesByUser, owner : Principal, id : AddressId, nickname : Text, address : ShippingAddress, now : Int) : Result<SavedAddress, AddressError> {
        let ?user = state.get(owner) else return #err(#NotFound);
        if (user.byId.get(id) == null) return #err(#NotFound);
        let checkedNickname = switch (checkEntry(nickname, address)) {
            case (#ok(l)) l;
            case (#err(e)) return #err(e);
        };
        let stored = { nickname = checkedNickname; address; updatedAt = now };
        user.byId.add(id, stored);
        #ok(toSaved(user, id, stored));
    };

    /// Deletes `owner`'s address `id`. If it was the default, there's no default until one is set.
    public func remove(state : AddressesByUser, owner : Principal, id : AddressId) : Result<(), AddressError> {
        let ?user = state.get(owner) else return #err(#NotFound);
        if (not user.byId.delete(id)) return #err(#NotFound);
        if (user.defaultId == ?id) user.defaultId := null;
        #ok;
    };

    /// Makes `owner`'s address `id` the default, or clears the default when `id` is null.
    public func setDefault(state : AddressesByUser, owner : Principal, id : ?AddressId) : Result<(), AddressError> {
        let ?user = state.get(owner) else {
            return if (id == null) #ok else #err(#NotFound);
        };
        switch (id) {
            case (?i) if (user.byId.get(i) == null) return #err(#NotFound);
            case null {};
        };
        user.defaultId := id;
        #ok;
    };

    /// `owner`'s addresses after id `after`, oldest first, a page at a time.
    public func list(state : AddressesByUser, owner : Principal, after : ?AddressId, limit : ?Nat) : Pagination.Page<SavedAddress, AddressId> {
        let ?user = state.get(owner) else return { items = []; next = null };
        let start = switch (after) { case (?a) a; case null 0 };
        Pagination.scan<(AddressId, StoredAddress), SavedAddress, AddressId>(
            user.byId.entriesFrom(start),
            func((id, _)) = id,
            Nat.compare,
            after,
            func((id, stored)) = ?toSaved(user, id, stored),
            limit,
        );
    };
};
