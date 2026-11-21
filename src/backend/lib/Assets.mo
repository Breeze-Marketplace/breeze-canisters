import Text "mo:base/Text";
import XRC "../interfaces/xrc";

module {
    public func assetPairsEquivalent(
        pairA : (a : XRC.Asset, b : XRC.Asset),
        pairB : (a : XRC.Asset, b : XRC.Asset),
    ) : Bool {
        return assetsAreEquivalent(pairA.0, pairB.0) and assetsAreEquivalent(pairA.1, pairB.1);
    };

    public func hashAssetPair(assetPair : (a : XRC.Asset, b : XRC.Asset)) : Nat32 {
        let symbolHashA = Text.hash(assetPair.0.symbol);
        let symbolHashB = Text.hash(assetPair.1.symbol);
        let classHashA = Text.hash(assetClassToText(assetPair.0.class_));
        let classHashB = Text.hash(assetClassToText(assetPair.1.class_));
        // XOR is order-blind: (a, b) and (b, a) hash the same.
        symbolHashA ^ symbolHashB ^ classHashA ^ classHashB;
    };

    private func assetsAreEquivalent(a : XRC.Asset, b : XRC.Asset) : Bool {
        switch (a.class_, b.class_) {
            case (classA, classB) {
                if (classA != classB) {
                    return false;
                };
            };
        };

        if (a.symbol != b.symbol) {
            return false;
        };

        return true;
    };

    private func assetClassToText(class_ : XRC.AssetClass) : Text {
        switch (class_) {
            case (#Cryptocurrency) { "Cryptocurrency" };
            case (#FiatCurrency) { "FiatCurrency" };
        };
    };
};
