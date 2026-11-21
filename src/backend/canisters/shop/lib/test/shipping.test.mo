import { suite; test } "mo:test";
import Nat "mo:core/Nat";

import Shipping "../shipping";

let address = {
    name = "Ada Lovelace";
    line1 = "1 Rue de Rivoli";
    line2 = null;
    city = "Paris";
    region = "";
    postalCode = "75001";
    country = "FR";
    phone = null;
};

func isErr<T>(r : { #ok : T; #err : Text }) : Bool {
    switch (r) { case (#err(_)) true; case (#ok(_)) false };
};

suite(
    "Shipping.anyRequiresShipping",
    func() {
        test(
            "needs shipping only when a physical item is in the cart",
            func() {
                assert not Shipping.anyRequiresShipping([#Digital, #Service]);
                assert not Shipping.anyRequiresShipping([]);
                assert Shipping.anyRequiresShipping([#Digital, #Physical]);
            },
        );
    },
);

suite(
    "Shipping.validateAddress",
    func() {
        test(
            "accepts a non-US address with no region",
            func() {
                assert not isErr(Shipping.validateAddress(address));
            },
        );
        test(
            "rejects a missing name, street or city",
            func() {
                assert isErr(Shipping.validateAddress({ address with name = " " }));
                assert isErr(Shipping.validateAddress({ address with line1 = "" }));
                assert isErr(Shipping.validateAddress({ address with city = "" }));
            },
        );
        test(
            "rejects country names and lowercase codes",
            func() {
                assert isErr(Shipping.validateAddress({ address with country = "France" }));
                assert isErr(Shipping.validateAddress({ address with country = "fr" }));
                assert isErr(Shipping.validateAddress({ address with country = "" }));
            },
        );
        test(
            "rejects overlong fields",
            func() {
                var long = "";
                for (_ in Nat.range(0, Shipping.MAX_FIELD_LENGTH + 1)) long #= "x";
                assert isErr(Shipping.validateAddress({ address with line1 = long }));
                assert isErr(Shipping.validateAddress({ address with line2 = ?long }));
            },
        );
    },
);

suite(
    "Shipping.addressForOrder",
    func() {
        test(
            "drops the address of a digital-only order",
            func() {
                assert Shipping.addressForOrder(false, ?address) == #ok(null);
                assert Shipping.addressForOrder(false, null) == #ok(null);
            },
        );
        test(
            "requires a valid address when something ships",
            func() {
                assert isErr(Shipping.addressForOrder(true, null));
                assert isErr(Shipping.addressForOrder(true, ?{ address with country = "USA" }));
                assert Shipping.addressForOrder(true, ?address) == #ok(?address);
            },
        );
    },
);
