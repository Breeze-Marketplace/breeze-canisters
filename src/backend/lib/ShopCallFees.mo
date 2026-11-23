/// Cycles a shop attaches to each event it sends core (BRE-116): the shop pays for the work its
/// calls cause. Once enforced, core takes them from
/// every caller, hosted shops included.
module {
    /// Attached to `syncShopDetails`, `syncUpdatedProduct`, `syncDeletedProduct` and `trackOrder`.
    /// About 0.0001 TC, several times the execution of one event with its product_index call; raise
    /// it only with a new major shop version, since older shops keep sending this much.
    public let EVENT_CYCLES : Nat = 100_000_000;
};
