import Blob "mo:core/Blob";
import Principal "mo:core/Principal";

module {
    public type Vault = actor {
        authorize : (Principal) -> async ();
        setShopCanisterId : (Principal) -> async ();
        setHmacSecretKey : (Blob) -> async ();
        getCyclesBalance : shared query () -> async Nat;
    };
};
