import { expect } "mo:test";
import { suite; test } "mo:test";

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Base64 "mo:base64";

import DeliveryToken "../../../lib/DeliveryToken";
import Delivery "../lib/Delivery";

let secret : Blob = "0123456789abcdef0123456789abcdef";
let path = "/private/digital/1/2";

// The ticket format shop mints (lib/digital_delivery): version, expiry (u64 BE), key length
// (u32 BE), key, 16-byte nonce, then HMAC-SHA256 over all of that. Built here because shop's module
// imports canister aliases that tests don't have. Expires far in the future.
func mint(nonce : Blob) : Text = mintWith(secret, nonce);

func mintWith(signingKey : Blob, nonce : Blob) : Text {
    let exp : Nat64 = 1 << 40;
    let key = path.encodeUtf8().toArray();
    let keyLen = key.size().toNat32();
    let message = [1 : Nat8].concat(Array.tabulate<Nat8>(8, func i = ((exp >> (8 * (7 - i.toNat64()))) & 0xff).toNat().toNat8())).concat(Array.tabulate<Nat8>(4, func i = ((keyLen >> (8 * (3 - i.toNat32()))) & 0xff).toNat().toNat8())).concat(key).concat(nonce.toArray());
    let tag = DeliveryToken.computeTag(signingKey, message).toArray();
    Base64.Base64(#v("2"), ?true).encode(#bytes(message.concat(tag)));
};

func isOk(r : Delivery.Result) : Bool = switch r {
    case (#ok(_)) true;
    case (#err(_)) false;
};

func errText(r : Delivery.Result) : Text = switch r {
    case (#ok(_)) "ok";
    case (#err(e)) debug_show e;
};

suite(
    "Delivery.queryToken",
    func() {
        test(
            "finds the token parameter among others",
            func() {
                expect.option(Delivery.queryToken("/private/a?x=1&token=abc&y=2"), func(t : Text) : Text = t, func(a : Text, b : Text) : Bool = a == b).equal(?"abc");
                expect.option(Delivery.queryToken("/private/a?x=1"), func(t : Text) : Text = t, func(a : Text, b : Text) : Bool = a == b).isNull();
            },
        );
    },
);

suite(
    "Delivery.Gate",
    func() {
        test(
            "a ticket checks out any number of times until it is consumed, then is a replay",
            func() {
                let gate = Delivery.Gate(func() = ?secret);
                let token = mint("nonce-0000000001");
                expect.bool(isOk(gate.validate(token, path, false))).isTrue();
                expect.bool(isOk(gate.validate(token, path, true))).isTrue();
                expect.text(errText(gate.validate(token, path, false))).equal("#NonceReplay");
            },
        );
        test(
            "rejects another path, another key, or no key",
            func() {
                let token = mint("nonce-0000000002");
                expect.text(errText(Delivery.Gate(func() = ?secret).validate(token, "/private/other", true))).equal("#PathMismatch");
                expect.bool(isOk(Delivery.Gate(func() = ?("another secret, 32 bytes long!!!" : Blob)).validate(token, path, true))).isFalse();
                expect.text(errText(Delivery.Gate(func() = null).validate(token, path, true))).equal("#MissingKey");
            },
        );
        test(
            "rejects a ticket signed with the old placeholder key, or any key under 16 bytes (BRE-55)",
            func() {
                let placeholder : Blob = "\01\02\03\04";
                let token = mintWith(placeholder, "nonce-0000000003");
                expect.text(errText(Delivery.Gate(func() = ?placeholder).validate(token, path, true))).equal("#MissingKey");
                let short : Blob = "fifteen bytes!!";
                let shortToken = mintWith(short, "nonce-0000000004");
                expect.text(errText(Delivery.Gate(func() = ?short).validate(shortToken, path, true))).equal("#MissingKey");
            },
        );
        test(
            "a consumed ticket still continues its download, but can't start another",
            func() {
                let gate = Delivery.Gate(func() = ?secret);
                let token = mint("nonce-0000000099");
                expect.bool(isOk(gate.validate(token, path, true))).isTrue();
                expect.bool(isOk(gate.validateContinuation(token, path))).isTrue();
                expect.text(errText(gate.validate(token, path, false))).equal("#NonceReplay");
                expect.text(errText(gate.validateContinuation(token, "/private/other"))).equal("#PathMismatch");
            },
        );
    },
);
