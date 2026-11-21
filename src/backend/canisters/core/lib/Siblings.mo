import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Runtime "mo:core/Runtime";

import Management "../../../interfaces/management";
import ShopInterface "../../../interfaces/shop";
import Pagination "../../../lib/Pagination";
import WasmVersion "../../../lib/WasmVersion";
import ShopAPI "../api/shop";

/// The other canisters of this deployment, found through the `PUBLIC_CANISTER_ID:<name>` variables
/// that `icp deploy` sets. Read at call time: a sibling may not exist yet when core is first installed.
/// Pass variable names as literals: moc 1.6.0 rejected a concatenated name as invalid UTF-8.
module {
    public type WasmName = WasmVersion.WasmName;
    public type Version = WasmVersion.Version;

    /// A wasm stored in canister_factory, without its bytes.
    public type WasmInfo = {
        name : WasmName;
        version : Version;
        interface : Nat;
        breaking : Bool;
        sha256 : Blob;
        size : Nat;
        uploadedAt : Int;
        uploadedBy : Principal;
        note : Text;
        yanked : Bool;
    };

    public type CanisterFactory = actor {
        getWasm : query (WasmName, Version) -> async Result<{ wasm : Blob; sha256 : Blob }, { #NotFound; #Yanked }>;
        getWasmInfo : query (WasmName, Version) -> async ?WasmInfo;
        listWasms : query (WasmName) -> async [WasmInfo];
        yankWasm : (WasmName, Version) -> async Result<(), { #Unauthorized : Text; #NotFound }>;
        unyankWasm : (WasmName, Version) -> async Result<(), { #Unauthorized : Text; #NotFound }>;
        createCanister : (?Management.CanisterSettings) -> async Result<{ canisterId : Principal; isNewCanister : Bool }, { #Unauthorized : Text }>;
        addCanisterToPool : (Principal) -> async Result<(), { #Unauthorized : Text }>;
    };

    public type ProductIndex = actor {
        syncShopProductBatch : (Principal, [ShopAPI.MarketplaceProductListing]) -> async Result<(), Text>;
        pruneShopProducts : (Principal, [ShopInterface.ProductId]) -> async Result<Nat, Text>;
        syncUpdatedProduct : (Principal, ShopAPI.MarketplaceProductListing) -> async Result<(), Text>;
        syncDeletedProducts : (Principal, [ShopInterface.ProductId]) -> async Result<(), Text>;
        listHiddenShops : (?Principal, ?Nat) -> async Result<Pagination.Page<Principal, Principal>, Text>;
    };

    func required<system>(variable : Text) : Text {
        Runtime.envVar<system>(variable) ?? Runtime.trap(variable # " is not set; deploy this canister with icp deploy");
    };

    public func canisterFactory<system>() : CanisterFactory = actor (required<system>("PUBLIC_CANISTER_ID:canister_factory"));

    /// True if `caller` is trust_safety, which alone may hide or show shops.
    public func isTrustSafety<system>(caller : Principal) : Bool {
        switch (Runtime.envVar<system>("PUBLIC_CANISTER_ID:trust_safety")) {
            case (?id) { Principal.fromText(id) == caller };
            case null { false };
        };
    };

    public func productIndex<system>() : ProductIndex = actor (required<system>("PUBLIC_CANISTER_ID:product_index"));
};
