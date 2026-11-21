import Cycles "mo:core/Cycles";
import Error "mo:core/Error";
import List "mo:core/List";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";

/// Cycle balances of core and its sibling canisters for the admin page (BRE-25). Shops and vaults
/// are left out: core can't read their status.
module {
    public type CanisterKind = {
        #core;
        #productIndex;
        #canisterFactory;
        #frontend;
    };

    /// What controls the freezing point: the canister freezes once its balance falls to
    /// `thresholdCycles`, the idle burn for `thresholdSeconds`.
    public type Freezing = {
        thresholdSeconds : Nat;
        idleCyclesBurnedPerDay : Nat;
        thresholdCycles : Nat;
    };

    public type CyclesStatus = {
        cycles : Nat;
        /// Null on core's own row when core isn't its own status viewer (see scripts/setup.sh).
        freezing : ?Freezing;
    };

    public type CanisterCycles = {
        kind : CanisterKind;
        canisterId : Principal;
        /// An error when canister_status failed, typically because core is neither a controller nor
        /// a status viewer of the canister.
        status : Result<CyclesStatus, Text>;
    };

    /// The subset of the management canister's canister_status result this module reads.
    public type RawStatus = {
        cycles : Nat;
        idleCyclesBurnedPerDay : Nat;
        freezingThresholdSeconds : Nat;
    };

    public type Operations = {
        /// canister_status of a canister core controls or is a status viewer of.
        canisterStatus : (Principal) -> async* RawStatus;
        /// Core's own balance, for when core can't read its own status.
        ownBalance : () -> Nat;
    };

    let secondsPerDay = 86_400;

    public func freezingThresholdCycles(idleCyclesBurnedPerDay : Nat, thresholdSeconds : Nat) : Nat {
        idleCyclesBurnedPerDay * thresholdSeconds / secondsPerDay;
    };

    func toStatus(raw : RawStatus) : CyclesStatus {
        {
            cycles = raw.cycles;
            freezing = ?{
                thresholdSeconds = raw.freezingThresholdSeconds;
                idleCyclesBurnedPerDay = raw.idleCyclesBurnedPerDay;
                thresholdCycles = freezingThresholdCycles(raw.idleCyclesBurnedPerDay, raw.freezingThresholdSeconds);
            };
        };
    };

    /// The cycles of each of `canisters`, in order. Reads one canister at a time, with no self-calls:
    /// every outstanding call holds a prepayment of core's cycles, and several at once on mainnet
    /// left too few for the next call ("could not perform remote call").
    public func list(ops : Operations, canisters : [(CanisterKind, Principal)]) : async* [CanisterCycles] {
        let rows = List.empty<CanisterCycles>();
        for ((kind, canisterId) in canisters.vals()) {
            let status = try {
                #ok(toStatus(await* ops.canisterStatus(canisterId)));
            } catch (e) {
                // Without status access to itself, core still knows its own balance.
                if (kind == #core) #ok({
                    cycles = ops.ownBalance();
                    freezing = null;
                }) else #err("canister_status of " # Principal.toText(canisterId) # " failed: " # Error.message(e));
            };
            List.add(rows, { kind; canisterId; status });
        };
        List.toArray(rows);
    };

    type ManagementStatus = actor {
        canister_status : ({ canister_id : Principal }) -> async {
            cycles : Nat;
            idle_cycles_burned_per_day : Nat;
            settings : { freezing_threshold : Nat };
        };
    };

    /// Seconds before a bounded-wait call gives up, so a slow management call can't hold up the
    /// page or block core's upgrades.
    let callTimeoutSeconds : Nat32 = 30;

    /// `Operations` backed by the management canister.
    public func managementOperations() : Operations {
        let ic = actor "aaaaa-aa" : ManagementStatus;
        {
            canisterStatus = func(canisterId : Principal) : async* RawStatus {
                let status = await (with timeout = callTimeoutSeconds) ic.canister_status({
                    canister_id = canisterId;
                });
                {
                    cycles = status.cycles;
                    idleCyclesBurnedPerDay = status.idle_cycles_burned_per_day;
                    freezingThresholdSeconds = status.settings.freezing_threshold;
                };
            };
            ownBalance = func() : Nat { Cycles.balance() };
        };
    };
};
