import Map "mo:core/Map";

// Adds core's shop handover state (BRE-79): handovers of a shop and its vault to a merchant's own
// principal that are waiting for that principal to confirm, and shops already handed over
// (self-managed); and the shop and vault releases published for those merchants. Empty: no
// handovers or releases yet.
module {
    type Pending = {
        controller : Principal;
        vaultId : Principal;
        startedAt : Int;
        vaultReleased : Bool;
    };

    type SelfManaged = {
        controller : Principal;
        vaultId : Principal;
        since : Int;
    };

    type HandoverState = {
        pending : Map.Map<Principal, Pending>;
        selfManaged : Map.Map<Principal, SelfManaged>;
    };

    type Release = {
        name : Text;
        version : Text;
        sha256 : Blob;
        size : Nat;
        notes : Text;
        publishedAt : Int;
        source : Principal;
    };

    type ReleasesState = {
        releases : Map.Map<Text, Release>;
    };

    type OldActor = {};

    type NewActor = {
        handoverState : HandoverState;
        releasesState : ReleasesState;
    };

    public func migration(_ : OldActor) : NewActor {
        {
            handoverState = {
                pending = Map.empty<Principal, Pending>();
                selfManaged = Map.empty<Principal, SelfManaged>();
            };
            releasesState = {
                releases = Map.empty<Text, Release>();
            };
        };
    };
};
