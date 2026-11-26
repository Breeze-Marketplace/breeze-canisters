import Array "mo:core/Array";
import Iter "mo:core/Iter";
import Nat32 "mo:core/Nat32";
import Set "mo:core/Set";

import Music "music";

/// Which variants buyers get a release through (BRE-192). Release delivery finds a paid line's
/// release through its variant's current `deliverable`, so such a variant can't be deleted, dropped
/// from its product or moved off its release: archive it instead.
///
/// Doesn't import `../types` (its `canister:xrc` import keeps it out of `mops test`), so the types
/// below are the parts of `Order` and `ProductVariant` it reads.
module ReleaseSales {
    public type VariantId = Nat32;

    /// Mirrors `types.OrderStatus`: a status added there stops `Order` fitting `SaleRecord`, so the
    /// compiler asks for it here too.
    public type OrderStatus = {
        #created;
        #awaitingPayment;
        #paid;
        #processing;
        #partiallyFulfilled;
        #fulfilled;
        #canceled;
        #refunded;
    };

    public type SaleRecord = {
        status : OrderStatus;
        items : [{ variantId : VariantId }];
    };

    public type ReleaseVariant = {
        id : VariantId;
        deliverable : ?Music.Deliverable;
    };

    /// An order a buyer paid for, even if since fulfilled or refunded: its lines count as sales.
    public func isSale(status : OrderStatus) : Bool {
        switch (status) {
            case (#paid or #processing or #partiallyFulfilled or #fulfilled or #refunded) true;
            case (#created or #awaitingPayment or #canceled) false;
        };
    };

    /// Whether a paid order in `orders` holds variant `variantId`. Scans every order.
    public func hasSold(orders : Iter.Iter<SaleRecord>, variantId : VariantId) : Bool {
        for (order in orders) {
            if (isSale(order.status) and order.items.any(func(item : { variantId : VariantId }) : Bool = item.variantId == variantId)) return true;
        };
        false;
    };

    /// The ones of `variants` that sell a release a paid order in `orders` holds them for.
    /// Only variants whose release is in `soldReleases` can qualify (`MusicApi` marks a release sold
    /// whenever a paid line delivers it, or a sold variant is linked to it), so `orders` is read only
    /// when one of those is among `variants`, and then once.
    public func soldReleaseVariants<V <: ReleaseVariant>(library : Music.Library, orders : Iter.Iter<SaleRecord>, variants : [V]) : [V] {
        let candidates = variants.filter(
            func(variant : V) : Bool = switch (variant.deliverable) {
                case (?#release(releaseId)) Music.isSold(library, releaseId);
                case null false;
            }
        );
        if (candidates.size() == 0) return [];
        let candidateIds = Set.empty<VariantId>();
        for (variant in candidates.values()) candidateIds.add(variant.id);
        let soldIds = Set.empty<VariantId>();
        for (order in orders) {
            if (isSale(order.status)) {
                for (item in order.items.values()) {
                    if (candidateIds.contains(item.variantId)) soldIds.add(item.variantId);
                };
            };
        };
        candidates.filter(func(variant : V) : Bool = soldIds.contains(variant.id));
    };

    /// Why a buyer needs a release variant to stay: a paid order holds it, or an order awaiting
    /// payment does, whose buyer gets the release through it once the payment lands.
    public type Hold = { #sold; #awaitingPayment };

    /// The first of `variants` a buyer needs to keep its release, and why, or null. A variant an
    /// order awaiting payment holds (`isHeldByUnpaidOrder`) counts as soon as it sells a release;
    /// a sold one only as `soldReleaseVariants` says.
    public func heldReleaseVariant<V <: ReleaseVariant>(
        library : Music.Library,
        orders : Iter.Iter<SaleRecord>,
        isHeldByUnpaidOrder : VariantId -> Bool,
        variants : [V],
    ) : ?(V, Hold) {
        for (variant in variants.values()) {
            if (variant.deliverable != null and isHeldByUnpaidOrder(variant.id)) return ?(variant, #awaitingPayment);
        };
        switch (soldReleaseVariants(library, orders, variants).values().next()) {
            case (?sold) ?(sold, #sold);
            case null null;
        };
    };
};
