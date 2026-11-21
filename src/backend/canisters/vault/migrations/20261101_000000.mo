import Assets "mo:assets";
import CertifiedAssets "mo:certified-assets";

module {
    type OldActor = {};

    type NewActor = {
        var initialized : Bool;
        var entries : Assets.SerializedEntries;
        cert_store : CertifiedAssets.StableStore;
        var hmacSecretKey : ?Blob;
        var shopCanisterId : ?Principal;
    };

    public func migration(_ : OldActor) : NewActor {
        {
            var initialized = false;
            var entries = ([], []);
            cert_store = CertifiedAssets.init_stable_store();
            var hmacSecretKey = null;
            var shopCanisterId = null;
        };
    };
};
