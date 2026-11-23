import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";

import AddressesAPI "../lib";

let ada = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let bob = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");

let home : AddressesAPI.ShippingAddress = {
    name = "Ada Lovelace";
    phone = null;
    line1 = "1 Rue de Rivoli";
    line2 = null;
    city = "Paris";
    region = "";
    postalCode = "75001";
    country = "FR";
};

let work = {
    home with line1 = "10 Downing St";
    city = "London";
    postalCode = "SW1A 2AA";
    country = "GB";
};

func saved(r : { #ok : AddressesAPI.SavedAddress; #err : AddressesAPI.AddressError }) : AddressesAPI.SavedAddress {
    switch (r) {
        case (#ok(a)) a;
        case (#err(e)) Runtime.trap("expected ok, got " # debug_show e);
    };
};

func errOf<T>(r : { #ok : T; #err : AddressesAPI.AddressError }) : ?AddressesAPI.AddressError {
    switch (r) { case (#ok(_)) null; case (#err(e)) ?e };
};

func ids(state : AddressesAPI.AddressesByUser, user : Principal) : [Nat] {
    AddressesAPI.list(state, user, null, null).items.map(func(a : AddressesAPI.SavedAddress) : Nat = a.id);
};

func defaultOf(state : AddressesAPI.AddressesByUser, user : Principal) : ?Nat {
    for (a in AddressesAPI.list(state, user, null, null).items.values()) {
        if (a.isDefault) return ?a.id;
    };
    null;
};

func repeat(n : Nat) : Text {
    var t = "";
    for (_ in Nat.range(0, n)) t #= "x";
    t;
};

suite(
    "Saved addresses",
    func() {
        test(
            "saves, lists oldest first, and makes the first one the default",
            func() {
                let state = AddressesAPI.empty();
                let a = saved(AddressesAPI.add(state, ada, "  Home ", home, false, 1));
                let b = saved(AddressesAPI.add(state, ada, "Work", work, false, 2));
                expect.text(a.nickname).equal("Home");
                expect.bool(a.isDefault).isTrue();
                expect.bool(b.isDefault).isFalse();
                expect.array(ids(state, ada), Nat.toText, Nat.equal).equal([a.id, b.id]);
                expect.bool(defaultOf(state, ada) == ?a.id).isTrue();
            },
        );

        test(
            "saving with makeDefault moves the default",
            func() {
                let state = AddressesAPI.empty();
                ignore saved(AddressesAPI.add(state, ada, "Home", home, false, 1));
                let b = saved(AddressesAPI.add(state, ada, "Work", work, true, 2));
                expect.bool(defaultOf(state, ada) == ?b.id).isTrue();
            },
        );

        test(
            "updates the nickname and address but keeps the default",
            func() {
                let state = AddressesAPI.empty();
                let a = saved(AddressesAPI.add(state, ada, "Home", home, false, 1));
                let u = saved(AddressesAPI.update(state, ada, a.id, "Flat", work, 5));
                expect.text(u.nickname).equal("Flat");
                expect.text(u.address.city).equal("London");
                expect.int(u.updatedAt).equal(5);
                expect.bool(u.isDefault).isTrue();
            },
        );

        test(
            "deleting the default leaves no default, and ids are not reused",
            func() {
                let state = AddressesAPI.empty();
                let a = saved(AddressesAPI.add(state, ada, "Home", home, false, 1));
                let b = saved(AddressesAPI.add(state, ada, "Work", work, false, 2));
                expect.bool(AddressesAPI.remove(state, ada, a.id) == #ok).isTrue();
                expect.bool(defaultOf(state, ada) == null).isTrue();
                ignore AddressesAPI.remove(state, ada, b.id);
                let c = saved(AddressesAPI.add(state, ada, "Home", home, false, 3));
                expect.bool(c.id > b.id).isTrue();
                expect.bool(c.isDefault).isTrue();
            },
        );

        test(
            "sets and clears the default, refusing an unknown id",
            func() {
                let state = AddressesAPI.empty();
                let a = saved(AddressesAPI.add(state, ada, "Home", home, false, 1));
                let b = saved(AddressesAPI.add(state, ada, "Work", work, false, 2));
                expect.bool(AddressesAPI.setDefault(state, ada, ?b.id) == #ok).isTrue();
                expect.bool(defaultOf(state, ada) == ?b.id).isTrue();
                expect.bool(AddressesAPI.setDefault(state, ada, null) == #ok).isTrue();
                expect.bool(defaultOf(state, ada) == null).isTrue();
                expect.bool(errOf(AddressesAPI.setDefault(state, ada, ?99)) == ?#NotFound).isTrue();
                ignore a;
            },
        );

        test(
            "a new address doesn't replace a default the owner cleared or deleted",
            func() {
                let state = AddressesAPI.empty();
                let a = saved(AddressesAPI.add(state, ada, "Home", home, false, 1));
                ignore saved(AddressesAPI.add(state, ada, "Work", work, false, 2));
                expect.bool(AddressesAPI.setDefault(state, ada, null) == #ok).isTrue();
                let c = saved(AddressesAPI.add(state, ada, "Cabin", home, false, 3));
                expect.bool(c.isDefault).isFalse();
                expect.bool(defaultOf(state, ada) == null).isTrue();
                ignore AddressesAPI.remove(state, ada, a.id);
                let d = saved(AddressesAPI.add(state, ada, "Studio", work, false, 4));
                expect.bool(d.isDefault).isFalse();
            },
        );

        test(
            "one user can't see, change or delete another's addresses",
            func() {
                let state = AddressesAPI.empty();
                let a = saved(AddressesAPI.add(state, ada, "Home", home, false, 1));
                expect.nat(AddressesAPI.list(state, bob, null, null).items.size()).equal(0);
                expect.bool(errOf(AddressesAPI.update(state, bob, a.id, "Mine", work, 2)) == ?#NotFound).isTrue();
                expect.bool(errOf(AddressesAPI.remove(state, bob, a.id)) == ?#NotFound).isTrue();
                expect.bool(errOf(AddressesAPI.setDefault(state, bob, ?a.id)) == ?#NotFound).isTrue();
                // Bob's own first address doesn't touch Ada's.
                ignore saved(AddressesAPI.add(state, bob, "Home", work, false, 3));
                expect.text(AddressesAPI.list(state, ada, null, null).items[0].address.city).equal("Paris");
            },
        );

        test(
            "stops at MAX_ADDRESSES",
            func() {
                let state = AddressesAPI.empty();
                for (i in Nat.range(0, AddressesAPI.MAX_ADDRESSES)) {
                    ignore saved(AddressesAPI.add(state, ada, "A" # Nat.toText(i), home, false, i));
                };
                expect.bool(errOf(AddressesAPI.add(state, ada, "One more", home, false, 99)) == ?#LimitReached(AddressesAPI.MAX_ADDRESSES)).isTrue();
            },
        );

        test(
            "refuses bad nicknames and addresses",
            func() {
                let state = AddressesAPI.empty();
                func refusedNickname(nickname : Text) : Bool {
                    switch (AddressesAPI.add(state, ada, nickname, home, false, 1)) {
                        case (#err(#InvalidNickname(_))) true;
                        case _ false;
                    };
                };
                func refusedAddress(address : AddressesAPI.ShippingAddress) : Bool {
                    switch (AddressesAPI.add(state, ada, "Home", address, false, 1)) {
                        case (#err(#InvalidAddress(_))) true;
                        case _ false;
                    };
                };
                expect.bool(refusedNickname("   ")).isTrue();
                expect.bool(refusedNickname(repeat(AddressesAPI.MAX_NICKNAME_CHARS + 1))).isTrue();
                expect.bool(refusedNickname("Home\nWork")).isTrue();
                expect.bool(refusedAddress({ home with city = repeat(201) })).isTrue();
                expect.bool(refusedAddress({ home with phone = ?repeat(201) })).isTrue();
                expect.bool(refusedAddress({ home with country = "France" })).isTrue();
                expect.bool(refusedAddress({ home with name = "" })).isTrue();
                expect.nat(AddressesAPI.list(state, ada, null, null).items.size()).equal(0);
            },
        );

        test(
            "pages by id",
            func() {
                let state = AddressesAPI.empty();
                for (i in Nat.range(0, 5)) {
                    ignore saved(AddressesAPI.add(state, ada, "A" # Nat.toText(i), home, false, i));
                };
                let first = AddressesAPI.list(state, ada, null, ?2);
                expect.nat(first.items.size()).equal(2);
                expect.bool(first.next == ?1).isTrue();
                let rest = AddressesAPI.list(state, ada, first.next, ?10);
                expect.array(rest.items.map(func(a : AddressesAPI.SavedAddress) : Nat = a.id), Nat.toText, Nat.equal).equal([2, 3, 4]);
                expect.bool(rest.next == null).isTrue();
            },
        );
    },
);
