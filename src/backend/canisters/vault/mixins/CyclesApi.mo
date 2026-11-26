import Cycles "mo:core/Cycles";

/// The vault's cycle balance, so its shop can top it up when auto top-up is on (BRE-212).
mixin () {
    /// This canister's cycle balance. No caller check: the balance is not private (core's
    /// `getShopCycles` shows it), and the shop calls this to decide whether to top the vault up.
    public query func getCyclesBalance() : async Nat {
        Cycles.balance();
    };
};
