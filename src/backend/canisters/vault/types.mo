import AssetsTypes "mo:assets/Types";

module {
    public type StreamingCallbackToken = {
        key : Text;
        content_encoding : Text;
        index : Nat;
        sha256 : ?Blob;
    };

    public type StreamingCallbackHttpResponse = {
        body : Blob;
        token : ?StreamingCallbackToken;
    };

    public type StreamingStrategy = {
        #Callback : {
            callback : shared query StreamingCallbackToken -> async StreamingCallbackHttpResponse;
            token : StreamingCallbackToken;
        };
    };

    public type HttpResponse = {
        status_code : Nat16;
        headers : [AssetsTypes.HeaderField];
        body : Blob;
        streaming_strategy : ?StreamingStrategy;
        upgrade : ?Bool;
    };

    /// Reads and writes the vault's delivery settings, which are actor `var`s a mixin can't assign.
    public type DeliverySettings = {
        shopCanisterId : () -> ?Principal;
        setShopCanisterId : Principal -> ();
        hmacSecretKey : () -> ?Blob;
        setHmacSecretKey : Blob -> ();
    };
};
