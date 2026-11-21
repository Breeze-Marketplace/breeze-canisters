import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Cycles "mo:core/Cycles";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Runtime "mo:core/Runtime";
import CoreSet "mo:core/Set";
import Time "mo:core/Time";
import List "mo:core/List";
import Map "mo:map/Map";

import Ledger "canister:icp_ledger";
import CKUSDC_Ledger "canister:ckusdc_ledger";

import AdminAPI "../api/admin";
import PlatformPermissions "../../../lib/PlatformPermissions";
import BalancesAPI "../api/balances";
import CyclesAPI "../api/cycles";
import ShopCreationAPI "../api/shop_creation";

/// Core's own ledger balances and cycles (admin views). Core holds no funds on users' behalf: users
/// keep ICP and ckUSDC in their own accounts and the frontend calls the ledgers as them (BRE-83).
mixin (
    adminApi : AdminAPI.API,
    coreId : Principal,
    shopCreationState : ShopCreationAPI.State,
    emptyQuoteDeposits : CoreSet.Set<Nat>,
) {
    /// Core's own main-account ICP balance. Needs `Balances.View`.
    public shared ({ caller }) func getWalletBalance() : async Result<Nat, { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.balancesView)) {
            return #err(#Unauthorized);
        };
        #ok(await Ledger.icrc1_balance_of({ owner = coreId; subaccount = null }));
    };

    /// Core's cycle balance. A query, so it costs core nothing; the balance is public on the IC anyway.
    public query func getCyclesBalance() : async Nat {
        Cycles.balance();
    };

    /// Core's ICP (e8s) and ckUSDC (6 decimals) balances, totalled over its subaccounts: the main
    /// account and each shop creation quote's deposit account, except the deposits of settled
    /// quotes (claimed, refunded, or unpaid past their grace period) that an earlier call found
    /// empty (BRE-101). Core keeps no accounts for users (BRE-83). `accounts` lists the main
    /// account and every other account that holds funds. Needs `Balances.View`.
    public shared ({ caller }) func getMarketplaceBalances() : async Result<BalancesAPI.Balances, { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.balancesView)) {
            return #err(#Unauthorized);
        };
        #ok(
            await* BalancesAPI.read(
                {
                    balances = func(subaccounts : [?Blob]) : async* [(Nat, Nat)] {
                        let calls = List.empty<(async Nat, async Nat)>();
                        for (subaccount in subaccounts.vals()) {
                            let account = { owner = coreId; subaccount };
                            calls.add((Ledger.icrc1_balance_of(account), CKUSDC_Ledger.icrc1_balance_of(account)));
                        };
                        let balances = List.empty<(Nat, Nat)>();
                        for ((icp, ckusdc) in calls.values()) {
                            balances.add((await icp, await ckusdc));
                        };
                        balances.toArray();
                    };
                },
                {
                    ids = Map.keys(shopCreationState.quotes);
                    settled = func(id : Nat) : Bool {
                        switch (Map.get(shopCreationState.quotes, Map.nhash, id)) {
                            case (?quote) {
                                ShopCreationAPI.depositSettled(quote, Time.now());
                            };
                            case null { false };
                        };
                    };
                    empty = emptyQuoteDeposits;
                    subaccount = ShopCreationAPI.depositSubaccount;
                },
            )
        );
    };

    /// Cycle balances and freezing thresholds of core, product_index, canister_factory and the
    /// frontend, read with canister_status (scripts/setup.sh makes core a status viewer of each).
    /// Shops and vaults aren't listed. A canister core can't read shows an error row. Needs `Cycles.View`.
    public shared ({ caller }) func getCanisterCycles() : async Result<[CyclesAPI.CanisterCycles], { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.cyclesView)) {
            return #err(#Unauthorized);
        };
        // Literal names: see lib/Siblings. A sibling that isn't deployed is left out.
        let siblings = [
            (#core, ?coreId.toText()),
            (#productIndex, Runtime.envVar<system>("PUBLIC_CANISTER_ID:product_index")),
            (#canisterFactory, Runtime.envVar<system>("PUBLIC_CANISTER_ID:canister_factory")),
            (#frontend, Runtime.envVar<system>("PUBLIC_CANISTER_ID:frontend")),
        ].filterMap<(CyclesAPI.CanisterKind, ?Text), (CyclesAPI.CanisterKind, Principal)>(
            func((kind, id)) = Option.map<Text, (CyclesAPI.CanisterKind, Principal)>(id, func(id) = (kind, Principal.fromText(id)))
        );
        #ok(await* CyclesAPI.list(CyclesAPI.managementOperations(), siblings));
    };
};
