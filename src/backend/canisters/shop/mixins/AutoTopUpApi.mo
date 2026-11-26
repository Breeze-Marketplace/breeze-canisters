import Cycles "mo:core/Cycles";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Time "mo:core/Time";

import Ledger "canister:icp_ledger";

import Cmc "../../../interfaces/cmc";
import Logger "../../../lib/Logger";
import Pagination "../../../lib/Pagination";
import AuthService "../lib/auth";
import AutoTopUp "../lib/auto_top_up";
import ShopPermissions "../lib/permissions";
import { type MediaSettings } "../types";

/// Automatic cycle top-ups of the shop and its vault from the main account's ICP (BRE-212). The
/// Owner turns it on and runs it; `Funds.View` reads it. `main.mo` runs it hourly.
mixin (
    autoTopUp : AutoTopUp.State,
    autoTopUpRun : AutoTopUp.TopUpRunState,
    media : MediaSettings,
    authService : AuthService.AuthService,
    shopId : Principal,
    logger : Logger.BoundLogger,
) {
    public type AutoTopUpStatus = {
        settings : ?AutoTopUp.TopUpSettings;
        limits : AutoTopUp.TopUpLimits;
        /// ICP converted and top-ups made in the last 30 days, against the cap.
        spentLast30Days : { e8s : Nat; count : Nat };
        running : Bool;
        /// Transient: an upgrade clears it until the next run.
        lastRun : ?AutoTopUp.TopUpRun;
    };

    public type SetAutoTopUpError = {
        #Unauthorized : Text;
        #InvalidSettings : Text;
    };

    public type RunAutoTopUpError = { #Unauthorized : Text; #Busy };

    type VaultCycles = actor { getCyclesBalance : shared query () -> async Nat };

    /// Seconds before a read of the vault or the ledger, or a CMC notification, gives up, so none
    /// can hold up a run or an upgrade. The ledger transfer waits for its answer: a timed-out
    /// transfer can't say whether the ICP left.
    transient let callTimeoutSeconds : Nat32 = 30;

    func autoTopUpOperations() : AutoTopUp.Operations {
        let mainAccount : Ledger.Account = { owner = shopId; subaccount = null };
        {
            ownBalance = func() : Nat = Cycles.balance();
            vaultBalance = func(vaultId : Principal) : async* Nat {
                let vault = actor (vaultId.toText()) : VaultCycles;
                await (with timeout = callTimeoutSeconds) vault.getCyclesBalance();
            };
            mainBalanceE8s = func() : async* Nat {
                await (with timeout = callTimeoutSeconds) Ledger.icrc1_balance_of(mainAccount);
            };
            feeE8s = func() : async* Nat {
                await (with timeout = callTimeoutSeconds) Ledger.icrc1_fee();
            };
            transferToCmc = func(canisterId : Principal, e8s : Nat, fee : Nat, createdAtTime : Nat64) : async* Result<Nat, Text> {
                let result = await Ledger.icrc1_transfer({
                    to = {
                        owner = Principal.fromText(Cmc.CANISTER_ID);
                        subaccount = ?Cmc.topUpSubaccount(canisterId);
                    };
                    amount = e8s;
                    fee = ?fee;
                    memo = ?Cmc.TOP_UP_MEMO;
                    from_subaccount = null;
                    created_at_time = ?createdAtTime;
                });
                switch (result) {
                    case (#Ok(blockIndex)) #ok(blockIndex);
                    case (#Err(e)) #err(debug_show (e));
                };
            };
            notifyTopUp = func(blockIndex : Nat, canisterId : Principal) : async* AutoTopUp.NotifyResult {
                let answer = await (with timeout = callTimeoutSeconds) Cmc.cmc().notify_top_up({
                    block_index = Nat64.fromNat(blockIndex);
                    canister_id = canisterId;
                });
                AutoTopUp.classifyNotify(answer);
            };
            now = func() : Int = Time.now();
        };
    };

    /// One run, unless one is in progress (null then). The timer calls this too.
    func runAutoTopUpOnce(trigger : AutoTopUp.TopUpTrigger) : async* ?AutoTopUp.TopUpRun {
        if (autoTopUpRun.running) return null;
        autoTopUpRun.running := true;
        try {
            let run = await* AutoTopUp.run(autoTopUpOperations(), autoTopUp, shopId, func() = media.mediaCanisterId, trigger);
            for (check in run.checks.values()) {
                switch (check.status) {
                    case (#toppedUp({ e8s; outcome })) {
                        logger.info("Auto top-up: sent " # debug_show (e8s) # " e8s to the CMC for the " # debug_show (check.kind) # " (" # debug_show (outcome) # ")");
                    };
                    case (#transferFailed(message)) {
                        logger.warning("Auto top-up of the " # debug_show (check.kind) # " failed: " # message);
                    };
                    case _ {};
                };
            };
            autoTopUpRun.lastRun := ?run;
            ?run;
        } finally {
            autoTopUpRun.running := false;
        };
    };

    /// `Funds.View`: the auto top-up settings, the 30-day spend and the last run. Null for anyone
    /// else.
    public query ({ caller }) func getAutoTopUp() : async ?AutoTopUpStatus {
        if (caller.isAnonymous() or not AuthService.hasPermission(authService, caller, ShopPermissions.fundsView)) {
            return null;
        };
        ?{
            settings = autoTopUp.settings;
            limits = AutoTopUp.limits;
            spentLast30Days = AutoTopUp.spentInWindow(autoTopUp, Time.now());
            running = autoTopUpRun.running;
            lastRun = autoTopUpRun.lastRun;
        };
    };

    /// `Funds.View`: top-ups that moved ICP, newest first, before id `after`. Empty for anyone else.
    public query ({ caller }) func listAutoTopUps(after : ?Nat, limit : ?Nat) : async Pagination.Page<AutoTopUp.TopUp, Nat> {
        if (caller.isAnonymous() or not AuthService.hasPermission(authService, caller, ShopPermissions.fundsView)) {
            return { items = []; next = null };
        };
        AutoTopUp.page(autoTopUp, after, limit);
    };

    /// Owner only: turns auto top-up on with `settings`, or off with null. When on, the shop
    /// converts ICP from its main account into cycles for itself or its vault whenever either is
    /// under `thresholdCycles`, `topUpE8s` at a time, at most `maxE8sPer30Days` in any 30 days.
    public shared ({ caller }) func setAutoTopUp(settings : ?AutoTopUp.TopUpSettings) : async Result<(), SetAutoTopUpError> {
        if (caller.isAnonymous() or not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop owner can set up auto top-up"));
        };
        switch (settings) {
            case (?wanted) {
                switch (AutoTopUp.validate(wanted)) {
                    case (#err(message)) return #err(#InvalidSettings(message));
                    case (#ok) {};
                };
                logger.info("Auto top-up on: " # debug_show (wanted));
            };
            case null logger.info("Auto top-up off");
        };
        autoTopUp.settings := settings;
        #ok;
    };

    /// Owner only: runs auto top-up now instead of waiting for the hourly check. With auto top-up
    /// off it only asks the CMC about top-ups still waiting on it.
    public shared ({ caller }) func runAutoTopUp() : async Result<AutoTopUp.TopUpRun, RunAutoTopUpError> {
        if (caller.isAnonymous() or not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop owner can run auto top-up"));
        };
        switch (await* runAutoTopUpOnce(#manual caller)) {
            case (?run) #ok(run);
            case null #err(#Busy);
        };
    };
};
