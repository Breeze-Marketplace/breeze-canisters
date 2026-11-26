import Principal "mo:base/Principal";
import Map "mo:map/Map";
import Timer "mo:core/Timer";

import XRC "canister:xrc";

import DeliveryToken "../../lib/DeliveryToken";
import ExchangeRates "../../lib/ExchangeRates";

import Wallet "../../lib/Wallet";

import OrderService "lib/orders";
import PubSubService "lib/pubsub";
import Music "lib/music";
import AuthService "lib/auth";
import ProductService "lib/products";
import OrderExpiry "lib/order_expiry";
import OrderEvents "lib/order_events";
import WithdrawalAddresses "lib/withdrawal_addresses";
import ShopPermissions "lib/permissions";
import Marketplaces "lib/marketplaces";
import Permissions "../../lib/Permissions";
import Set "mo:core/Set";

import {
    type Order;
    type ProductVariant;
    type ProductAttributeConfig;
    type ProductId;
    type VariantId;
    type OrderId;
    type SKU;
    type Product;
    type ShopProfile;
    type MediaSettings;
    type InventoryEntry;
    type StripeSettings;
    type StorefrontSettings;
    type PresentationSettings;
    type MusicLibrary;
    type Deliverable;
} "./types";

import Logger "../../lib/Logger";
import ExchangeRatesMixin "../../mixins/ExchangeRates";
import LogsApi "../../mixins/Logs";

import PubSubApi "mixins/PubSubApi";
import OwnershipApi "mixins/OwnershipApi";
import TeamApi "../../mixins/Team";
import CatalogApi "mixins/CatalogApi";
import WalletApi "mixins/WalletApi";
import DashboardApi "mixins/DashboardApi";
import MediaApi "mixins/MediaApi";
import OrdersApi "mixins/OrdersApi";
import ShopDetailsApi "mixins/ShopDetailsApi";
import StripeApi "mixins/StripeApi";
import StorefrontApi "mixins/StorefrontApi";
import MusicApi "mixins/MusicApi";
import PresentationApi "mixins/PresentationApi";

