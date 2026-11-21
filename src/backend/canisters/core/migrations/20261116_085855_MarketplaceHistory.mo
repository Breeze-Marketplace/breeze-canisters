import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Set "mo:core/Set";
import Text "mo:core/Text";

// Adds the marketplace's history (BRE-153), empty: it starts at this upgrade. Gives the "Admin" preset
// (role 1) the new `History.View` permission, so admins keep holding every permission; a renamed or
// edited role 1 is left alone. The types are this version's (`api/history`, `lib/Permissions.mo`),
// copied here because a migration can't import them.
module {
    type WasmName = { #shop; #vault };
    type Outcome = { #ok; #err : Text };

    type EventKind = {
        #shopCreated : { owner : Principal; quoteId : Nat };
        #shopRegistered : { owner : Principal };
        #shopUnregistered;
        #shopSlugChanged : { slug : Text };
        #vaultLinked : { vault : ?Principal };
        #upgraded : {
            canister : Principal;
            name : WasmName;
            version : Nat;
            outcome : Outcome;
        };
        #snapshotRestored : { canister : Principal; outcome : Outcome };
        #canisterStarted : { canister : Principal; outcome : Outcome };
        #canaryEligibilitySet : { eligible : Bool };
        #rolloutApproved : { name : WasmName; version : Nat };
        #initialVersionSet : { name : WasmName; version : Nat };
        #wasmYanked : { name : WasmName; version : Nat };
        #wasmUnyanked : { name : WasmName; version : Nat };
        #releasePublished : { name : WasmName; version : Nat };
        #handoverStarted : { controller : Principal };
        #handoverConfirmed;
        #handoverCancelled;
        #handedBack;
        #roleCreated : { roleId : Nat; name : Text; permissions : [Text] };
        #roleUpdated : { roleId : Nat; name : Text; permissions : [Text] };
        #roleDeleted : { roleId : Nat };
        #roleAssigned : { principal : Principal; roleId : Nat };
        #roleUnassigned : { principal : Principal; roleId : Nat };
        #shopCreationPriceSet : { usdCents : Nat };
        #shopCallFeesEnforcedSet : { enforced : Bool };
        #stuckQuoteReleased : { quoteId : Nat };
    };

    type Event = {
        seq : Nat;
        shop : ?Principal;
        at : Int;
        by : Principal;
        kind : EventKind;
    };

    type History = {
        events : Map.Map<Nat, Event>;
        bySubject : Set.Set<(?Principal, Nat)>;
        var nextSeq : Nat;
    };

    type TeamRole = { name : Text; permissions : [Text] };
    type Team = {
        roles : Map.Map<Nat, TeamRole>;
        members : Map.Map<Principal, [Nat]>;
        counter : { var nextRoleId : Nat };
    };

    let HISTORY_VIEW = "History.View";
    let ADMIN_ROLE_ID = 1;

    public func migration(old : { team : Team }) : {
        team : Team;
        marketplaceHistory : History;
    } {
        switch (old.team.roles.get(ADMIN_ROLE_ID)) {
            case (?role) {
                if (role.name == "Admin" and not role.permissions.contains(HISTORY_VIEW)) {
                    old.team.roles.add(ADMIN_ROLE_ID, { role with permissions = role.permissions.concat([HISTORY_VIEW]) });
                };
            };
            case null {};
        };
        {
            team = old.team;
            marketplaceHistory = {
                events = Map.empty();
                bySubject = Set.empty();
                var nextSeq = 0;
            };
        };
    };
};
