import Cycles "mo:core/Cycles";
import Error "mo:core/Error";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

import Management "../interfaces/management";

/// Cycle amounts for the shop and vault canisters that canister_factory creates and pools, and the
/// balance check core runs before reinstalling into a pooled one (BRE-14).
module {
    /// Cycles canister_factory sends with each create_canister call (BRE-6). The creation fee comes
    /// out of these and scales with subnet size: 0.5T on a 13-node subnet, ~1.3T on a 34-node one
    /// (icp-cli's local network). Installing the shop or vault wasm then needs ~0.86T on hand there.
    public let createCanisterCycles = 3_000_000_000_000;

    /// The least a pooled canister may hold before core reinstalls into it: what a new canister has
    /// left after the 34-node creation fee (3T - 1.3T). That covers the ~0.86T install with the rest
    /// as operating margin, so a reused canister starts no worse off than a new one.
    public let reuseCycles = 1_700_000_000_000;

    /// The cycles to deposit so that a canister holding `balance` reaches `reuseCycles`.
    public func topUpAmount(balance : Nat) : Nat {
        if (balance >= reuseCycles) 0 else reuseCycles - balance;
    };

    public type Operations = {
        /// The canister's cycle balance. The caller must control it.
        canisterBalance : (Principal) -> async Nat;
        /// Sends `amount` cycles from the caller to the canister.
        depositCycles : (Principal, Nat) -> async ();
        /// The caller's own cycle balance.
        ownBalance : () -> Nat;
    };

    public type EnsureReuseBalanceError = {
        /// canister_status failed, so the canister can't be checked (and likely can't be reinstalled).
        #StatusUnavailable : Text;
        /// The caller can't spare the cycles for the top-up. The canister itself is fine.
        #InsufficientCycles : Text;
        /// deposit_cycles failed.
        #TopUpFailed : Text;
    };

    /// Checks a pooled canister's balance before a reinstall and tops it up to `reuseCycles` when it
    /// is short. Returns the cycles deposited (0 when none were needed).
    public func ensureReuseBalance(canisterId : Principal, ops : Operations) : async Result<Nat, EnsureReuseBalanceError> {
        let balance = try {
            await ops.canisterBalance(canisterId);
        } catch (e) {
            return #err(#StatusUnavailable("Failed to read the cycle balance of " # Principal.toText(canisterId) # ": " # Error.message(e)));
        };

        let amount = topUpAmount(balance);
        if (amount == 0) {
            return #ok(0);
        };

        let available = ops.ownBalance();
        if (available < amount) {
            return #err(
                #InsufficientCycles(
                    "Canister " # Principal.toText(canisterId) # " has " # debug_show (balance)
                    # " cycles and needs " # debug_show (amount) # " more to be reused, but only "
                    # debug_show (available) # " are available"
                )
            );
        };

        try {
            await ops.depositCycles(canisterId, amount);
        } catch (e) {
            return #err(#TopUpFailed("Failed to top up " # Principal.toText(canisterId) # ": " # Error.message(e)));
        };

        #ok(amount);
    };

    /// `Operations` backed by the management canister and this canister's own balance.
    public func managementOperations() : Operations {
        let ic = Management.getManagementCanister();
        {
            canisterBalance = func(canisterId : Principal) : async Nat {
                let status = await ic.canister_status({
                    canister_id = canisterId;
                });
                switch (status.cycles) {
                    case (?cycles) { cycles };
                    case null { 0 };
                };
            };
            depositCycles = func(canisterId : Principal, amount : Nat) : async () {
                await (with cycles = amount) ic.deposit_cycles({
                    canister_id = canisterId;
                });
            };
            ownBalance = func() : Nat { Cycles.balance() };
        };
    };
};
