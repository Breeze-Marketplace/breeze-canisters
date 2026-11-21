import { expect } "mo:test";
import { suite; test } "mo:test";

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";

import WithdrawalAddresses "../withdrawal_addresses";

let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
let merchant = Principal.fromBlob(Blob.fromArray([1, 2, 3, 4]));
let other = Principal.fromBlob(Blob.fromArray([5, 6, 7, 8]));

func at(owner : Principal) : WithdrawalAddresses.Destination = {
    owner;
    subaccount = null;
};
func withSub(owner : Principal, last : Nat8) : WithdrawalAddresses.Destination {
    {
        owner;
        subaccount = ?Blob.fromArray(Array.tabulate<Nat8>(32, func(i) = if (i == 31) last else 0));
    };
};

func xs(n : Nat) : Text {
    var t = "";
    for (_ in Nat.range(0, n)) { t #= "x" };
    t;
};

func errorOf(result : { #ok : WithdrawalAddresses.WithdrawalAddress; #err : WithdrawalAddresses.SaveAddressError }) : Text {
    switch (result) {
        case (#ok(_)) "ok";
        case (#err(#InvalidDestination(_))) "InvalidDestination";
        case (#err(#InvalidName(_))) "InvalidName";
        case (#err(#LimitReached(_))) "LimitReached";
        case (#err(#Unauthorized(_))) "Unauthorized";
    };
};

suite(
    "save",
    func() {
        test(
            "adds an address with a trimmed name",
            func() {
                let book = WithdrawalAddresses.empty();
                expect.text(errorOf(WithdrawalAddresses.save(book, at(merchant), "  Cold wallet ", shopId, 10))).equal("ok");
                let list = WithdrawalAddresses.list(book);
                expect.nat(list.size()).equal(1);
                expect.text(list[0].name).equal("Cold wallet");
                expect.int(list[0].addedAt).equal(10);
            },
        );
        test(
            "renaming keeps when it was added",
            func() {
                let book = WithdrawalAddresses.empty();
                ignore WithdrawalAddresses.save(book, at(merchant), "Old", shopId, 10);
                ignore WithdrawalAddresses.save(book, at(merchant), "New", shopId, 99);
                let list = WithdrawalAddresses.list(book);
                expect.nat(list.size()).equal(1);
                expect.text(list[0].name).equal("New");
                expect.int(list[0].addedAt).equal(10);
            },
        );
        test(
            "an all-zero subaccount is the same account as none",
            func() {
                let book = WithdrawalAddresses.empty();
                ignore WithdrawalAddresses.save(book, at(merchant), "Main", shopId, 1);
                ignore WithdrawalAddresses.save(book, withSub(merchant, 0), "Renamed", shopId, 2);
                let list = WithdrawalAddresses.list(book);
                expect.nat(list.size()).equal(1);
                expect.text(list[0].name).equal("Renamed");
                expect.bool(list[0].subaccount == null).isTrue();
            },
        );
        test(
            "different subaccounts are different addresses",
            func() {
                let book = WithdrawalAddresses.empty();
                ignore WithdrawalAddresses.save(book, withSub(merchant, 1), "One", shopId, 1);
                ignore WithdrawalAddresses.save(book, withSub(merchant, 2), "Two", shopId, 2);
                expect.nat(WithdrawalAddresses.list(book).size()).equal(2);
            },
        );
        test(
            "refuses the shop itself, the anonymous principal and a short subaccount",
            func() {
                let book = WithdrawalAddresses.empty();
                expect.text(errorOf(WithdrawalAddresses.save(book, at(shopId), "Me", shopId, 1))).equal("InvalidDestination");
                expect.text(errorOf(WithdrawalAddresses.save(book, at(Principal.anonymous()), "Anon", shopId, 1))).equal("InvalidDestination");
                expect.text(errorOf(WithdrawalAddresses.save(book, { owner = merchant; subaccount = ?Blob.fromArray([1]) }, "Short", shopId, 1))).equal("InvalidDestination");
                expect.nat(WithdrawalAddresses.list(book).size()).equal(0);
            },
        );
        test(
            "refuses empty, long and multi-line names",
            func() {
                let book = WithdrawalAddresses.empty();
                expect.text(errorOf(WithdrawalAddresses.save(book, at(merchant), "   ", shopId, 1))).equal("InvalidName");
                let long = xs(WithdrawalAddresses.MAX_NAME_CHARS + 1);
                expect.text(errorOf(WithdrawalAddresses.save(book, at(merchant), long, shopId, 1))).equal("InvalidName");
                expect.text(errorOf(WithdrawalAddresses.save(book, at(merchant), "Cold\nwallet", shopId, 1))).equal("InvalidName");
                let longest = xs(WithdrawalAddresses.MAX_NAME_CHARS);
                expect.text(errorOf(WithdrawalAddresses.save(book, at(merchant), longest, shopId, 1))).equal("ok");
            },
        );
        test(
            "stops at MAX_ADDRESSES but still renames",
            func() {
                let book = WithdrawalAddresses.empty();
                for (i in Nat8.range(0, Nat8.fromNat(WithdrawalAddresses.MAX_ADDRESSES))) {
                    ignore WithdrawalAddresses.save(book, withSub(other, i + 1), "A", shopId, 1);
                };
                expect.nat(WithdrawalAddresses.list(book).size()).equal(WithdrawalAddresses.MAX_ADDRESSES);
                expect.text(errorOf(WithdrawalAddresses.save(book, at(merchant), "One more", shopId, 2))).equal("LimitReached");
                expect.text(errorOf(WithdrawalAddresses.save(book, withSub(other, 1), "Renamed", shopId, 2))).equal("ok");
            },
        );
    },
);

suite(
    "remove and list",
    func() {
        test(
            "removes a saved address, and reports one that isn't",
            func() {
                let book = WithdrawalAddresses.empty();
                ignore WithdrawalAddresses.save(book, at(merchant), "Main", shopId, 1);
                expect.bool(WithdrawalAddresses.remove(book, withSub(merchant, 0))).isTrue();
                expect.bool(WithdrawalAddresses.remove(book, at(merchant))).isFalse();
                expect.nat(WithdrawalAddresses.list(book).size()).equal(0);
            },
        );
        test(
            "lists oldest first",
            func() {
                let book = WithdrawalAddresses.empty();
                ignore WithdrawalAddresses.save(book, at(merchant), "Second", shopId, 20);
                ignore WithdrawalAddresses.save(book, at(other), "First", shopId, 10);
                let list = WithdrawalAddresses.list(book);
                expect.text(list[0].name).equal("First");
                expect.text(list[1].name).equal("Second");
            },
        );
    },
);