shared ({ caller = initializer }) persistent actor class Shop(
    initArgs : {
        name : Text;
        description : Text;
    }
) = self {
    // Stable state gets its initial values from the migration chain in ./migrations.
    var initialized : Bool;

    /// Name, description, images and location shown on storefronts and marketplaces (see `types.mo`).
    let profile : ShopProfile;

    /// The media (vault) canister and the HMAC secret it shares for delivery tickets (see `types.mo`).
    let media : MediaSettings;

    /// The Owner's Stripe restricted key for card payments, if any (BRE-123).
    let stripe : StripeSettings;

    /// The storefront's theme (BRE-171) and its draft and published home page layouts (BRE-172).
    let storefront : StorefrontSettings;

    /// Storefront or artist page, the artist preset and the artist profile (BRE-197).
    let presentation : PresentationSettings;

    /// The shop's wallet, used for receiving payments and sending refunds
    var wallet : Wallet.Wallet;

    /// The Owner's saved withdrawal addresses, each with a label (BRE-150).
    let withdrawalAddresses : WithdrawalAddresses.Book;

    var productIdCounter : ProductId;
    let products : Map.Map<ProductId, Product>;
    let productAttributeConfigs : Map.Map<ProductId, ProductAttributeConfig>;

    var variantIdCounter : VariantId;
    let productVariants : Map.Map<VariantId, ProductVariant>;
    let productVariantsBySKU : Map.Map<SKU, VariantId>;

    let inventory : Map.Map<VariantId, InventoryEntry>;

    /// The music library: tracks, releases and which releases have sold (BRE-182).
    let music : MusicLibrary;

    let orders : Map.Map<OrderId, Order>;
    var orderIdCounter : OrderId;

    /// IDs of the orders still awaiting payment, kept in step with `orders` by `OrdersApi` (BRE-100).
    /// The payment watcher and the timer re-arming below read only these orders.
    let awaitingPaymentOrderIds : OrderExpiry.AwaitingPaymentIds;

    /// Every order's history, appended to by `OrdersApi` on each change (BRE-133).
    let orderEvents : OrderEvents.Log;

    // The canister's log. Stable, so entries survive upgrades (still capped at `Logger.MAX_LOGS`).
    // The migration can't see this canister's principal, so set it and the settings here on every
    // install and upgrade, before anything binds or reads `logState`. The entries are kept.
    var logState : Logger.Logger;
    logState := {
        logState with
        canisterId = Principal.fromActor(self);
        settings = { printToConsole = true };
    };
    transient let logger = Logger.bind(logState);

    // A migration can't see the init args or the canister's own principal, so set these here on
    // the first install only: this body runs again on every upgrade.
    if (not initialized) {
        profile.name := initArgs.name;
        profile.description := initArgs.description;
        wallet := Wallet.new(Principal.fromActor(self));
        initialized := true;
        logger.info("Installed shop \"" # initArgs.name # "\" (installed by " # Principal.toText(initializer) # ")");
    } else {
        logger.info("Upgraded shop \"" # profile.name # "\": " # debug_show (Map.size(products)) # " products, " # debug_show (Map.size(orders)) # " orders");
    };

    private func getNextProductId() : ProductId {
        productIdCounter += 1;
        productIdCounter;
    };
    private func getNextVariantId() : VariantId {
        variantIdCounter += 1;
        variantIdCounter;
    };
    private func getNextOrderId() : OrderId {
        orderIdCounter += 1;
        orderIdCounter;
    };

    /// Merchant-defined private media object keys keyed by `"productId:variantId"`.
    let digitalAssetKeys : Map.Map<Text, Text>;

    /// Access control (BRE-151): the Owner, Marketplace grants (core), and team roles made of
    /// permissions. Methods check a permission (`lib/permissions`), or the Owner for money and secrets.
    let ownership : AuthService.Ownership;
    let marketplacePrincipals : Set.Set<Principal>;
    let team : Permissions.Store;

    /// Marketplaces the Owner recognized, with their frontend canister and name (`lib/marketplaces`).
    let recognizedMarketplaces : Marketplaces.Store;
    transient let authService = AuthService.AuthService({
        ownership;
        marketplacePrincipals;
        team;
    });

    // Runs on every install and upgrade, but sets the Owner only while there is none (the first install).
    AuthService.initOwner(authService, initializer);

    transient let productService = ProductService.ProductService({
        products = products;
        productVariants = productVariants;
        productVariantsBySKU = productVariantsBySKU;
        productAttributeConfigs = productAttributeConfigs;
        inventory = inventory;
        getNextProductId = getNextProductId;
        getNextVariantId = getNextVariantId;
    });

    transient let orderService = OrderService.OrderService({
        productVariants = productVariants;
    });

    let productUpdatedSubscribers : Map.Map<Principal, PubSubService.ProductUpdatedEventListener>;
    let productDeletedSubscribers : Map.Map<Principal, PubSubService.ProductDeletedEventListener>;
    let shopDetailsUpdatedSubscribers : Map.Map<Principal, PubSubService.ShopDetailsUpdatedEventListener>;
    let orderUpdatedSubscribers : Map.Map<Principal, PubSubService.OrderUpdatedEventListener>;
    transient let pubSubService = PubSubService.PubSubService(
        productUpdatedSubscribers,
        productDeletedSubscribers,
        shopDetailsUpdatedSubscribers,
        orderUpdatedSubscribers,
        // Controllers (core, for the shops it creates), Marketplace and `Events.Manage`; see PubSubApi.
        func(p : Principal) : Bool {
            Principal.isController(p) or AuthService.isMarketplace(authService, p) or AuthService.hasPermission(authService, p, ShopPermissions.eventsManage);
        },
        logger,
        func(d : ?Deliverable) : ?Music.MarketplaceRelease = Music.marketplaceRelease(music, d),
    );

    let exchangeRateCache : ExchangeRates.Cache;
    transient let exchangeRates = ExchangeRates.newState(exchangeRateCache);
    include ExchangeRatesMixin(exchangeRates, XRC);
    include PubSubApi(pubSubService, authService);
    include OwnershipApi(authService, recognizedMarketplaces, logger);
    include TeamApi(authService.team, logger, func(_ : Principal, _ : Permissions.TeamChange) {});
    include CatalogApi(products, productVariants, inventory, music, productService, authService, pubSubService, unpaidOrderHolds, heldReleaseVariant, logger);
    include WalletApi(wallet, orders, withdrawalAddresses, authService, Principal.fromActor(self), logger);
    include DashboardApi(products, productVariants, inventory, orders, authService);
    include MediaApi(media, digitalAssetKeys, products, productVariants, orders, music, authService, Principal.fromActor(self), logger, recordDigitalDelivery);
    include OrdersApi(orders, awaitingPaymentOrderIds, orderEvents, wallet, productVariants, products, inventory, authService, orderService, pubSubService, exchangeRates, stripe, getNextOrderId, recordReleaseSales, Principal.fromActor(self), logger);
    include StripeApi(stripe, authService, stripeTransform, logger);
    include ShopDetailsApi(profile, presentation, authService, pubSubService, logger);
    include StorefrontApi(storefront, media, authService, logger);
    include PresentationApi(presentation, profile, media, authService, pubSubService, logger);
    include MusicApi(music, products, productVariants, orders, productService, authService, unpaidOrderHolds, pubSubService, logger);
    include LogsApi(
        logState,
        func(caller : Principal) : Bool {
            Principal.isController(caller) or AuthService.hasPermission(authService, caller, ShopPermissions.logsView);
        },
    );

    // A new shop, or one still on the placeholder key the first migration installed, has no usable
    // HMAC secret, so draw one from `raw_rand` once the install
    // or upgrade finishes (BRE-55). Until then delivery fails closed. Arming a timer can't trap.
    if (not DeliveryToken.isUsableKey(media.hmacSecretKey)) {
        logger.info("No usable HMAC secret key yet; scheduled generating one from raw_rand");
        ignore Timer.setTimer<system>(#seconds 0, generateHmacSecretKey);
    };

    // Timers don't survive upgrades, so re-arm expiry for every order awaiting payment, and the
    // payment watcher if there is one, on install and upgrade. Orders already past `expiresAt` are
    // checked right away. Reads only `awaitingPaymentOrderIds`, not the whole order history (BRE-100).
    transient let rearmedOrders = rearmOrderTimers<system>();
    if (rearmedOrders > 0) {
        logger.info("Re-armed expiry and the payment watcher for " # debug_show (rearmedOrders) # " orders awaiting payment");
    };
};
