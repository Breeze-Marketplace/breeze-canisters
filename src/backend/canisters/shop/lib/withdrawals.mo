import Int "mo:core/Int";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

/// Rules for withdrawing from the shop's main account to an account the merchant controls (BRE-76).
/// Pure, so it runs under `mops test`; `WalletApi.withdrawFunds` does the ledger calls.
module Withdrawals {
    /// An ICRC-1 account to withdraw to.
    public type Destination = { owner : Principal; subaccount : ?Blob };

    /// Why `withdrawFunds` refused or failed. Nothing was sent unless the variant says otherwise.
    public type WithdrawError = {
        #Unauthorized : Text;
        #UnsupportedToken : Text;
        #InvalidDestination : Text;
        #InvalidAmount : Text;
        /// The main account can't cover the amount plus the ledger fee.
        #InsufficientFunds : { balance : Nat; fee : Nat };
        /// Another withdrawal from this shop is in progress. Try again once it finishes.
        #Busy;
        /// The ledger refused the transfer (its error, as text).
        #TransferError : Text;
    };

    /// Checks the destination: a real ICRC-1 account outside this shop. The shop's own accounts are
    /// refused, since its subaccounts hold buyers' order payments (BRE-31), and the anonymous principal
    /// can't spend what it receives.
    public func checkDestination(to : Destination, shopId : Principal) : Result<(), Text> {
        if (to.owner.isAnonymous()) {
            return #err("The destination can't be the anonymous principal");
        };
        if (to.owner == shopId) {
            return #err("The destination must be outside this shop");
        };
        switch (to.subaccount) {
            case (?s) {
                if (s.size() != 32) {
                    return #err("A subaccount must be 32 bytes");
                };
            };
            case null {};
        };
        #ok;
    };

    /// The amount to send: `requested`, or with null everything the account holds minus the fee.
    /// Worked out from the live ledger `balance`, never stored state, so repeating a withdrawal of
    /// everything after the first went through finds nothing left to send.
    public func amountToSend(requested : ?Nat, balance : Nat, fee : Nat) : Result<Nat, WithdrawError> {
        switch (requested) {
            case null {
                if (balance <= fee) {
                    return #err(#InsufficientFunds({ balance; fee }));
                };
                #ok(balance - fee);
            };
            case (?amount) {
                if (amount == 0) {
                    return #err(#InvalidAmount("The amount must be greater than zero"));
                };
                if (amount > Nat64.maxValue.toNat()) {
                    return #err(#InvalidAmount("The amount is too large"));
                };
                if (amount + fee > balance) {
                    return #err(#InsufficientFunds({ balance; fee }));
                };
                #ok(amount);
            };
        };
    };

    /// The transfer's `created_at_time`: the caller's, or now. A client that retries after a timeout
    /// passes the same value, so the ledger reports the first transfer as a duplicate instead of
    /// sending twice (BRE-70).
    public func createdAt(requested : ?Nat64, now : Int) : Nat64 {
        switch (requested) {
            case (?t) t;
            case null Nat64.fromNat(Int.abs(now));
        };
    };
};
