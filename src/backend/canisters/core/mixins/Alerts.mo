import { type Result } "mo:core/Result";

import AdminAPI "../api/admin";
import AlertsAPI "../api/alerts";
import Pagination "../../../lib/Pagination";
import PlatformPermissions "../../../lib/PlatformPermissions";

/// Platform alerts for staff (BRE-210; see `api/alerts`). Every method needs `Alerts.View`: alerts
/// name the users and shop owners they are about. Settings and read state are the caller's own.
mixin (adminApi : AdminAPI.API, alerts : AlertsAPI.State) {
    func canReadAlerts(caller : Principal) : Bool {
        AdminAPI.has(adminApi, caller, PlatformPermissions.alertsView);
    };

    /// The alerts the caller hasn't muted, newest first, a page at a time: pass a page's `next` as
    /// `after` for older ones. A page can be short, or empty with a `next`, where muted alerts were
    /// skipped. Needs `Alerts.View`.
    public query ({ caller }) func listAlerts(after : ?Nat, limit : ?Nat) : async Result<Pagination.Page<AlertsAPI.Alert, Nat>, { #Unauthorized }> {
        if (not canReadAlerts(caller)) return #err(#Unauthorized);
        #ok(AlertsAPI.page(alerts, caller, after, limit));
    };

    /// How many unmuted alerts the caller hasn't marked read (at most 100), and the newest alert's
    /// number to mark read with `markAlertsSeen`. Needs `Alerts.View`.
    public query ({ caller }) func getAlertSummary() : async Result<AlertsAPI.AlertSummary, { #Unauthorized }> {
        if (not canReadAlerts(caller)) return #err(#Unauthorized);
        #ok(AlertsAPI.summary(alerts, caller));
    };

    /// The caller's alert settings. Needs `Alerts.View`.
    public query ({ caller }) func getAlertSettings() : async Result<AlertsAPI.AlertSettings, { #Unauthorized }> {
        if (not canReadAlerts(caller)) return #err(#Unauthorized);
        #ok(AlertsAPI.getSettings(alerts, caller));
    };

    /// Sets which alert types the caller doesn't want to see; every other type shows. Needs
    /// `Alerts.View`.
    public shared ({ caller }) func setMutedAlertTypes(muted : [AlertsAPI.AlertType]) : async Result<(), { #Unauthorized }> {
        if (not canReadAlerts(caller)) return #err(#Unauthorized);
        AlertsAPI.setMuted(alerts, caller, muted);
        #ok;
    };

    /// Marks every alert up to number `upTo` read for the caller. Needs `Alerts.View`.
    public shared ({ caller }) func markAlertsSeen(upTo : Nat) : async Result<(), { #Unauthorized }> {
        if (not canReadAlerts(caller)) return #err(#Unauthorized);
        AlertsAPI.markSeen(alerts, caller, upTo);
        #ok;
    };
};
