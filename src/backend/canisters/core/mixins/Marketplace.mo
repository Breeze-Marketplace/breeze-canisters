import Principal "mo:core/Principal";

mixin (coreId : Principal, frontendCanisterId : ?Principal) {
    /// Who this marketplace is, for a shop that recognizes it (`recognizeMarketplace` on the shop):
    /// core's ID, the frontend canister's ID (null when it isn't deployed) and the marketplace's
    /// name. Public: none of it is private.
    public query func getMarketplaceInfo() : async {
        backendCanisterId : Principal;
        frontendCanisterId : ?Principal;
        name : Text;
    } {
        {
            backendCanisterId = coreId;
            frontendCanisterId;
            name = "Breeze Marketplace";
        };
    };
};
