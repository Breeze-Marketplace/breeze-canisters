import Map "mo:core/Map";

// Adds core's upgrade state (BRE-61): each wasm version's rollout (its canary and whether an admin
// approved it) and the version each shop or vault ran when core last snapshotted it. Empty: no
// rollouts or snapshots yet.
module {
    type Rollout = {
        name : Text;
        version : Text;
        canary : Principal;
        approved : Bool;
    };

    type UpgradesState = {
        rollouts : Map.Map<Text, Rollout>;
        snapshotVersions : Map.Map<Principal, Text>;
    };

    type OldActor = {};

    type NewActor = {
        upgradesState : UpgradesState;
    };

    public func migration(_ : OldActor) : NewActor {
        {
            upgradesState = {
                rollouts = Map.empty<Text, Rollout>();
                snapshotVersions = Map.empty<Principal, Text>();
            };
        };
    };
};
