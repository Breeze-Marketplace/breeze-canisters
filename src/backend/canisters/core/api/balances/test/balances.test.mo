import { expect } "mo:test";
import { suite; test } "mo:test/async";

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Set "mo:core/Set";

import BalancesAPI "../lib";

func sub(n : Nat) : Blob { Blob.fromArray([Nat8.fromNat(n)]) };

// Ledger mock for `read`: counts balance calls and returns whatever `funded` says for a subaccount.
type Counting = { ops : BalancesAPI.Operations; var calls : Nat };

func counting(funded : (?Blob) -> Nat) : Counting {
    let c : Counting = {
        var calls = 0;
        ops = {
            balances = func(subaccounts : [?Blob]) : async* [(Nat, Nat)] {
                // Never more ledger calls in flight than a batch's (BRE-109).
                assert subaccounts.size() <= BalancesAPI.BATCH_SIZE;
                c.calls += 2 * subaccounts.size();
                Array.map<?Blob, (Nat, Nat)>(subaccounts, func(s) = (funded(s), 0));
            };
        };
    };
    c;
};

// Deposit subaccount of quote `id`: two bytes, so IDs past 255 stay distinct.
func depositSub(id : Nat) : Blob {
    Blob.fromArray([Nat8.fromNat(id / 256), Nat8.fromNat(id % 256)]);
};

func depositId(b : Blob) : Nat {
    let bytes = b.toArray();
    Nat8.toNat(bytes[0]) * 256 + Nat8.toNat(bytes[1]);
};

// ICP balance = the subaccount's byte * 10, ckUSDC = its byte; the main account holds 1000 / 5.
let ops : BalancesAPI.Operations = {
    balances = func(subaccounts : [?Blob]) : async* [(Nat, Nat)] {
        Array.map<?Blob, (Nat, Nat)>(
            subaccounts,
            func(s) = switch (s) {
                case null (1000, 5);
                case (?b) {
                    let n = Nat8.toNat(b.toArray()[0]);
                    (n * 10, n);
                };
            },
        );
    };
};

suite(
    "BalancesAPI",
    func() : async () {
        await test(
            "lists the main account first, then quote deposits, and no user accounts (BRE-83)",
            func() : async () {
                let accounts = BalancesAPI.accounts(
                    [7, 8].vals(),
                    func(id) = sub(id),
                );
                expect.bool(Array.map<(BalancesAPI.AccountKind, ?Blob), BalancesAPI.AccountKind>(accounts, func((k, _)) = k) == [#main, #shopCreationDeposit(7), #shopCreationDeposit(8)]).isTrue();
            },
        );

        await test(
            "totals every account and lists only the main account and funded ones",
            func() : async () {
                let result = await* BalancesAPI.list(ops, [(#main, null), (#shopCreationDeposit(1), ?sub(0)), (#shopCreationDeposit(2), ?sub(2)), (#shopCreationDeposit(3), ?sub(3))], func(_) {});
                expect.nat(result.icp).equal(1000 + 20 + 30);
                expect.nat(result.ckusdc).equal(5 + 2 + 3);
                expect.bool(Array.map<BalancesAPI.AccountBalance, BalancesAPI.AccountKind>(result.accounts, func(a) = a.kind) == [#main, #shopCreationDeposit(2), #shopCreationDeposit(3)]).isTrue();
            },
        );

        await test(
            "reads more accounts than fit in one batch",
            func() : async () {
                let n = BalancesAPI.BATCH_SIZE * 2 + 5;
                let accounts = Array.tabulate<(BalancesAPI.AccountKind, ?Blob)>(n, func(i) = (#shopCreationDeposit(i), ?sub(1)));
                let result = await* BalancesAPI.list(ops, accounts, func(_) {});
                expect.nat(result.accounts.size()).equal(n);
                expect.nat(result.ckusdc).equal(n);
            },
        );

        await test(
            "after the first read, ledger calls track open and funded quotes, not every quote (BRE-101)",
            func() : async () {
                // 1000 settled quotes, of which 2 (IDs 10 and 20) still hold ICP; 3 open quotes (1000-1002).
                let quotes = 1003;
                let settled = func(id : Nat) : Bool = id < 1000;
                let ledger = counting(
                    func(s) = switch (s) {
                        case (?b) {
                            let id = depositId(b);
                            if (id == 10 or id == 20) 7 else 0;
                        };
                        case null 0;
                    }
                );
                let empty = Set.empty<Nat>();
                let deposits = func() : BalancesAPI.Deposits = {
                    ids = Nat.range(0, quotes);
                    settled;
                    empty;
                    subaccount = depositSub;
                };

                let first = await* BalancesAPI.read(ledger.ops, deposits());
                expect.nat(ledger.calls).equal(2 * (1 + quotes));
                expect.nat(first.icp).equal(14);
                expect.nat(Set.size(empty)).equal(998);

                ledger.calls := 0;
                let second = await* BalancesAPI.read(ledger.ops, deposits());
                // Main account, the 3 open quotes and the 2 funded settled ones.
                expect.nat(ledger.calls).equal(2 * (1 + 3 + 2));
                expect.nat(second.icp).equal(14);
                expect.bool(Array.map<BalancesAPI.AccountBalance, BalancesAPI.AccountKind>(second.accounts, func(a) = a.kind) == [#main, #shopCreationDeposit(10), #shopCreationDeposit(20)]).isTrue();
            },
        );

        await test(
            "keeps reading an open quote's empty deposit, and one that settles during the read",
            func() : async () {
                let ledger = counting(func(_) = 0);
                let empty = Set.empty<Nat>();
                // Quote 0 is open throughout; quote 1 settles once its balance has been read.
                var settledNow = false;
                let deposits : BalancesAPI.Deposits = {
                    ids = [0, 1].vals();
                    settled = func(id : Nat) : Bool = id == 1 and settledNow;
                    empty;
                    subaccount = depositSub;
                };
                let ops : BalancesAPI.Operations = {
                    balances = func(subaccounts : [?Blob]) : async* [(Nat, Nat)] {
                        let balances = await* ledger.ops.balances(subaccounts);
                        settledNow := true;
                        balances;
                    };
                };
                ignore await* BalancesAPI.read(ops, deposits);
                expect.nat(Set.size(empty)).equal(0);
            },
        );
    },
);
