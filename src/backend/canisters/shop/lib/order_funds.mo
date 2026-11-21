import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat8 "mo:core/Nat8";

import Subaccount "../../../lib/Subaccount";
import OrderExpiry "./order_expiry";

/// Who the funds in an order's payment subaccount belong to (BRE-31). The shop owner may sweep them
/// into the main account only once the order is paid. Before that they are the buyer's payment in
/// progress, and after a cancellation they are the buyer's to reclaim. Pure, so it runs under `mops test`.
module OrderFunds {
    /// The order whose payment subaccount is `subaccount` (`Subaccount.fromNat32` of its ID), or null for
    /// any other account.
    public func orderIdOfSubaccount(subaccount : ?Blob) : ?Nat32 {
        let ?blob = subaccount else return null;
        let bytes = blob.toArray();
        if (bytes.size() != Subaccount.SIZE) {
            return null;
        };
        var id : Nat32 = 0;
        for (i in bytes.keys()) {
            if (i < 4) {
                id := (id << 8) | bytes[i].toNat().toNat32();
            } else if (bytes[i] != 0) {
                return null;
            };
        };
        // Order IDs start at 1, and an all-zero subaccount is the default (main) account.
        if (id == 0) null else ?id;
    };

    /// True when the shop owner may sweep a paid order's payment subaccount into the main account.
    public func canSweepToMain(status : OrderExpiry.OrderStatus) : Bool {
        switch (status) {
            case (#paid or #processing or #partiallyFulfilled or #fulfilled) true;
            case (#created or #awaitingPayment or #canceled or #refunded) false;
        };
    };

    /// Whether `transferFundsToMain` may sweep an account. `order` is the order the account pays, or
    /// null for an account that isn't an order's payment subaccount, which can always be swept.
    public func sweepDecision(order : ?{ id : Nat32; status : OrderExpiry.OrderStatus }) : { #ok; #err : Text } {
        let ?{ id; status } = order else return #ok;
        if (canSweepToMain(status)) {
            return #ok;
        };
        let label_ = "Order " # id.toText();
        #err(
            switch (status) {
                case (#canceled) label_ # " was canceled. Funds sent to it belong to the buyer, who can get them back with reclaimOrderPayment";
                case (#refunded) label_ # " was refunded. Funds left in its payment account belong to the buyer";
                case _ label_ # " is not paid yet. Its payment account can be moved to main once the order is paid";
            }
        );
    };
};
