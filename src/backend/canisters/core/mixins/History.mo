import { type Result } "mo:core/Result";

import AdminAPI "../api/admin";
import HistoryAPI "../api/history";
import Pagination "../../../lib/Pagination";
import PlatformPermissions "../../../lib/PlatformPermissions";

/// The marketplace's history (BRE-153; see `api/history`). Needs `History.View`: events name who acted.
mixin (adminApi : AdminAPI.API, history : HistoryAPI.State) {
    /// Every event after sequence number `after`, oldest first, a page at a time. Needs `History.View`.
    public query ({ caller }) func listHistory(after : ?Nat, limit : ?Nat) : async Result<Pagination.Page<HistoryAPI.Event, Nat>, { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.historyView)) {
            return #err(#Unauthorized);
        };
        #ok(HistoryAPI.page(history, after, limit));
    };

    /// Events about shop `shopId` (and its vault) after sequence number `after`, oldest first, a page
    /// at a time. Needs `History.View`.
    public query ({ caller }) func getShopHistory(shopId : Principal, after : ?Nat, limit : ?Nat) : async Result<Pagination.Page<HistoryAPI.Event, Nat>, { #Unauthorized }> {
        if (not AdminAPI.has(adminApi, caller, PlatformPermissions.historyView)) {
            return #err(#Unauthorized);
        };
        #ok(HistoryAPI.pageShop(history, shopId, after, limit));
    };
};
