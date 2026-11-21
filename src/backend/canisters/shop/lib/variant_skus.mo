import { type Result } "mo:core/Result";
import Array "mo:core/Array";
import Nat32 "mo:core/Nat32";
import Set "mo:core/Set";
import Text "mo:core/Text";
import VarArray "mo:core/VarArray";

/// Which stored variant each SKU in a `createProduct`/`updateProduct` input refers to (BRE-127).
module VariantSkus {
    // Same as `types.mo`'s, which tests can't import (it imports `canister:xrc`).
    type ProductId = Nat32;
    type VariantId = Nat32;
    type SKU = Text;

    /// The stored variant an SKU is indexed to.
    public type StoredVariant = { id : VariantId; productId : ProductId };

    /// For each input SKU, in order, the variant ID to keep, or `null` for a new variant; and the
    /// product's current variants that the input leaves out.
    public type UpdatePlan = {
        variantIds : [?VariantId];
        removed : [VariantId];
    };

    /// Rejects an SKU listed twice in one input.
    public func checkNoDuplicates(skus : [SKU]) : Result<(), Text> {
        let seen = Set.empty<SKU>();
        for (sku in skus.values()) {
            if (Set.contains(seen, Text.compare, sku)) {
                return #err("SKU " # sku # " is listed more than once");
            };
            Set.add(seen, Text.compare, sku);
        };
        #ok;
    };

    /// Plans an update of product `productId`, whose variants are `currentVariantIds`, to the variants
    /// with `skus`. `lookup` returns the stored variant an SKU is indexed to, if any. An SKU of another
    /// product's variant is rejected, so an update can't take that variant over.
    public func planUpdate(
        productId : ProductId,
        currentVariantIds : [VariantId],
        skus : [SKU],
        lookup : SKU -> ?StoredVariant,
    ) : Result<UpdatePlan, Text> {
        switch (checkNoDuplicates(skus)) {
            case (#err(e)) return #err(e);
            case (#ok) {};
        };
        let kept = Set.empty<VariantId>();
        let variantIds = VarArray.repeat<?VariantId>(null, skus.size());
        for (i in skus.keys()) {
            switch (lookup(skus[i])) {
                case null {};
                case (?stored) {
                    if (stored.productId != productId) {
                        return #err("SKU " # skus[i] # " belongs to product " # Nat32.toText(stored.productId));
                    };
                    variantIds[i] := ?stored.id;
                    Set.add(kept, Nat32.compare, stored.id);
                };
            };
        };
        #ok({
            variantIds = Array.fromVarArray(variantIds);
            removed = Array.filter<VariantId>(
                currentVariantIds,
                func(id) = not Set.contains(kept, Nat32.compare, id),
            );
        });
    };
};
