import List "mo:core/List";
import { type Result } "mo:core/Result";

import Runtime "mo:core/Runtime";

import { type Account; type Currency; type Ledgers; type TransferArgs } "./lib";

module {
    public type MockedTransfer = {
        currency : Currency;
        fromSubaccount : Blob;
        to : Account;
        amount : Nat;
        fee : Nat;
        createdAtTime : Nat64;
    };

    /// One balance shared by every deposit account, which is enough for tests that use one quote at a time.
    public type MockLedgerState = {
        var balance : Nat;
        var failTransfers : Bool;
        /// Makes `transfer` trap before it moves anything, as a trapping ledger would.
        var trapTransfers : Bool;
        fee : Nat;
        transfers : List.List<MockedTransfer>;
    };

    public func mockLedgers(balance : Nat, fee : Nat) : {
        ledgers : Ledgers;
        state : MockLedgerState;
    } {
        let state : MockLedgerState = {
            var balance;
            var failTransfers = false;
            var trapTransfers = false;
            fee;
            transfers = List.empty();
        };
        let ledgers : Ledgers = {
            balanceOf = func(_ : Currency, _ : Account) : async Nat {
                state.balance;
            };
            fee = func(_ : Currency) : async Nat { state.fee };
            transfer = func(currency : Currency, args : TransferArgs) : async Result<Nat, Text> {
                if (state.trapTransfers) {
                    Runtime.trap("ledger trapped");
                };
                if (state.failTransfers) {
                    return #err("transfer rejected");
                };
                List.add(state.transfers, { args with currency });
                state.balance -= args.amount + args.fee;
                #ok(List.size(state.transfers));
            };
        };
        { ledgers; state };
    };
};
