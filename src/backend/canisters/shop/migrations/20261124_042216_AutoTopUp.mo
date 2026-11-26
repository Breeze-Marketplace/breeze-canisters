import Map "mo:core/Map";

// Adds `autoTopUp` (BRE-212): automatic cycle top-ups from the main account's ICP. Off for every
// shop until its Owner turns it on.
module {
    type Settings = {
        thresholdCycles : Nat;
        topUpE8s : Nat;
        maxE8sPer30Days : Nat;
    };
    type TopUp = {
        id : Nat;
        at : Int;
        trigger : { #timer; #manual : Principal };
        kind : { #shop; #vault };
        canisterId : Principal;
        balanceBefore : Nat;
        e8s : Nat;
        blockIndex : Nat;
        outcome : {
            #notifying;
            #minted : Nat;
            #refunded : Text;
            #failed : Text;
        };
        notifyAttempts : Nat;
    };

    public func migration(_old : {}) : {
        autoTopUp : {
            var settings : ?Settings;
            var nextId : Nat;
            topUps : Map.Map<Nat, TopUp>;
        };
    } {
        {
            autoTopUp = {
                var settings = null;
                var nextId = 0;
                topUps = Map.empty();
            };
        };
    };
};
