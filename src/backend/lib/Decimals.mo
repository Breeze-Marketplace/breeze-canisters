import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import { type Order } "mo:core/Order";

/// Amounts in minor units with a number of decimals, e.g. 150 with 2 decimals is 1.50.
module {
    /// Converts `amount` from `fromDecimals` to `toDecimals`. Rounds down when dropping digits.
    public func rescale(amount : Nat, fromDecimals : Nat32, toDecimals : Nat32) : Nat {
        if (toDecimals >= fromDecimals) {
            amount * 10 ** (toDecimals - fromDecimals).toNat();
        } else {
            amount / 10 ** (fromDecimals - toDecimals).toNat();
        };
    };

    /// Compares two amounts with different decimals exactly, by scaling both to the larger number of decimals.
    public func compare(a : Nat, aDecimals : Nat32, b : Nat, bDecimals : Nat32) : Order {
        let decimals = Nat32.max(aDecimals, bDecimals);
        Nat.compare(rescale(a, aDecimals, decimals), rescale(b, bDecimals, decimals));
    };
};
