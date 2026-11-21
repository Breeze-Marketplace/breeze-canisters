import Types "../types";

/// Links the vault to its shop and receives the shop's HMAC secret for delivery tickets.
mixin (creator : Principal, settings : Types.DeliverySettings) {
    /// Sets the shop allowed to send the HMAC secret. Only the vault's creator (core); others are ignored.
    public shared ({ caller }) func setShopCanisterId(id : Principal) : async () {
        if (caller != creator) {
            return;
        };
        settings.setShopCanisterId(id);
    };

    /// Stores the HMAC secret that signs delivery tickets. Only the linked shop; others are ignored.
    public shared ({ caller }) func setHmacSecretKey(key : Blob) : async () {
        if (settings.shopCanisterId() != ?caller) {
            return;
        };
        settings.setHmacSecretKey(key);
    };
};
