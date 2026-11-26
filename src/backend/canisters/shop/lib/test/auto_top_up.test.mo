import { expect; suite; test } "mo:test/async";

import Error "mo:core/Error";
import List "mo:core/List";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";

import AutoTopUp "../auto_top_up";

let T = 1_000_000_000_000;
let ICP = 100_000_000;
let FEE = 10_000;
let DAY : Int = 86_400_000_000_000;

let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
let vaultId = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");

let settings : AutoTopUp.TopUpSettings = {
    thresholdCycles = 2 * T;
    topUpE8s = 1 * ICP;
    maxE8sPer30Days = 3 * ICP;
};

/// A fake shop, vault, ledger and CMC. Transfers debit `mainE8s`; `notifyAnswers` are given out in
/// order (then `#minted`), and a minted top-up credits the canister 1T cycles per ICP.
type World = {
    var shopCycles : Nat;
    var vaultCycles : ?Nat;
    var mainE8s : Nat;
    var now : Int;
    var nextBlock : Nat;
    var failTransfer : Bool;
    notifyAnswers : List.List<AutoTopUp.NotifyResult>;
    transfers : List.List<{ canisterId : Principal; e8s : Nat }>;
    var notifyCalls : Nat;
    /// Transfers the CMC hasn't minted yet: block, canister, e8s.
    pendingCredit : List.List<(Nat, Principal, Nat)>;
    /// Run during the first ledger read and the next vault read, to change state mid-run.
    var duringLedgerRead : ?(() -> ());
    var duringVaultRead : ?(() -> ());
    /// The shop's linked vault, read live by the run.
    var linkedVault : ?Principal;
};

func world() : World = {
    var shopCycles = 5 * T;
    var vaultCycles = ?(5 * T);
    var mainE8s = 10 * ICP;
    var now = 100 * DAY;
    var nextBlock = 1;
    var failTransfer = false;
    notifyAnswers = List.empty();
    transfers = List.empty();
    var notifyCalls = 0;
    pendingCredit = List.empty();
    var duringLedgerRead = null;
    var duringVaultRead = null;
    var linkedVault = ?vaultId;
};

