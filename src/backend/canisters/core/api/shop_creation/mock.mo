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
    /// It is held on `depositCurrency`'s ledger: the other ledger reports 0 and refuses transfers,
    /// so a quote that reads or pays from the wrong ledger fails.
    public type MockLedgerState = {
        var balance : Nat;
        var depositCurrency : Currency;
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
            var depositCurrency = #ICP;
            var failTransfers = false;
            var trapTransfers = false;
            fee;
            transfers = List.empty();
        };
        let ledgers : Ledgers = {
            balanceOf = func(currency : Currency, _ : Account) : async Nat {
                if (currency == state.depositCurrency) { state.balance } else { 0 };
            };
            fee = func(_ : Currency) : async Nat { state.fee };
            transfer = func(currency : Currency, args : TransferArgs) : async Result<Nat, Text> {
                if (state.trapTransfers) {
                    Runtime.trap("ledger trapped");
                };
                if (state.failTransfers) {
                    return #err("transfer rejected");
                };
                if (currency != state.depositCurrency) {
                    return #err("insufficient funds");
                };
                List.add(state.transfers, { args with currency });
                state.balance -= args.amount + args.fee;
                #ok(List.size(state.transfers));
            };
        };
        { ledgers; state };
    };
};
