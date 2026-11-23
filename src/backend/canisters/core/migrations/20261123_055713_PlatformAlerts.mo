import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

// Adds platform alerts (BRE-210), empty: they start at this upgrade. Gives the "Admin" preset (role 1)
// the new `Alerts.View` permission, so admins keep holding every permission; a renamed or edited role
// 1 is left alone. The types are this version's (`api/alerts`, `lib/Permissions.mo`), copied here
// because a migration can't import them.
module {
    type AlertKind = {
        #userRegistered : { user : Principal };
        #shopCreated : { shop : Principal; owner : Principal };
        #shopRegistered : { shop : Principal; owner : Principal };
        #shopCreationFailed : { quoteId : Nat; owner : Principal; error : Text };
    };
    type AlertType = {
        #userRegistered;
        #shopCreated;
        #shopRegistered;
        #shopCreationFailed;
    };
    type Alert = { seq : Nat; at : Int; kind : AlertKind };
    type Settings = { muted : [AlertType]; lastSeen : ?Nat };
    type Alerts = {
        alerts : Map.Map<Nat, Alert>;
        var nextSeq : Nat;
        settings : Map.Map<Principal, Settings>;
    };

    type TeamRole = { name : Text; permissions : [Text] };
    type Team = {
        roles : Map.Map<Nat, TeamRole>;
        members : Map.Map<Principal, [Nat]>;
        counter : { var nextRoleId : Nat };
    };

    let ALERTS_VIEW = "Alerts.View";
    let ADMIN_ROLE_ID = 1;

    public func migration(old : { team : Team }) : {
        team : Team;
        platformAlerts : Alerts;
    } {
        switch (old.team.roles.get(ADMIN_ROLE_ID)) {
            case (?role) {
                if (role.name == "Admin" and not role.permissions.contains(ALERTS_VIEW)) {
                    old.team.roles.add(ADMIN_ROLE_ID, { role with permissions = role.permissions.concat([ALERTS_VIEW]) });
                };
            };
            case null {};
        };
        {
            team = old.team;
            platformAlerts = {
                alerts = Map.empty();
                var nextSeq = 0;
                settings = Map.empty();
            };
        };
    };
};