func runOnceWithoutVault(w : World, state : AutoTopUp.State) : async* AutoTopUp.TopUpRun {
    w.linkedVault := null;
    await* AutoTopUp.run(ops(w), state, shopId, func() = w.linkedVault, #timer);
};

func runOnce(w : World, state : AutoTopUp.State, trigger : AutoTopUp.TopUpTrigger) : async* AutoTopUp.TopUpRun {
    await* AutoTopUp.run(ops(w), state, shopId, func() = w.linkedVault, trigger);
};

func ops(w : World) : AutoTopUp.Operations {
    {
        ownBalance = func() : Nat = w.shopCycles;
        vaultBalance = func(_ : Principal) : async* Nat {
            switch (w.duringVaultRead) {
                case (?f) { w.duringVaultRead := null; f() };
                case null {};
            };
            switch (w.vaultCycles) {
                case (?cycles) cycles;
                case null throw Error.reject("no such method");
            };
        };
        mainBalanceE8s = func() : async* Nat {
            switch (w.duringLedgerRead) {
                case (?f) { w.duringLedgerRead := null; f() };
                case null {};
            };
            w.mainE8s;
        };
        feeE8s = func() : async* Nat = FEE;
        transferToCmc = func(canisterId : Principal, e8s : Nat, fee : Nat, _ : Nat64) : async* {
            #ok : Nat;
            #err : Text;
        } {
            if (w.failTransfer) return #err("ledger said no");
            w.mainE8s -= e8s + fee;
            w.transfers.add({ canisterId; e8s });
            let block = w.nextBlock;
            w.nextBlock += 1;
            w.pendingCredit.add((block, canisterId, e8s));
            #ok(block);
        };
        notifyTopUp = func(blockIndex : Nat, canisterId : Principal) : async* AutoTopUp.NotifyResult {
            w.notifyCalls += 1;
            let answer = switch (w.notifyAnswers.removeLast()) {
                case (?a) a;
                case null #minted(0);
            };
            switch (answer) {
                case (#minted(_)) {
                    var e8s = 0;
                    for ((block, _, amount) in w.pendingCredit.values()) if (block == blockIndex) e8s := amount;
                    let cycles = e8s * T / ICP;
                    if (canisterId == shopId) w.shopCycles += cycles else if (canisterId == vaultId) {
                        switch (w.vaultCycles) {
                            case (?v) w.vaultCycles := ?(v + cycles);
                            case null {};
                        };
                    };
                    #minted(cycles);
                };
                case other other;
            };
        };
        now = func() : Int = w.now;
    };
};

/// Queues CMC answers; they're handed out first to last.
func answers(w : World, list : [AutoTopUp.NotifyResult]) {
    var i = list.size();
    while (i > 0) {
        i -= 1;
        w.notifyAnswers.add(list[i]);
    };
};

func enabled() : AutoTopUp.State {
    let state = AutoTopUp.empty();
    state.settings := ?settings;
    state;
};

func statusOf(run : AutoTopUp.TopUpRun, kind : AutoTopUp.CanisterKind) : AutoTopUp.TopUpCheckStatus {
    for (check in run.checks.values()) if (check.kind == kind) return check.status;
    Runtime.trap("no check for " # debug_show (kind));
};

await suite(
    "validate",
    func() : async () {
        await test(
            "accepts settings within the limits",
            func() : async () {
                assert AutoTopUp.validate(settings) == #ok;
            },
        );
        await test(
            "refuses a cap below one top-up and out-of-range values",
            func() : async () {
                assert AutoTopUp.validate({
                    settings with maxE8sPer30Days = ICP / 2
                }) != #ok;
                assert AutoTopUp.validate({ settings with topUpE8s = ICP / 100 }) != #ok;
                assert AutoTopUp.validate({
                    settings with thresholdCycles = 100 * T
                }) != #ok;
                assert AutoTopUp.validate({ settings with thresholdCycles = 0 }) != #ok;
            },
        );
    },
);

await suite(
    "plan",
    func() : async () {
        await test(
            "leaves a canister at or above the threshold alone",
            func() : async () {
                assert AutoTopUp.plan(settings, AutoTopUp.empty(), shopId, 2 * T, 0) == #healthy;
            },
        );
        await test(
            "tops up by topUpE8s, or what the cap leaves",
            func() : async () {
                let state = AutoTopUp.empty();
                assert AutoTopUp.plan(settings, state, shopId, T, 0) == #topUp(ICP);
                assert AutoTopUp.plan({ settings with maxE8sPer30Days = ICP + ICP / 2; topUpE8s = ICP }, state, shopId, T, 0) == #topUp(ICP);
            },
        );
        await test(
            "refuses when the main account can't cover the top-up and fee",
            func() : async () {
                assert AutoTopUp.fundsShortfall(ICP, FEE, ICP) == ?#insufficientFunds({
                    balance = ICP;
                    needed = ICP + FEE;
                });
                assert AutoTopUp.fundsShortfall(ICP, FEE, ICP + FEE) == null;
            },
        );
    },
);

