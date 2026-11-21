import Array "mo:base/Array";
import { type Result } "mo:core/Result";
import List "mo:core/List";
import Principal "mo:core/Principal";
import Map "mo:map/Map";
import Time "mo:core/Time";

import Ledger "canister:icp_ledger";

import Wallet "../../../lib/Wallet";
import Logger "../../../lib/Logger";
import AuthService "../lib/auth";
import ShopPermissions "../lib/permissions";
import OrderFunds "../lib/order_funds";
import Withdrawals "../lib/withdrawals";
import WithdrawalAddresses "../lib/withdrawal_addresses";
import {
    type Order;
    type OrderId;
    type TranferFundsToMainError;
} "../types";

/// The shop's wallet: its main account plus tracked subaccounts (one per order). `wallet` is set on
/// first install and never reassigned, so the mixin can hold it. `orders` is read to tell whose funds
/// an order's payment subaccount holds (BRE-31). `withdrawalAddresses` is the Owner's address book (BRE-150).
mixin (wallet : Wallet.Wallet, orders : Map.Map<OrderId, Order>, withdrawalAddresses : WithdrawalAddresses.Book, authService : AuthService.AuthService, shopId : Principal, logger : Logger.BoundLogger) {
    /// Owner or Admin: main canister ledger account plus tracked subaccounts with live `icrc1_balance_of` balances.
    public query ({ caller }) func listWalletAccounts() : async [Wallet.Account.Account] {
        if (not AuthService.hasPermission(authService, caller, ShopPermissions.fundsView)) {
            return [];
        };
        return Wallet.listAccounts(wallet);
    };

    /// Removes an account from the tracked set. Allowed only when the account balance is 0 and caller is the shop owner.
    public shared ({ caller }) func removeWalletAccount(accountId : Text) : async Result<(), { #NotFoundError : Text; #Unauthorized : Text; #NonZeroBalanceError : { msg : Text; balance : Nat } }> {
        if (not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop owner can remove wallet accounts"));
        };
        let result = await Wallet.deleteAccount(wallet, accountId);
        switch (result) {
            case (#ok) { logger.info("Removed wallet account " # accountId) };
            case (#err(_)) {};
        };
        result;
    };

    /// Transfers all funds from the account identified by accountId to the store's main account. Callable only by the shop owner.
    /// An order's payment subaccount can be swept only once the order is paid: before that the funds are the
    /// buyer's payment in progress, and after a cancellation they are the buyer's to reclaim (`#InvalidStatus`).
    public shared ({ caller }) func transferFundsToMain(accountId : Text) : async Result<(), [TranferFundsToMainError]> {
        if (not AuthService.isOwner(authService, caller)) {
            return #err([#Unauthorized("Only the shop owner can transfer funds to main account")]);
        };

        let account = Wallet.getAccount(wallet, accountId);
        let sourceAccount : Ledger.Account = switch (account) {
            case (null) {
                return #err([#NotFoundError("Account mot found")]);
            };
            case (?acc) acc;
        };
        // Paid orders never go back to unpaid or cancelled, so checking once before the transfers is enough.
        let order = switch (OrderFunds.orderIdOfSubaccount(sourceAccount.subaccount)) {
            case null null;
            case (?orderId) Map.get(orders, Map.n32hash, orderId);
        };
        switch (OrderFunds.sweepDecision(order)) {
            case (#ok) {};
            case (#err(message)) { return #err([#InvalidStatus(message)]) };
        };
        let mainAccount : Ledger.Account = {
            owner = shopId;
            subaccount = null;
        };
        let supportedTokens = Wallet.supportedTokens;
        let errors = List.empty<{ #TransferError : { token : Wallet.Token; msg : Text }; #InsufficientFunds : { token : Wallet.Token; balance : Nat; fee : Nat } }>();

        for (token in Array.vals(supportedTokens)) {
            let ledger = Wallet.ledgerForToken(token);
            switch (ledger) {
                case null {
                    List.add(errors, #TransferError({ token = token; msg = "Unsupported token type" }));
                };
                case (?l) {
                    let balance = await l.icrc1_balance_of(sourceAccount);
                    if (balance > 0) {
                        let fee = await l.icrc1_fee();
                        if (balance > fee) {
                            let amount : Nat = balance - fee;
                            let res = await Wallet.transfer(
                                wallet,
                                {
                                    token = token;
                                    fromAccountId = accountId;
                                    to = mainAccount;
                                    amount = amount;
                                },
                            );
                            switch (res) {
                                case (#ok(_)) {
                                    logger.info("Moved " # debug_show (amount) # " " # debug_show (token) # " from wallet account " # accountId # " to the main account");
                                };
                                case (#err(#NotFoundError(msg))) {
                                    // Unreachable: the account was found above.
                                    return #err([#NotFoundError(msg)]);
                                };
                                case (#err(#TransferError(msg))) {
                                    List.add(errors, #TransferError({ token = token; msg = msg }));
                                };
                                case (#err(#UnsupportedToken(_))) {
                                    List.add(errors, #TransferError({ token = token; msg = "Unsupported token type" }));
                                };
                                case (#err(#InsufficientFunds({ balance; fee }))) {
                                    List.add(errors, #InsufficientFunds({ token = token; balance = balance; fee = fee }));
                                };
                            };
                        } else {
                            // The balance doesn't cover the fee, so there is nothing to move.
                        };
                    };
                };
            };
        };

        if (List.size(errors) > 0) {
            logger.warning("Moving funds from wallet account " # accountId # " to the main account failed for " # debug_show (List.size(errors)) # " token(s)");
            return #err(List.toArray(errors));
        };

        #ok;
    };

    /// Set while a `withdrawFunds` call is between its balance read and the ledger's answer, so two
    /// withdrawals can't both spend the same balance. Transient: an upgrade waits for calls to finish.
    private transient var withdrawing = false;

    /// Owner or Admin: the main account's balance and the ledger fee for each token, as `withdrawFunds`
    /// sees them. An update call, since it reads both ledgers; refused callers get no ledger calls.
    public shared ({ caller }) func getWithdrawableBalances() : async Result<[{ token : Wallet.Token; balance : Nat; fee : Nat }], { #Unauthorized : Text }> {
        if (caller.isAnonymous() or not AuthService.hasPermission(authService, caller, ShopPermissions.fundsView)) {
            return #err(#Unauthorized("Only the shop owner or an admin can view withdrawable balances"));
        };
        let mainAccount : Ledger.Account = { owner = shopId; subaccount = null };
        let balances = List.empty<{ token : Wallet.Token; balance : Nat; fee : Nat }>();
        for (token in Wallet.supportedTokens.values()) {
            switch (Wallet.ledgerForToken(token)) {
                case null {};
                case (?ledger) {
                    let balance = await ledger.icrc1_balance_of(mainAccount);
                    let fee = await ledger.icrc1_fee();
                    List.add(balances, { token; balance; fee });
                };
            };
        };
        #ok(List.toArray(balances));
    };

    /// Owner only: sends `token` ("ICP" or "ckUSDC") from the shop's main account to `to`, an ICRC-1
    /// account outside this shop. `amount` is in the token's smallest unit; null sends everything the
    /// main account holds minus the ledger fee, read from the ledger at call time. The fee is paid on top.
    /// `createdAtTime` (nanoseconds since the epoch, default: now) is the transfer's `created_at_time`:
    /// a client that retries after a timeout passes the same value again, and if the first attempt went
    /// through, the ledger reports a duplicate and this returns that transfer's block index instead of
    /// sending twice (BRE-76, BRE-70). Returns the block index and the amount sent.
    public shared ({ caller }) func withdrawFunds(
        token : Wallet.Token,
        to : Withdrawals.Destination,
        amount : ?Nat,
        createdAtTime : ?Nat64,
    ) : async Result<{ blockIndex : Nat; amount : Nat }, Withdrawals.WithdrawError> {
        if (caller.isAnonymous() or not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop owner can withdraw funds"));
        };
        let ?ledger = Wallet.ledgerForToken(token) else return #err(#UnsupportedToken(token));
        switch (Withdrawals.checkDestination(to, shopId)) {
            case (#ok) {};
            case (#err(message)) { return #err(#InvalidDestination(message)) };
        };
        if (withdrawing) {
            return #err(#Busy);
        };
        withdrawing := true;
        try {
            let mainAccount : Ledger.Account = {
                owner = shopId;
                subaccount = null;
            };
            let balance = await ledger.icrc1_balance_of(mainAccount);
            let fee = await ledger.icrc1_fee();
            let sending = switch (Withdrawals.amountToSend(amount, balance, fee)) {
                case (#ok(n)) n;
                case (#err(e)) { return #err(e) };
            };
            let result = await ledger.icrc1_transfer({
                to;
                amount = sending;
                fee = ?fee;
                memo = null;
                from_subaccount = null;
                created_at_time = ?Withdrawals.createdAt(createdAtTime, Time.now());
            });
            switch (result) {
                case (#Ok(blockIndex)) {
                    logger.info("Withdrew " # debug_show (sending) # " " # token # " to " # debug_show (to) # " (block " # debug_show (blockIndex) # ")");
                    #ok({ blockIndex; amount = sending });
                };
                case (#Err(#Duplicate({ duplicate_of }))) {
                    // A retry of a withdrawal that already went through: report the original transfer.
                    #ok({ blockIndex = duplicate_of; amount = sending });
                };
                case (#Err(#InsufficientFunds({ balance }))) {
                    #err(#InsufficientFunds({ balance; fee }));
                };
                case (#Err(e)) {
                    logger.warning("Withdrawing " # debug_show (sending) # " " # token # " failed: " # debug_show (e));
                    #err(#TransferError(debug_show (e)));
                };
            };
        } finally {
            withdrawing := false;
        };
    };

    /// `Funds.View`: the saved withdrawal addresses, oldest first. Empty for anyone else, since
    /// they're the merchant's own accounts.
    public query ({ caller }) func listWithdrawalAddresses() : async [WithdrawalAddresses.WithdrawalAddress] {
        if (caller.isAnonymous() or not AuthService.hasPermission(authService, caller, ShopPermissions.fundsView)) {
            return [];
        };
        WithdrawalAddresses.list(withdrawalAddresses);
    };

    /// Owner only: saves `to` with `name`, or renames it if it's already saved. At most
    /// `WithdrawalAddresses.MAX_ADDRESSES`, each name at most `MAX_NAME_CHARS` characters.
    /// `withdrawFunds` doesn't require a saved address.
    public shared ({ caller }) func saveWithdrawalAddress(to : Withdrawals.Destination, name : Text) : async Result<WithdrawalAddresses.WithdrawalAddress, WithdrawalAddresses.SaveAddressError> {
        if (caller.isAnonymous() or not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop owner can save withdrawal addresses"));
        };
        let result = WithdrawalAddresses.save(withdrawalAddresses, to, name, shopId, Time.now());
        switch (result) {
            case (#ok(entry)) {
                logger.info("Saved withdrawal address " # debug_show (to) # " as \"" # entry.name # "\"");
            };
            case (#err(_)) {};
        };
        result;
    };

    /// Owner only: removes `to` from the saved withdrawal addresses.
    public shared ({ caller }) func removeWithdrawalAddress(to : Withdrawals.Destination) : async Result<(), WithdrawalAddresses.RemoveError> {
        if (caller.isAnonymous() or not AuthService.isOwner(authService, caller)) {
            return #err(#Unauthorized("Only the shop owner can remove withdrawal addresses"));
        };
        if (not WithdrawalAddresses.remove(withdrawalAddresses, to)) {
            return #err(#NotFound);
        };
        logger.info("Removed withdrawal address " # debug_show (to));
        #ok;
    };
};
