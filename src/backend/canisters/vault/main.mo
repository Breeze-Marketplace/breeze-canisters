import Principal "mo:core/Principal";
import Timer "mo:core/Timer";
import Assets "mo:assets";
import CertifiedAssets "mo:certified-assets";

import Delivery "lib/Delivery";
import Folders "lib/Folders";
import Writers "lib/Writers";
import Types "types";
import AssetApi "mixins/AssetApi";
import HttpApi "mixins/HttpApi";
import DeliverySettingsApi "mixins/DeliverySettingsApi";
import LibraryApi "mixins/LibraryApi";
import CyclesApi "mixins/CyclesApi";

shared ({ caller = creator }) persistent actor class Valut() = self {
    // Stable state gets its initial values from the migration chain in ./migrations.
    var initialized : Bool;
    var entries : Assets.SerializedEntries;
    let cert_store : CertifiedAssets.StableStore;
    var hmacSecretKey : ?Blob;
    var shopCanisterId : ?Principal;
    let writers : Writers.Writers;
    let folders : Folders.Folders;

    // A migration can't see the installing caller, so authorize it here on the first install
    // only: this body runs again on every upgrade.
    if (not initialized) {
        Writers.add(writers, creator);
        initialized := true;
    };

    // `writers` decides who may write; `mo:assets` only ever hears from the vault itself.
    transient let vault = Principal.fromActor(self);
    entries := (entries.0, [vault]);

    transient let assets = Assets.Assets({
        serializedEntries = entries;
    });
    transient let certs = CertifiedAssets.CertifiedAssets(cert_store);

    // The mixins can't assign actor `var`s, so they get these accessors instead.
    func persistEntries() {
        entries := assets.entries();
    };
    transient let deliverySettings : Types.DeliverySettings = {
        shopCanisterId = func() = shopCanisterId;
        setShopCanisterId = func(id) { shopCanisterId := ?id };
        hmacSecretKey = func() = hmacSecretKey;
        setHmacSecretKey = func(key) { hmacSecretKey := ?key };
    };

    transient let gate = Delivery.Gate(deliverySettings.hmacSecretKey);

    include AssetApi(assets, certs, persistEntries, writers, creator, vault);
    include HttpApi(assets, certs, gate);
    include DeliverySettingsApi(creator, deliverySettings);
    include LibraryApi(assets, certs, persistEntries, writers, folders);
    include CyclesApi();

    // Timers don't survive upgrades, so this runs after every install and upgrade. Arming one can't trap.
    ignore Timer.setTimer<system>(#seconds 0, recertifyAllAssets);
};
