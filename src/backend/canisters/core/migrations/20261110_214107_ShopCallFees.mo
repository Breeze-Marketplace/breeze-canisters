// Adds the switch for charging shops core doesn't host for their events (BRE-116). Off at first, so
// the upgrade changes nothing until a controller turns it on.
module {
    type OldActor = {};

    type NewActor = {
        shopCallFeesState : { var enforced : Bool };
    };

    public func migration(_ : OldActor) : NewActor {
        { shopCallFeesState = { var enforced = false } };
    };
};