await suite(
    "run",
    func() : async () {
        await test(
            "does nothing while off",
            func() : async () {
                let w = world();
                w.shopCycles := 0;
                let run = await* runOnce(w, AutoTopUp.empty(), #timer);
                assert run.checks.size() == 0;
                assert w.transfers.size() == 0;
            },
        );
        await test(
            "tops up a low shop and leaves a healthy vault",
            func() : async () {
                let w = world();
                w.shopCycles := T;
                let state = enabled();
                let run = await* runOnce(w, state, #timer);
                assert statusOf(run, #shop) == #toppedUp({
                    e8s = ICP;
                    outcome = #minted(T);
                });
                assert statusOf(run, #vault) == #healthy;
                expect.nat(w.mainE8s).equal(9 * ICP - FEE);
                expect.nat(w.shopCycles).equal(2 * T);
                let page = AutoTopUp.page(state, null, null);
                expect.nat(page.items.size()).equal(1);
                assert page.items[0].outcome == #minted(T);
            },
        );
        await test(
            "stops at the 30-day cap, and the window slides",
            func() : async () {
                let w = world();
                let state = enabled();
                for (_ in [1, 2, 3, 4].values()) {
                    w.shopCycles := 0;
                    ignore await* runOnceWithoutVault(w, state);
                    w.now += DAY;
                };
                expect.nat(w.transfers.size()).equal(3);
                w.shopCycles := 0;
                let capped = await* runOnceWithoutVault(w, state);
                assert statusOf(capped, #shop) == #skipped(#capReached);
                w.now += 30 * DAY;
                let later = await* runOnceWithoutVault(w, state);
                assert statusOf(later, #shop) == #toppedUp({
                    e8s = ICP;
                    outcome = #minted(T);
                });
            },
        );
        await test(
            "skips when the main account is short, sending nothing",
            func() : async () {
                let w = world();
                w.shopCycles := 0;
                w.mainE8s := ICP;
                let run = await* runOnceWithoutVault(w, enabled());
                assert statusOf(run, #shop) == #skipped(#insufficientFunds({ balance = ICP; needed = ICP + FEE }));
                expect.nat(w.transfers.size()).equal(0);
            },
        );
        await test(
            "a refused transfer isn't logged",
            func() : async () {
                let w = world();
                w.shopCycles := 0;
                w.failTransfer := true;
                let state = enabled();
                let run = await* runOnceWithoutVault(w, state);
                assert statusOf(run, #shop) == #transferFailed("ledger said no");
                expect.nat(AutoTopUp.page(state, null, null).items.size()).equal(0);
            },
        );
        await test(
            "an unanswered notification is retried next run, and blocks another top-up meanwhile",
            func() : async () {
                let w = world();
                w.shopCycles := 0;
                let state = enabled();
                answers(w, [#retry("timeout"), #retry("still"), #minted(0)]);
                let first = await* runOnceWithoutVault(w, state);
                assert statusOf(first, #shop) == #toppedUp({
                    e8s = ICP;
                    outcome = #notifying;
                });
                let second = await* runOnceWithoutVault(w, state);
                assert second.resolved == 0;
                assert statusOf(second, #shop) == #skipped(#notifyPending);
                expect.nat(w.transfers.size()).equal(1);
                let third = await* runOnceWithoutVault(w, state);
                assert third.resolved == 1;
                let original = AutoTopUp.page(state, null, null).items[1];
                assert original.id == 0;
                assert original.outcome == #minted(T);
                // The confirmed cycles count before the check: 1T is still under the 2T threshold.
                assert statusOf(third, #shop) == #toppedUp({
                    e8s = ICP;
                    outcome = #minted(T);
                });
            },
        );
        await test(
            "retries pending notifications even after auto top-up is turned off",
            func() : async () {
                let w = world();
                w.shopCycles := 0;
                let state = enabled();
                answers(w, [#retry("timeout"), #refunded("too small")]);
                ignore await* runOnceWithoutVault(w, state);
                state.settings := null;
                let run = await* runOnceWithoutVault(w, state);
                assert run.resolved == 1;
                assert AutoTopUp.page(state, null, null).items[0].outcome == #refunded("too small");
            },
        );
        await test(
            "gives up on a notification after MAX_NOTIFY_ATTEMPTS",
            func() : async () {
                let w = world();
                w.shopCycles := 0;
                let state = enabled();
                state.settings := ?{
                    settings with thresholdCycles = AutoTopUp.limits.minThresholdCycles
                };
                var i = 0;
                while (i < AutoTopUp.MAX_NOTIFY_ATTEMPTS) {
                    w.notifyAnswers.add(#retry("no answer"));
                    i += 1;
                };
                ignore await* runOnceWithoutVault(w, state);
                state.settings := null;
                var runs = 1;
                while (runs < AutoTopUp.MAX_NOTIFY_ATTEMPTS) {
                    ignore await* runOnceWithoutVault(w, state);
                    runs += 1;
                };
                switch (AutoTopUp.page(state, null, null).items[0].outcome) {
                    case (#failed(_)) {};
                    case other Runtime.trap("expected #failed, got " # debug_show (other));
                };
            },
        );
        await test(
            "stops when turned off during the ledger read",
            func() : async () {
                let w = world();
                w.shopCycles := 0;
                let state = enabled();
                w.duringLedgerRead := ?(func() { state.settings := null });
                let run = await* runOnce(w, state, #timer);
                assert run.checks.size() == 0;
                expect.nat(w.transfers.size()).equal(0);
            },
        );
        await test(
            "an older vault without getCyclesBalance doesn't stop the shop's check",
            func() : async () {
                let w = world();
                w.shopCycles := 0;
                w.vaultCycles := null;
                let run = await* runOnce(w, enabled(), #timer);
                assert statusOf(run, #shop) == #toppedUp({
                    e8s = ICP;
                    outcome = #minted(T);
                });
                switch (statusOf(run, #vault)) {
                    case (#balanceUnavailable(_)) {};
                    case other Runtime.trap("expected #balanceUnavailable, got " # debug_show (other));
                };
            },
        );
        await test(
            "doesn't top up a vault the Owner unlinked during the run",
            func() : async () {
                let w = world();
                w.vaultCycles := ?0;
                let otherVault = Principal.fromText("r7inp-6aaaa-aaaaa-aaabq-cai");
                w.duringLedgerRead := ?(func() { w.linkedVault := ?otherVault });
                let run = await* runOnce(w, enabled(), #timer);
                assert run.checks.size() == 1;
                expect.nat(w.transfers.size()).equal(0);
            },
        );
        await test(
            "applies a threshold raised during the vault's balance read",
            func() : async () {
                let w = world();
                let state = enabled();
                w.duringVaultRead := ?(func() { state.settings := ?{ settings with thresholdCycles = 20 * T } });
                let run = await* runOnce(w, state, #timer);
                assert statusOf(run, #vault) == #toppedUp({
                    e8s = ICP;
                    outcome = #minted(T);
                });
            },
        );
        await test(
            "rechecks the shop's balance after the ledger reads",
            func() : async () {
                let w = world();
                w.shopCycles := T;
                w.duringLedgerRead := ?(func() { w.shopCycles := 5 * T });
                let run = await* runOnceWithoutVault(w, enabled());
                assert statusOf(run, #shop) == #healthy;
                expect.nat(w.transfers.size()).equal(0);
            },
        );
        await test(
            "tops up a low vault through its own CMC account",
            func() : async () {
                let w = world();
                w.vaultCycles := ?0;
                let run = await* runOnce(w, enabled(), #timer);
                assert statusOf(run, #vault) == #toppedUp({
                    e8s = ICP;
                    outcome = #minted(T);
                });
                assert w.transfers.get(0) == ?{
                    canisterId = vaultId;
                    e8s = ICP;
                };
            },
        );
    },
);

await suite(
    "page",
    func() : async () {
        await test(
            "lists newest first and pages with the cursor",
            func() : async () {
                let w = world();
                let state = enabled();
                state.settings := ?{ settings with maxE8sPer30Days = 100 * ICP };
                for (_ in [1, 2, 3].values()) {
                    w.shopCycles := 0;
                    ignore await* runOnceWithoutVault(w, state);
                };
                let first = AutoTopUp.page(state, null, ?2);
                assert first.items.size() == 2;
                assert first.items[0].id == 2;
                assert first.next == ?1;
                let second = AutoTopUp.page(state, first.next, ?2);
                assert second.items.size() == 1;
                assert second.items[0].id == 0;
                assert second.next == null;
            },
        );
    },
);

await suite(
    "classifyNotify",
    func() : async () {
        await test(
            "sorts the CMC's answers",
            func() : async () {
                assert AutoTopUp.classifyNotify(#Ok(5)) == #minted(5);
                assert AutoTopUp.classifyNotify(#Err(#Refunded({ reason = "x"; block_index = null }))) == #refunded("x");
                assert AutoTopUp.classifyNotify(#Err(#Processing)) == #retry("The CMC is still processing the block");
                switch (AutoTopUp.classifyNotify(#Err(#TransactionTooOld(1)))) {
                    case (#failed(_)) {};
                    case _ Runtime.trap("expected #failed");
                };
            },
        );
    },
);
