import { expect } "mo:test";
import { suite; test } "mo:test";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";

import Subaccount "../Subaccount";

suite(
    "Subaccount.fromPrincipal",
    func() {
        test(
            "starts with the principal's length, then its bytes, zero-padded to 32",
            func() {
                let principal = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
                let bytes = principal.toBlob().toArray();
                let sub = Subaccount.fromPrincipal(principal).toArray();
                expect.nat(sub.size()).equal(32);
                expect.nat(sub[0].toNat()).equal(bytes.size());
                for (i in bytes.keys()) {
                    expect.nat(sub[i + 1].toNat()).equal(bytes[i].toNat());
                };
                expect.nat(sub[31].toNat()).equal(0);
            },
        );
    },
);

suite(
    "Subaccount.fromNat32",
    func() {
        test(
            "puts the ID's bytes first, most significant first, zero-padded to 32",
            func() {
                let sub = Subaccount.fromNat32(0x01020304).toArray();
                expect.nat(sub.size()).equal(32);
                expect.nat(sub[0].toNat()).equal(1);
                expect.nat(sub[1].toNat()).equal(2);
                expect.nat(sub[2].toNat()).equal(3);
                expect.nat(sub[3].toNat()).equal(4);
                expect.nat(sub[4].toNat()).equal(0);
                expect.nat(sub[31].toNat()).equal(0);
            },
        );
    },
);
