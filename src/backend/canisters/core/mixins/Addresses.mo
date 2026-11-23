import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Time "mo:core/Time";
import Map "mo:map/Map";

import AddressesAPI "../api/addresses";
import Pagination "../../../lib/Pagination";
import Types "../types";

/// The caller's own saved shipping addresses (BRE-209; see `api/addresses`). Every method acts only on
/// the caller's addresses, with no principal argument, so no one can read or change another user's.
mixin (savedAddresses : AddressesAPI.AddressesByUser, userRegistry : Map.Map<Principal, Types.UserRegistryItem>) {
    func checkAddressOwner(caller : Principal) : Result<(), AddressesAPI.AddressError> {
        if (caller.isAnonymous()) return #err(#Unauthenticated);
        if (not Map.has(userRegistry, Map.phash, caller)) return #err(#NotRegistered);
        #ok;
    };

    /// Saves a shipping address with a nickname ("Home") for the caller, up to `MAX_ADDRESSES` (10). The
    /// first one saved, or one saved with `makeDefault`, becomes the default. The caller must be a
    /// registered user (`createUser`), never anonymous.
    public shared ({ caller }) func saveMyAddress(nickname : Text, address : AddressesAPI.ShippingAddress, makeDefault : Bool) : async Result<AddressesAPI.SavedAddress, AddressesAPI.AddressError> {
        switch (checkAddressOwner(caller)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        AddressesAPI.add(savedAddresses, caller, nickname, address, makeDefault, Time.now());
    };

    /// Replaces the nickname and address of the caller's saved address `id`. Registered users only.
    public shared ({ caller }) func updateMyAddress(id : AddressesAPI.AddressId, nickname : Text, address : AddressesAPI.ShippingAddress) : async Result<AddressesAPI.SavedAddress, AddressesAPI.AddressError> {
        switch (checkAddressOwner(caller)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        AddressesAPI.update(savedAddresses, caller, id, nickname, address, Time.now());
    };

    /// Deletes the caller's saved address `id`. Refuses anonymous callers.
    public shared ({ caller }) func deleteMyAddress(id : AddressesAPI.AddressId) : async Result<(), AddressesAPI.AddressError> {
        if (caller.isAnonymous()) return #err(#Unauthenticated);
        AddressesAPI.remove(savedAddresses, caller, id);
    };

    /// Makes the caller's saved address `id` the one checkout fills in, or clears the default when
    /// `id` is null. Refuses anonymous callers.
    public shared ({ caller }) func setMyDefaultAddress(id : ?AddressesAPI.AddressId) : async Result<(), AddressesAPI.AddressError> {
        if (caller.isAnonymous()) return #err(#Unauthenticated);
        AddressesAPI.setDefault(savedAddresses, caller, id);
    };

    /// The caller's saved addresses after id `after`, oldest first, a page at a time. Anonymous callers
    /// get an empty page.
    public query ({ caller }) func listMyAddresses(after : ?AddressesAPI.AddressId, limit : ?Nat) : async Pagination.Page<AddressesAPI.SavedAddress, AddressesAPI.AddressId> {
        if (caller.isAnonymous()) return { items = []; next = null };
        AddressesAPI.list(savedAddresses, caller, after, limit);
    };
};
