import { expect } "mo:test";
import { test; suite } "mo:test/async";

import Blob "mo:core/Blob";
import Error "mo:core/Error";
import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat8 "mo:core/Nat8";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Result";
import Text "mo:core/Text";
import Time "mo:core/Time";

import CoreSet "mo:core/Set";
import Map "mo:map/Map";

import ShopProvisioning "../../../provisioning/shop";
import { mockCreateShop; buildMockCreateShopImplementation } "../../../provisioning/shop/mock";
import ShopInterface "../../../../../interfaces/shop";
import Management "../../../../../interfaces/management";
import WasmVersion "../../../../../lib/WasmVersion";

import { mockReleaseCanister } "../../canister_management/mock";
import ShopAPI "../../shop";
import Fixtures "./fixtures";
import { mockProductIndex } "./mock";

suite(
    "ShopAPI",
    func() : async () {
        await suite(
            "createShop",
            func() : async () {
                await test(
                    "returns error on failure to retrieve WASM for shop canister",
                    func() : async () {
                        let selfPrincipal = Principal.fromText("aaaaa-aa");
                        let caller = Principal.fromText("aaaaa-aa");
                        let req = Fixtures.defaultCreateShopRequest;
                        let baseDependencies = Fixtures.makeDependencies(null);
                        let dependencies = {
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = baseDependencies.ShopService;
                            logger = baseDependencies.logger;
                            releaseCanister = baseDependencies.releaseCanister;
                            canisterFactory = {
                                getWasm = func(_ : WasmVersion.WasmName, _ : WasmVersion.Version) : async Result<{ wasm : Blob; sha256 : Blob }, { #NotFound; #Yanked }> {
                                    #err(#NotFound);
                                };
                                createCanister = baseDependencies.canisterFactory.createCanister;
                                addCanisterToPool = baseDependencies.canisterFactory.addCanisterToPool;
                            };
                            createMediaCanister = baseDependencies.createMediaCanister;
                            productIndex = baseDependencies.productIndex;
                        };
                        let api = ShopAPI.API(dependencies);
                        let res = await ShopAPI.createShop(api, selfPrincipal, caller, req, 1);
                        assert (res == #err(#CanisterCreationFailed("Shop canister WASM not found")));
                    },
                );

                await test(
                    "returns error on failure to create media canister - unauthorized",
                    func() : async () {
                        let selfPrincipal = Principal.fromText("aaaaa-aa");
                        let caller = Principal.fromText("aaaaa-aa");
                        let req = Fixtures.defaultCreateShopRequest;
                        let baseDependencies = Fixtures.makeDependencies(null);
                        let dependencies = {
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = baseDependencies.ShopService;
                            logger = baseDependencies.logger;
                            releaseCanister = baseDependencies.releaseCanister;
                            canisterFactory = baseDependencies.canisterFactory;
                            createMediaCanister = func(_ : Principal) : async Result<Principal, { #Unauthorized; #WasmNotFound; #InsufficientCycles : Text; #FailedToCreate : Text }> {
                                #err(#Unauthorized);
                            };
                            productIndex = baseDependencies.productIndex;
                        };
                        let api = ShopAPI.API(dependencies);
                        let res = await ShopAPI.createShop(api, selfPrincipal, caller, req, 1);
                        assert (res == #err(#CanisterCreationFailed("Unauthorized to create media canister")));
                    },
                );

                await test(
                    "returns error on failure to create media canister - WASM not found",
                    func() : async () {
                        let selfPrincipal = Principal.fromText("aaaaa-aa");
                        let caller = Principal.fromText("aaaaa-aa");
                        let req = Fixtures.defaultCreateShopRequest;
                        let baseDependencies = Fixtures.makeDependencies(null);
                        let dependencies = {
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = baseDependencies.ShopService;
                            logger = baseDependencies.logger;
                            releaseCanister = baseDependencies.releaseCanister;
                            canisterFactory = baseDependencies.canisterFactory;
                            createMediaCanister = func(_ : Principal) : async Result<Principal, { #Unauthorized; #WasmNotFound; #InsufficientCycles : Text; #FailedToCreate : Text }> {
                                #err(#WasmNotFound);
                            };
                            productIndex = baseDependencies.productIndex;
                        };
                        let api = ShopAPI.API(dependencies);
                        let res = await ShopAPI.createShop(api, selfPrincipal, caller, req, 1);
                        assert (res == #err(#CanisterCreationFailed("Media canister WASM not found")));
                    },
                );

                await test(
                    "returns error on failure to create media canister - Insufficient cycles",
                    func() : async () {
                        let selfPrincipal = Principal.fromText("aaaaa-aa");
                        let caller = Principal.fromText("aaaaa-aa");
                        let req = Fixtures.defaultCreateShopRequest;
                        let baseDependencies = Fixtures.makeDependencies(null);
                        let dependencies = {
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = baseDependencies.ShopService;
                            logger = baseDependencies.logger;
                            releaseCanister = baseDependencies.releaseCanister;
                            canisterFactory = baseDependencies.canisterFactory;
                            createMediaCanister = func(_ : Principal) : async Result<Principal, { #Unauthorized; #WasmNotFound; #InsufficientCycles : Text; #FailedToCreate : Text }> {
                                #err(#InsufficientCycles("Not enough cycles"));
                            };
                            productIndex = baseDependencies.productIndex;
                        };
                        let api = ShopAPI.API(dependencies);
                        let res = await ShopAPI.createShop(api, selfPrincipal, caller, req, 1);
                        assert (res == #err(#CanisterCreationFailed("Insufficient cycles to create media canister: Not enough cycles")));
                    },
                );

                await test(
                    "returns error if media canister installation fails",
                    func() : async () {
                        let selfPrincipal = Principal.fromText("aaaaa-aa");
                        let caller = Principal.fromText("aaaaa-aa");
                        let req = Fixtures.defaultCreateShopRequest;
                        let baseDependencies = Fixtures.makeDependencies(null);
                        let dependencies = {
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = baseDependencies.ShopService;
                            logger = baseDependencies.logger;
                            releaseCanister = baseDependencies.releaseCanister;
                            canisterFactory = baseDependencies.canisterFactory;
                            createMediaCanister = func(_ : Principal) : async Result<Principal, { #Unauthorized; #WasmNotFound; #InsufficientCycles : Text; #FailedToCreate : Text }> {
                                #err(#FailedToCreate("Failed to create Media canister: out of cycles"));
                            };
                            productIndex = baseDependencies.productIndex;
                        };
                        let api = ShopAPI.API(dependencies);
                        let res = await ShopAPI.createShop(api, selfPrincipal, caller, req, 1);
                        assert (res == #err(#CanisterCreationFailed("Failed to create Media canister: out of cycles")));
                    },
                );

                await test(
                    "returns error and releases media canister if canister factory returns unauthorized when creating shop canister",
                    func() : async () {
                        let selfPrincipal = Principal.fromText("aaaaa-aa");
                        let caller = Principal.fromText("aaaaa-aa");
                        let req = Fixtures.defaultCreateShopRequest;
                        let mockedReleaseCanister = mockReleaseCanister();
                        let baseDependencies = Fixtures.makeDependencies(null);
                        let dependencies = {
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = baseDependencies.ShopService;
                            logger = baseDependencies.logger;
                            releaseCanister = mockedReleaseCanister.fn;
                            canisterFactory = {
                                getWasm = baseDependencies.canisterFactory.getWasm;
                                createCanister = func(canisterSettings : ?Management.CanisterSettings) : async Result<{ canisterId : Principal; isNewCanister : Bool }, { #Unauthorized : Text }> {
                                    #err(#Unauthorized("Access denied"));
                                };
                                addCanisterToPool = baseDependencies.canisterFactory.addCanisterToPool;
                            };
                            createMediaCanister = baseDependencies.createMediaCanister;
                            productIndex = baseDependencies.productIndex;
                        };
                        let api = ShopAPI.API(dependencies);
                        let res = await ShopAPI.createShop(api, selfPrincipal, caller, req, 1);

                        expect.nat(List.size(mockedReleaseCanister.calls)).equal(1);

                        let firstCall = Option.unwrap(List.get(mockedReleaseCanister.calls, 0));
                        expect.principal(firstCall.args.0).equal(Principal.fromText("aaaaa-aa"));

                        assert (res == #err(#CanisterCreationFailed("Failed to create shop canister: Unauthorized request to canister factory")));
                    },
                );

                await test(
                    "returns error and releases media and shop canisters if shop service returns InsufficientCycles error during shop creation",
                    func() : async () {
                        let selfPrincipal = Principal.fromText("aaaaa-aa");
                        let caller = Principal.fromText("aaaaa-aa");
                        let req = Fixtures.defaultCreateShopRequest;
                        let mockedReleaseCanister = mockReleaseCanister();
                        let baseDependencies = Fixtures.makeDependencies(null);
                        let dependencies = {
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = {
                                createShop = mockCreateShop(
                                    ?buildMockCreateShopImplementation(
                                        func() : async ShopProvisioning.CreateShopResponse {
                                            #err(#InsufficientCycles("Not enough cycles to create shop"));
                                        }
                                    )
                                ).fn;
                            };
                            logger = baseDependencies.logger;
                            releaseCanister = mockedReleaseCanister.fn;
                            canisterFactory = {
                                getWasm = baseDependencies.canisterFactory.getWasm;
                                createCanister = func(canisterSettings : ?Management.CanisterSettings) : async Result<{ canisterId : Principal; isNewCanister : Bool }, { #Unauthorized : Text }> {
                                    #ok({
                                        canisterId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                                        isNewCanister = true;
                                    });
                                };
                                addCanisterToPool = baseDependencies.canisterFactory.addCanisterToPool;
                            };
                            createMediaCanister = baseDependencies.createMediaCanister;
                            productIndex = baseDependencies.productIndex;
                        };
                        let api = ShopAPI.API(dependencies);
                        let res = await ShopAPI.createShop(api, selfPrincipal, caller, req, 1);

                        expect.nat(List.size(mockedReleaseCanister.calls)).equal(2);

                        let firstCall = Option.unwrap(List.get(mockedReleaseCanister.calls, 0));
                        expect.principal(firstCall.args.0).equal(Principal.fromText("uxrrr-q7777-77774-qaaaq-cai"));

                        let secondCall = Option.unwrap(List.get(mockedReleaseCanister.calls, 1));
                        expect.principal(secondCall.args.0).equal(Principal.fromText("aaaaa-aa"));

                        assert (res == #err(#CanisterCreationFailed("Insufficient cycles to create shop canister: Not enough cycles to create shop")));
                    },
                );

                await test(
                    "returns error and keeps a pooled shop canister out of the pool if the shop service reports it unusable",
                    func() : async () {
                        let selfPrincipal = Principal.fromText("aaaaa-aa");
                        let caller = Principal.fromText("aaaaa-aa");
                        let req = Fixtures.defaultCreateShopRequest;
                        let mockedReleaseCanister = mockReleaseCanister();
                        let baseDependencies = Fixtures.makeDependencies(null);
                        let dependencies = {
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = {
                                createShop = mockCreateShop(
                                    ?buildMockCreateShopImplementation(
                                        func() : async ShopProvisioning.CreateShopResponse {
                                            #err(#UnusableCanister("canister_status failed"));
                                        }
                                    )
                                ).fn;
                            };
                            logger = baseDependencies.logger;
                            releaseCanister = mockedReleaseCanister.fn;
                            canisterFactory = {
                                getWasm = baseDependencies.canisterFactory.getWasm;
                                createCanister = func(canisterSettings : ?Management.CanisterSettings) : async Result<{ canisterId : Principal; isNewCanister : Bool }, { #Unauthorized : Text }> {
                                    #ok({
                                        canisterId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                                        isNewCanister = false;
                                    });
                                };
                                addCanisterToPool = baseDependencies.canisterFactory.addCanisterToPool;
                            };
                            createMediaCanister = baseDependencies.createMediaCanister;
                            productIndex = baseDependencies.productIndex;
                        };
                        let api = ShopAPI.API(dependencies);
                        let res = await ShopAPI.createShop(api, selfPrincipal, caller, req, 1);

                        // Only the media canister goes back to the pool.
                        expect.nat(List.size(mockedReleaseCanister.calls)).equal(1);

                        let firstCall = Option.unwrap(List.get(mockedReleaseCanister.calls, 0));
                        expect.principal(firstCall.args.0).equal(Principal.fromText("aaaaa-aa"));

                        assert (res == #err(#CanisterCreationFailed("Pooled shop canister is unusable: canister_status failed")));
                    },
                );

                await test(
                    "returns error and releases media and shop canisters if shop service raises an error during shop creation",
                    func() : async () {
                        let selfPrincipal = Principal.fromText("aaaaa-aa");
                        let caller = Principal.fromText("aaaaa-aa");
                        let req = Fixtures.defaultCreateShopRequest;
                        let mockedReleaseCanister = mockReleaseCanister();
                        let baseDependencies = Fixtures.makeDependencies(null);
                        let dependencies = {
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = {
                                createShop = mockCreateShop(
                                    ?buildMockCreateShopImplementation(
                                        func() : async ShopProvisioning.CreateShopResponse {
                                            throw Error.reject("Uh-oh, something went wrong!");
                                        }
                                    )
                                ).fn;
                            };
                            logger = baseDependencies.logger;
                            releaseCanister = mockedReleaseCanister.fn;
                            canisterFactory = {
                                getWasm = baseDependencies.canisterFactory.getWasm;
                                createCanister = func(canisterSettings : ?Management.CanisterSettings) : async Result<{ canisterId : Principal; isNewCanister : Bool }, { #Unauthorized : Text }> {
                                    #ok({
                                        canisterId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                                        isNewCanister = true;
                                    });
                                };
                                addCanisterToPool = baseDependencies.canisterFactory.addCanisterToPool;
                            };
                            createMediaCanister = baseDependencies.createMediaCanister;
                            productIndex = baseDependencies.productIndex;
                        };
                        let api = ShopAPI.API(dependencies);
                        let res = await ShopAPI.createShop(api, selfPrincipal, caller, req, 1);

                        expect.nat(List.size(mockedReleaseCanister.calls)).equal(2);

                        let firstCall = Option.unwrap(List.get(mockedReleaseCanister.calls, 0));
                        expect.principal(firstCall.args.0).equal(Principal.fromText("uxrrr-q7777-77774-qaaaq-cai"));

                        let secondCall = Option.unwrap(List.get(mockedReleaseCanister.calls, 1));
                        expect.principal(secondCall.args.0).equal(Principal.fromText("aaaaa-aa"));

                        assert (res == #err(#CanisterCreationFailed("Failed to create shop canister: Uh-oh, something went wrong!")));
                    },
                );

                await test(
                    "successfully creates shop canister",
                    func() : async () {
                        let selfPrincipal = Principal.fromText("aaaaa-aa");
                        let caller = Principal.fromText("aaaaa-aa");
                        let req = Fixtures.defaultCreateShopRequest;
                        let dependencies = Fixtures.makeDependencies(null);
                        let api = ShopAPI.API(dependencies);
                        let res = await ShopAPI.createShop(api, selfPrincipal, caller, req, 1);
                        let (item, mediaCanisterId) = switch (res) {
                            case (#ok(val)) { val };
                            case (#err(_)) {
                                assert false;
                                return;
                            };
                        };

                        expect.principal(item.canisterId).equal(Principal.fromText("aaaaa-aa"));
                        expect.principal(item.owner).equal(caller);
                        expect.text(item.shopDetails.name).equal("Test Shop");
                        expect.text(item.shopDetails.description).equal("Test Description");
                        expect.option<Text>(item.shopDetails.logoUrl, func(url) { url }, Text.equal).equal(null);
                        expect.option<Text>(item.shopDetails.bannerImageUrl, func(url) { url }, Text.equal).equal(null);
                        expect.option<ShopInterface.ShopLocation>(item.shopDetails.physicalLocation, func(loc) { debug_show (loc) }, func(locA, locB) { debug_show (locA) == debug_show (locB) }).equal(null);
                        expect.bool(item.shopDetails.locationPublic).equal(false);
                        expect.principal(item.registeredBy).equal(caller);
                        assert (item.registrationDate == Time.now());
                        expect.principal(mediaCanisterId).equal(Principal.fromText("aaaaa-aa"));
                    },
                );
            },
        );

        await suite(
            "listShops",
            func() : async () {
                await test(
                    "returns empty list when registry is empty",
                    func() : async () {
                        let dependencies = Fixtures.makeDependencies(null);
                        let api = ShopAPI.API(dependencies);
                        let shops = ShopAPI.listShops(api, null, null).items;
                        expect.nat(Array.size(shops)).equal(0);
                    },
                );

                await test(
                    "maps registry items to public shop info",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let item = Fixtures.shopRegistryItem(
                            shopId,
                            "Breeze Market",
                            "Fresh goods",
                            ?"https://example.com/logo.png",
                            ?#PostalCode("90210"),
                            true,
                        );
                        let _ = Map.put(registry, Map.phash, shopId, item);
                        let dependencies = Fixtures.makeDependencies(?registry);
                        let api = ShopAPI.API(dependencies);
                        let shops = ShopAPI.listShops(api, null, null).items;

                        expect.nat(Array.size(shops)).equal(1);
                        expect.principal(shops[0].canisterId).equal(shopId);
                        expect.text(shops[0].name).equal("Breeze Market");
                        expect.text(shops[0].description).equal("Fresh goods");
                        expect.option<Text>(shops[0].logoUrl, func(url) { url }, Text.equal).equal(?"https://example.com/logo.png");
                        expect.option<ShopInterface.ShopLocation>(
                            shops[0].physicalLocation,
                            func(loc) { debug_show (loc) },
                            func(locA, locB) {
                                debug_show (locA) == debug_show (locB);
                            },
                        ).equal(?#PostalCode("90210"));
                        expect.bool(shops[0].locationPublic).equal(true);
                    },
                );

                await test(
                    "omits the location of a shop whose location isn't public",
                    func() : async () {
                        let publicShop = Principal.fromText("aaaaa-aa");
                        let privateShop = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            publicShop,
                            Fixtures.shopRegistryItem(publicShop, "Public Shop", "", null, ?#PostalCode("90210"), true),
                        );
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            privateShop,
                            Fixtures.shopRegistryItem(privateShop, "Private Shop", "", null, ?#PostalCode("10001"), false),
                        );
                        let api = ShopAPI.API(Fixtures.makeDependencies(?registry));
                        let shops = ShopAPI.listShops(api, null, null).items;

                        expect.nat(Array.size(shops)).equal(2);
                        for (shop in shops.vals()) {
                            let expected : ?ShopInterface.ShopLocation = if (shop.canisterId == publicShop) {
                                ?#PostalCode("90210");
                            } else { null };
                            expect.option<ShopInterface.ShopLocation>(
                                shop.physicalLocation,
                                func(loc) { debug_show (loc) },
                                func(locA, locB) {
                                    debug_show (locA) == debug_show (locB);
                                },
                            ).equal(expected);
                            expect.bool(shop.locationPublic).equal(shop.canisterId == publicShop);
                        };
                    },
                );

                await test(
                    "returns all registered shops",
                    func() : async () {
                        let shopA = Principal.fromText("aaaaa-aa");
                        let shopB = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopA,
                            Fixtures.shopRegistryItem(shopA, "Shop A", "First shop", null, null, false),
                        );
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopB,
                            Fixtures.shopRegistryItem(shopB, "Shop B", "Second shop", null, null, false),
                        );
                        let dependencies = Fixtures.makeDependencies(?registry);
                        let api = ShopAPI.API(dependencies);
                        let shops = Fixtures.sortShopsByCanisterId(ShopAPI.listShops(api, null, null).items);

                        expect.nat(Array.size(shops)).equal(2);
                        expect.text(shops[0].name).equal("Shop A");
                        expect.text(shops[1].name).equal("Shop B");
                    },
                );

                await test(
                    "pages in canister ID order from the cursor (BRE-96)",
                    func() : async () {
                        let ids = [Principal.fromText("aaaaa-aa"), Principal.fromText("uxrrr-q7777-77774-qaaaq-cai"), Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai")];
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        for (id in ids.vals()) {
                            let _ = Map.put(registry, Map.phash, id, Fixtures.shopRegistryItem(id, Principal.toText(id), "", null, null, false));
                        };
                        let api = ShopAPI.API(Fixtures.makeDependencies(?registry));
                        let first = ShopAPI.listShops(api, null, ?2);
                        expect.nat(first.items.size()).equal(2);
                        let second = ShopAPI.listShops(api, first.next, ?2);
                        expect.nat(second.items.size()).equal(1);
                        expect.bool(second.next == null).isTrue();
                        let listed = Array.map<ShopAPI.PublicShopInfo, Principal>(Array.concat(first.items, second.items), func(s) = s.canisterId);
                        expect.bool(listed == Array.sort(ids, Principal.compare)).isTrue();
                    },
                );

                await test(
                    "a rename moves the shop in the name index and unregistering removes it (BRE-96)",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let api = ShopAPI.API(Fixtures.makeDependencies(null));
                        let item = Fixtures.shopRegistryItem(shopId, "Old Name", "", null, null, false);
                        ShopAPI.putShopRegistryAndIndexes(api, item, ShopAPI.normalizeShopName("Old Name"));
                        ShopAPI.putShopRegistryAndIndexes(api, { item with shopDetails = { item.shopDetails with name = "New Name" } }, ShopAPI.normalizeShopName("New Name"));
                        let names = Array.map<ShopAPI.ShopNameKey, Text>(CoreSet.toArray(api.shopsByDisplayName), func(k) = k.name);
                        expect.bool(names == ["New Name"]).isTrue();
                        expect.nat(CoreSet.size(api.shopIdsOrdered)).equal(1);
                        ignore ShopAPI.unregisterShop(api, shopId);
                        expect.nat(CoreSet.size(api.shopsByDisplayName)).equal(0);
                        expect.nat(CoreSet.size(api.shopIdsOrdered)).equal(0);
                        expect.nat(ShopAPI.listShops(api, null, null).items.size()).equal(0);
                    },
                );
            },
        );

        await suite(
            "registerShop",
            func() : async () {
                await test(
                    "returns Unauthenticated for anonymous caller",
                    func() : async () {
                        let api = ShopAPI.API(Fixtures.makeDependencies(null));
                        let res = await ShopAPI.registerShop(
                            api,
                            Principal.anonymous(),
                            {
                                canisterId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                            },
                            func _ = true,
                            Fixtures.defaultRegisterShopHooks([]),
                        );
                        assert (res == #err(#Unauthenticated));
                    },
                );

                await test(
                    "returns AlreadyRegistered when shop is already in registry",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let caller = Principal.fromText("aaaaa-aa");
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopId,
                            Fixtures.shopRegistryItem(shopId, "Existing Shop", "Already registered", null, null, false),
                        );
                        var subscribeCalls = List.empty<Principal>();
                        let api = ShopAPI.API(Fixtures.makeDependencies(?registry));
                        let res = await ShopAPI.registerShop(
                            api,
                            caller,
                            { canisterId = shopId },
                            func _ = true,
                            {
                                getControllers = func(_ : Principal) : async [Principal] {
                                    [caller];
                                };
                                getShopDetails = Fixtures.defaultRegisterShopHooks([caller]).getShopDetails;
                                subscribeToShopEvents = func(canisterId : Principal) : async () {
                                    subscribeCalls.add(canisterId);
                                };
                            },
                        );

                        assert (res == #err(#AlreadyRegistered));
                        expect.nat(List.size(subscribeCalls)).equal(1);
                        expect.principal(Option.unwrap(List.get(subscribeCalls, 0))).equal(shopId);
                    },
                );

                await test(
                    "returns ShopNameConflict when normalized name is taken by another shop",
                    func() : async () {
                        let existingShopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let newShopId = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
                        let caller = Principal.fromText("aaaaa-aa");
                        let api = ShopAPI.API(Fixtures.makeDependencies(null));
                        let normalizedName = ShopAPI.normalizeShopName("Taken Name");
                        let _ = Map.put(api.shopRegistryByName, Map.thash, normalizedName, existingShopId);

                        expect.bool(ShopAPI.shopNameConflicts(api, normalizedName, ?newShopId)).equal(true);

                        var subscribeCalls = List.empty<Principal>();
                        let res = await ShopAPI.registerShop(
                            api,
                            caller,
                            { canisterId = newShopId },
                            func _ = true,
                            {
                                getControllers = func(_ : Principal) : async [Principal] {
                                    [caller];
                                };
                                getShopDetails = func(_ : Principal) : async ShopAPI.ShopCanisterDetails {
                                    Fixtures.defaultShopCanisterDetails("Taken Name", "Another shop with same name");
                                };
                                subscribeToShopEvents = func(canisterId : Principal) : async () {
                                    subscribeCalls.add(canisterId);
                                };
                            },
                        );

                        assert (res == #err(#ShopNameConflict));
                        expect.nat(List.size(subscribeCalls)).equal(0);
                        expect.nat(Map.size(api.shopRegistry)).equal(0);
                    },
                );

                await test(
                    "rejects an unregistered user, a non-controller and a user at the cap, without calling the shop",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let caller = Principal.fromText("aaaaa-aa");
                        let other = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
                        var detailsCalls = 0;
                        func hooks(controllers : [Principal]) : ShopAPI.RegisterShopHooks {
                            {
                                getControllers = func(_ : Principal) : async [Principal] {
                                    controllers;
                                };
                                getShopDetails = func(_ : Principal) : async ShopAPI.ShopCanisterDetails {
                                    detailsCalls += 1;
                                    Fixtures.defaultShopCanisterDetails("Mine", "");
                                };
                                subscribeToShopEvents = func(_ : Principal) : async () {};
                            };
                        };
                        let api = ShopAPI.API(Fixtures.makeDependencies(null));

                        let notUser = await ShopAPI.registerShop(api, caller, { canisterId = shopId }, func _ = false, hooks([caller]));
                        assert (notUser == #err(#UserNotRegistered));

                        let notController = await ShopAPI.registerShop(api, caller, { canisterId = shopId }, func _ = true, hooks([other]));
                        assert (notController == #err(#NotController));
                        expect.nat(detailsCalls).equal(0);
                        expect.nat(Map.size(api.shopRegistry)).equal(0);

                        // A caller already managing the maximum number of registered shops.
                        let managed = List.empty<Principal>();
                        var n : Nat = 0;
                        while (n < ShopAPI.MAX_REGISTERED_SHOPS_PER_USER) {
                            let id = Principal.fromBlob(Blob.fromArray([Nat8.fromNat(n), 1]));
                            List.add(managed, id);
                            ignore Map.put(api.shopRegistry, Map.phash, id, Fixtures.shopRegistryItem(id, "Shop " # Nat.toText(n), "", null, null, false));
                            n += 1;
                        };
                        ignore Map.put(api.managedShopsByUser, Map.phash, caller, List.toArray(managed));
                        let tooMany = await ShopAPI.registerShop(api, caller, { canisterId = shopId }, func _ = true, hooks([caller]));
                        assert (tooMany == #err(#TooManyShops));
                    },
                );

                await test(
                    "returns ShopUnreachable when a call to the canister fails",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let caller = Principal.fromText("aaaaa-aa");
                        let api = ShopAPI.API(Fixtures.makeDependencies(null));
                        let good = Fixtures.defaultRegisterShopHooks([caller]);
                        let noStatus = await ShopAPI.registerShop(api, caller, { canisterId = shopId }, func _ = true, { good with getControllers = func(_ : Principal) : async [Principal] { throw Error.reject("not a status viewer") } });
                        assert (switch (noStatus) { case (#err(#ShopUnreachable(_))) true; case _ false });
                        let noSubscribe = await ShopAPI.registerShop(api, caller, { canisterId = shopId }, func _ = true, { good with subscribeToShopEvents = func(_ : Principal) : async () { throw Error.reject("timed out") } });
                        assert (switch (noSubscribe) { case (#err(#ShopUnreachable(_))) true; case _ false });
                        expect.nat(Map.size(api.shopRegistry)).equal(0);
                    },
                );

                await test(
                    "successfully registers shop and updates indexes",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let caller = Principal.fromText("aaaaa-aa");
                        var subscribeCalls = List.empty<Principal>();
                        let api = ShopAPI.API(Fixtures.makeDependencies(null));
                        let res = await ShopAPI.registerShop(
                            api,
                            caller,
                            { canisterId = shopId },
                            func _ = true,
                            {
                                getControllers = func(_ : Principal) : async [Principal] {
                                    [caller];
                                };
                                getShopDetails = func(_ : Principal) : async ShopAPI.ShopCanisterDetails {
                                    {
                                        name = "Breeze Market";
                                        description = "Fresh goods";
                                        logoUrl = ?"https://example.com/logo.png";
                                        bannerImageUrl = ?"https://example.com/banner.png";
                                        physicalLocation = ?#PostalCode("90210");
                                        showPhysicalLocation = true;
                                    };
                                };
                                subscribeToShopEvents = func(canisterId : Principal) : async () {
                                    subscribeCalls.add(canisterId);
                                };
                            },
                        );

                        assert (res == #ok);
                        expect.nat(List.size(subscribeCalls)).equal(1);
                        expect.principal(Option.unwrap(List.get(subscribeCalls, 0))).equal(shopId);

                        let item = Option.unwrap(Map.get(api.shopRegistry, Map.phash, shopId));
                        expect.principal(item.canisterId).equal(shopId);
                        expect.principal(item.owner).equal(caller);
                        expect.text(item.shopDetails.name).equal("Breeze Market");
                        expect.text(item.shopDetails.description).equal("Fresh goods");
                        expect.option<Text>(item.shopDetails.logoUrl, func(url) { url }, Text.equal).equal(?"https://example.com/logo.png");
                        expect.bool(item.shopDetails.locationPublic).equal(true);
                        expect.principal(item.registeredBy).equal(caller);
                        assert (item.registrationDate == Time.now());

                        expect.principal(Option.unwrap(Map.get(api.shopRegistryByOwner, Map.phash, caller))).equal(shopId);
                        expect.principal(
                            Option.unwrap(Map.get(api.shopRegistryByName, Map.thash, ShopAPI.normalizeShopName("Breeze Market")))
                        ).equal(shopId);
                        let managedShops = Option.unwrap(Map.get(api.managedShopsByUser, Map.phash, caller));
                        expect.nat(Array.size(managedShops)).equal(1);
                        expect.principal(managedShops[0]).equal(shopId);
                    },
                );
            },
        );

        await suite(
            "unregisterShop",
            func() : async () {
                await test(
                    "returns error when shop is not found",
                    func() : async () {
                        let dependencies = Fixtures.makeDependencies(null);
                        let api = ShopAPI.API(dependencies);
                        let res = ShopAPI.unregisterShop(api, Principal.fromText("uxrrr-q7777-77774-qaaaq-cai"));
                        assert (res == #err("Shop not found"));
                    },
                );

                await test(
                    "lets the owner and an admin unregister, but not another caller",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let owner = Principal.fromText("aaaaa-aa");
                        let other = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        ignore Map.put(registry, Map.phash, shopId, { Fixtures.shopRegistryItem(shopId, "Mine", "", null, null, false) with owner });
                        let api = ShopAPI.API(Fixtures.makeDependencies(?registry));
                        assert (ShopAPI.unregisterShopAs(api, other, false, shopId) == #err("Unauthorized"));
                        assert (ShopAPI.unregisterShopAs(api, Principal.anonymous(), false, shopId) == #err("Unauthorized"));
                        assert (Map.has(api.shopRegistry, Map.phash, shopId));
                        assert (ShopAPI.unregisterShopAs(api, owner, false, shopId) == #ok);
                        assert (not Map.has(api.shopRegistry, Map.phash, shopId));
                    },
                );

                await test(
                    "removes shop from registry and indexes",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let owner = Principal.fromText("2vxsx-fae");
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let item = {
                            canisterId = shopId;
                            slug = "shop-" # Principal.toText(shopId);
                            owner;
                            shopDetails = {
                                name = "Breeze Market";
                                description = "Fresh goods";
                                logoUrl = null;
                                bannerImageUrl = null;
                                physicalLocation = null;
                                locationPublic = false;
                            };
                            registeredBy = owner;
                            registrationDate = Time.now();
                            presentation = #storefront;
                        };
                        let _ = Map.put(registry, Map.phash, shopId, item);
                        let baseDependencies = Fixtures.makeDependencies(?registry);
                        let api = ShopAPI.API(baseDependencies);

                        let res = ShopAPI.unregisterShop(api, shopId);
                        assert (res == #ok);

                        expect.bool(Map.has(api.shopRegistry, Map.phash, shopId)).equal(false);
                        expect.bool(Map.has(api.shopRegistryByOwner, Map.phash, owner)).equal(false);
                        expect.bool(
                            Map.has(api.shopRegistryByName, Map.thash, ShopAPI.normalizeShopName("Breeze Market"))
                        ).equal(false);
                    },
                );
            },
        );

        await suite(
            "syncShopDetails",
            func() : async () {
                await test(
                    "no-ops for anonymous caller",
                    func() : async () {
                        let api = ShopAPI.API(Fixtures.makeDependencies(null));
                        ShopAPI.syncShopDetails(api, Principal.anonymous(), Fixtures.shopDetailsUpdatedEvent("New Name", "New Description"));
                        expect.nat(Map.size(api.shopRegistry)).equal(0);
                    },
                );

                await test(
                    "no-ops when shop is not registered",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let api = ShopAPI.API(Fixtures.makeDependencies(null));
                        ShopAPI.syncShopDetails(api, shopId, Fixtures.shopDetailsUpdatedEvent("New Name", "New Description"));
                        expect.nat(Map.size(api.shopRegistry)).equal(0);
                    },
                );

                await test(
                    "skips update when normalized name conflicts with another shop",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let otherShopId = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopId,
                            Fixtures.shopRegistryItem(shopId, "Original Shop", "Original description", null, null, false),
                        );
                        let api = ShopAPI.API(Fixtures.makeDependencies(?registry));
                        let _ = Map.put(api.shopRegistryByName, Map.thash, ShopAPI.normalizeShopName("Taken Name"), otherShopId);

                        ShopAPI.syncShopDetails(api, shopId, Fixtures.shopDetailsUpdatedEvent("Taken Name", "Updated description"));

                        let item = Option.unwrap(Map.get(api.shopRegistry, Map.phash, shopId));
                        expect.text(item.shopDetails.name).equal("Original Shop");
                        expect.text(item.shopDetails.description).equal("Original description");
                    },
                );

                await test(
                    "records the presentation a shop sends and keeps it when an older shop's event has none",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopId,
                            Fixtures.shopRegistryItem(shopId, "Gus", "Songs", null, null, false),
                        );
                        let api = ShopAPI.API(Fixtures.makeDependencies(?registry));
                        let presentationOf = func() : ShopInterface.ShopPresentation = Option.unwrap(Map.get(api.shopRegistry, Map.phash, shopId)).presentation;
                        assert presentationOf() == #storefront;

                        ShopAPI.syncShopDetails(api, shopId, Fixtures.shopDetailsEventWithPresentation("Gus", "Songs", ?#artist));
                        assert presentationOf() == #artist;

                        ShopAPI.syncShopDetails(api, shopId, Fixtures.shopDetailsUpdatedEvent("Gus", "New songs"));
                        assert presentationOf() == #artist;

                        ShopAPI.syncShopDetails(api, shopId, Fixtures.shopDetailsEventWithPresentation("Gus", "Songs", ?#storefront));
                        assert presentationOf() == #storefront;
                    },
                );

                await test(
                    "updates shop details and reindexes renamed shop",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopId,
                            Fixtures.shopRegistryItem(shopId, "Old Shop Name", "Old description", null, null, false),
                        );
                        let api = ShopAPI.API(Fixtures.makeDependencies(?registry));

                        ShopAPI.syncShopDetails(api, shopId, Fixtures.shopDetailsUpdatedEvent("New Shop Name", "New description"));

                        let item = Option.unwrap(Map.get(api.shopRegistry, Map.phash, shopId));
                        expect.text(item.shopDetails.name).equal("New Shop Name");
                        expect.text(item.shopDetails.description).equal("New description");
                        expect.option<Text>(item.shopDetails.logoUrl, func(url) { url }, Text.equal).equal(?"https://example.com/logo.png");
                        expect.bool(item.shopDetails.locationPublic).equal(true);
                        expect.principal(
                            Option.unwrap(Map.get(api.shopRegistryByName, Map.thash, ShopAPI.normalizeShopName("New Shop Name")))
                        ).equal(shopId);
                        expect.bool(
                            Map.has(api.shopRegistryByName, Map.thash, ShopAPI.normalizeShopName("Old Shop Name"))
                        ).equal(false);
                    },
                );
            },
        );

        await suite(
            "syncShopProducts",
            func() : async () {
                let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");

                // A ShopAPI with `shopId` registered and the given product_index mock.
                func syncApi(productIndex : ShopAPI.ProductIndexInterface) : ShopAPI.API {
                    let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                    Map.set(registry, Map.phash, shopId, Fixtures.shopRegistryItem(shopId, "Big Shop", "Lots of products", null, null, false));
                    let base = Fixtures.makeDependencies(?registry);
                    ShopAPI.API({ base with productIndex });
                };

                // A shop with products 0..<count, served `pageSize` at a time, each with a long description.
                func catalog(count : Nat, pageSize : Nat) : (Principal, ?ShopInterface.ProductId) -> async ShopAPI.ProductsPage {
                    let description = Text.join(Array.tabulate<Text>(1_000, func _ = "x").values(), "");
                    func(_ : Principal, after : ?ShopInterface.ProductId) : async ShopAPI.ProductsPage {
                        let start = switch (after) {
                            case null { 0 };
                            case (?id) { Nat32.toNat(id) + 1 };
                        };
                        let end = Nat.min(start + pageSize, count);
                        let items = Array.tabulate<ShopInterface.Product>(end - start, func i = { Fixtures.sampleProduct(Nat32.fromNat(start + i)) with description });
                        {
                            items;
                            next = if (end < count) ?Nat32.fromNat(end - 1) else null;
                        };
                    };
                };

                // The text in a batch of listings: a lower bound on its size as a message (the test
                // interpreter has no `to_candid`).
                func listingsBytes(listings : [ShopAPI.MarketplaceProductListing]) : Nat {
                    var n = 0;
                    for (l in listings.values()) {
                        n += l.title.size() + l.description.size();
                        for (v in l.variants.values()) {
                            n += v.name.size() + v.sku.size();
                            for (url in v.imageUrls.values()) {
                                n += url.size();
                            };
                        };
                    };
                    n;
                };

                await test(
                    "rejects a shop that isn't registered",
                    func() : async () {
                        let mocked = mockProductIndex(null);
                        let api = ShopAPI.API({
                            Fixtures.makeDependencies(null) with productIndex = mocked.productIndex
                        });
                        let res = await ShopAPI.syncShopProducts(api, shopId, { getProductsPage = catalog(3, 200) });
                        expect.bool(res == #err(#NotRegistered)).equal(true);
                        expect.nat(List.size(mocked.syncShopProductBatchCalls)).equal(0);
                        expect.nat(List.size(mocked.pruneShopProductsCalls)).equal(0);
                    },
                );

                await test(
                    "syncs 20,000 products in batches under the message limit, then prunes the rest",
                    func() : async () {
                        let mocked = mockProductIndex(?{ syncUpdatedProduct = null; syncDeletedProducts = null; syncShopProductBatch = null; pruneShopProducts = ?(func(_ : Principal, _ : [ShopInterface.ProductId]) : async Result<Nat, Text> { #ok(4) }) });
                        let api = syncApi(mocked.productIndex);
                        let res = await ShopAPI.syncShopProducts(api, shopId, { getProductsPage = catalog(20_000, 200) });
                        expect.bool(res == #ok({ products = 20_000; removed = 4; complete = true })).equal(true);

                        expect.nat(List.size(mocked.syncShopProductBatchCalls)).equal(100);
                        var sent = 0;
                        var total = 0;
                        for (call in List.values(mocked.syncShopProductBatchCalls)) {
                            expect.principal(call.shopId).equal(shopId);
                            let bytes = listingsBytes(call.products);
                            expect.nat(bytes).less(1_000_000);
                            total += bytes;
                            sent += call.products.size();
                        };
                        expect.nat(sent).equal(20_000);
                        // The whole catalog would not have fit in one message.
                        expect.nat(total).greater(2_000_000);
                        let first = Option.unwrap(List.get(mocked.syncShopProductBatchCalls, 0));
                        expect.text(first.products[0].variants[0].sku).equal("SKU-1");

                        expect.nat(List.size(mocked.pruneShopProductsCalls)).equal(1);
                        let prune = Option.unwrap(List.get(mocked.pruneShopProductsCalls, 0));
                        expect.nat(prune.keep.size()).equal(20_000);
                        expect.nat(Map.size(api.productSyncs)).equal(0);
                    },
                );

                await test(
                    "stops at the page cap without pruning",
                    func() : async () {
                        let mocked = mockProductIndex(null);
                        let api = syncApi(mocked.productIndex);
                        // Never returns a last page.
                        let endless = func(_ : Principal, after : ?ShopInterface.ProductId) : async ShopAPI.ProductsPage {
                            let id = switch (after) {
                                case null { 0 : Nat32 };
                                case (?id) { id + 1 };
                            };
                            { items = [Fixtures.sampleProduct(id)]; next = ?id };
                        };
                        let res = await ShopAPI.syncShopProducts(api, shopId, { getProductsPage = endless });
                        expect.bool(res == #ok({ products = ShopAPI.MAX_SYNC_PAGES; removed = 0; complete = false })).equal(true);
                        expect.nat(List.size(mocked.syncShopProductBatchCalls)).equal(ShopAPI.MAX_SYNC_PAGES);
                        expect.nat(List.size(mocked.pruneShopProductsCalls)).equal(0);
                    },
                );

                await test(
                    "a failed batch stops the sync without pruning and releases the lock",
                    func() : async () {
                        var fail = true;
                        let mocked = mockProductIndex(
                            ?{
                                syncUpdatedProduct = null;
                                syncDeletedProducts = null;
                                syncShopProductBatch = ?(func(_ : Principal, _ : [ShopAPI.MarketplaceProductListing]) : async Result<(), Text> { if (fail) #err("full") else #ok });
                                pruneShopProducts = null;
                            }
                        );
                        let api = syncApi(mocked.productIndex);
                        let res = await ShopAPI.syncShopProducts(api, shopId, { getProductsPage = catalog(500, 200) });
                        expect.bool(res == #err(#Failed("full"))).equal(true);
                        expect.nat(List.size(mocked.pruneShopProductsCalls)).equal(0);
                        expect.nat(Map.size(api.productSyncs)).equal(0);

                        fail := false;
                        let retry = await ShopAPI.syncShopProducts(api, shopId, { getProductsPage = catalog(500, 200) });
                        expect.bool(retry == #ok({ products = 500; removed = 0; complete = true })).equal(true);
                    },
                );

                await test(
                    "a shop that traps mid-sync releases the lock",
                    func() : async () {
                        let mocked = mockProductIndex(null);
                        let api = syncApi(mocked.productIndex);
                        let broken = func(_ : Principal, _ : ?ShopInterface.ProductId) : async ShopAPI.ProductsPage {
                            throw Error.reject("shop stopped");
                        };
                        let res = await ShopAPI.syncShopProducts(api, shopId, { getProductsPage = broken });
                        expect.bool(res == #err(#Failed("shop stopped"))).equal(true);
                        expect.nat(Map.size(api.productSyncs)).equal(0);
                    },
                );

                await test(
                    "product events during a sync win over the pages it read, and a second sync is refused",
                    func() : async () {
                        let mocked = mockProductIndex(null);
                        let api = syncApi(mocked.productIndex);
                        let pages = catalog(6, 3);
                        var second : ?Result<ShopAPI.SyncShopProductsResult, ShopAPI.SyncShopProductsError> = null;
                        let racing = func(id : Principal, after : ?ShopInterface.ProductId) : async ShopAPI.ProductsPage {
                            let page = await pages(id, after);
                            if (after == null) {
                                // While the first page is in flight: the shop edits product 1, deletes
                                // product 2 and adds product 9, all past the pages core reads.
                                await ShopAPI.syncUpdatedProduct(api, shopId, { data = ShopAPI.productToMarketplaceListing(Fixtures.sampleProduct(1)) });
                                await ShopAPI.syncDeletedProduct(api, shopId, { data = { productId = 2 } });
                                await ShopAPI.syncUpdatedProduct(api, shopId, { data = ShopAPI.productToMarketplaceListing(Fixtures.sampleProduct(9)) });
                                second := ?(await ShopAPI.syncShopProducts(api, shopId, { getProductsPage = pages }));
                            };
                            page;
                        };
                        let res = await ShopAPI.syncShopProducts(api, shopId, { getProductsPage = racing });
                        expect.bool(second == ?#err(#InProgress)).equal(true);
                        expect.bool(res == #ok({ products = 6; removed = 0; complete = true })).equal(true);

                        let batched = List.empty<Nat32>();
                        for (call in List.values(mocked.syncShopProductBatchCalls)) {
                            for (p in call.products.values()) {
                                List.add(batched, p.productId);
                            };
                        };
                        // Products 1 and 2 came from events, so the stale page copies weren't sent.
                        expect.array(List.toArray(batched), Nat32.toText, Nat32.equal).equal([0, 3, 4, 5]);
                        let keep = Option.unwrap(List.get(mocked.pruneShopProductsCalls, 0)).keep.sort(Nat32.compare);
                        expect.array(keep, Nat32.toText, Nat32.equal).equal([0, 1, 3, 4, 5, 9]);
                    },
                );
            },
        );

        await suite(
            "syncUpdatedProduct",
            func() : async () {
                await test(
                    "no-ops when caller is not a registered shop",
                    func() : async () {
                        let mockedProductIndex = mockProductIndex(null);
                        let baseDependencies = Fixtures.makeDependencies(null);
                        let api = ShopAPI.API({
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = baseDependencies.ShopService;
                            logger = baseDependencies.logger;
                            releaseCanister = baseDependencies.releaseCanister;
                            canisterFactory = baseDependencies.canisterFactory;
                            createMediaCanister = baseDependencies.createMediaCanister;
                            productIndex = mockedProductIndex.productIndex;
                        });

                        await ShopAPI.syncUpdatedProduct(api, Principal.fromText("uxrrr-q7777-77774-qaaaq-cai"), Fixtures.productUpdatedEvent(1));

                        expect.nat(List.size(mockedProductIndex.syncUpdatedProductCalls)).equal(0);
                    },
                );

                await test(
                    "forwards product updates to the product index",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let mockedProductIndex = mockProductIndex(null);
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopId,
                            Fixtures.shopRegistryItem(shopId, "Shop", "Description", null, null, false),
                        );
                        let baseDependencies = Fixtures.makeDependencies(?registry);
                        let api = ShopAPI.API({
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = baseDependencies.ShopService;
                            logger = baseDependencies.logger;
                            releaseCanister = baseDependencies.releaseCanister;
                            canisterFactory = baseDependencies.canisterFactory;
                            createMediaCanister = baseDependencies.createMediaCanister;
                            productIndex = mockedProductIndex.productIndex;
                        });

                        await ShopAPI.syncUpdatedProduct(api, shopId, Fixtures.productUpdatedEvent(3));

                        expect.nat(List.size(mockedProductIndex.syncUpdatedProductCalls)).equal(1);
                        let call = Option.unwrap(List.get(mockedProductIndex.syncUpdatedProductCalls, 0));
                        expect.principal(call.shopId).equal(shopId);
                        expect.nat32(call.product.productId).equal(3);
                        expect.text(call.product.title).equal("Sample Product");
                    },
                );
            },
        );

        await suite(
            "syncDeletedProduct",
            func() : async () {
                await test(
                    "no-ops when caller is not a registered shop",
                    func() : async () {
                        let mockedProductIndex = mockProductIndex(null);
                        let baseDependencies = Fixtures.makeDependencies(null);
                        let api = ShopAPI.API({
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = baseDependencies.ShopService;
                            logger = baseDependencies.logger;
                            releaseCanister = baseDependencies.releaseCanister;
                            canisterFactory = baseDependencies.canisterFactory;
                            createMediaCanister = baseDependencies.createMediaCanister;
                            productIndex = mockedProductIndex.productIndex;
                        });

                        await ShopAPI.syncDeletedProduct(api, Principal.fromText("uxrrr-q7777-77774-qaaaq-cai"), Fixtures.productDeletedEvent(9));

                        expect.nat(List.size(mockedProductIndex.syncDeletedProductsCalls)).equal(0);
                    },
                );

                await test(
                    "forwards deleted product ids to the product index",
                    func() : async () {
                        let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                        let mockedProductIndex = mockProductIndex(null);
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopId,
                            Fixtures.shopRegistryItem(shopId, "Shop", "Description", null, null, false),
                        );
                        let baseDependencies = Fixtures.makeDependencies(?registry);
                        let api = ShopAPI.API({
                            shopRegistry = baseDependencies.shopRegistry;
                            shopRegistryByOwner = baseDependencies.shopRegistryByOwner;
                            shopRegistryByName = baseDependencies.shopRegistryByName;
                            shopIdsOrdered = baseDependencies.shopIdsOrdered;
                            shopsByDisplayName = baseDependencies.shopsByDisplayName;
                            artistShops = baseDependencies.artistShops;
                            hiddenShops = baseDependencies.hiddenShops;
                            hiddenShopsCopy = baseDependencies.hiddenShopsCopy;
                            managedShopsByUser = baseDependencies.managedShopsByUser;
                            slugs = baseDependencies.slugs;
                            slugReservedByQuote = baseDependencies.slugReservedByQuote;
                            ShopService = baseDependencies.ShopService;
                            logger = baseDependencies.logger;
                            releaseCanister = baseDependencies.releaseCanister;
                            canisterFactory = baseDependencies.canisterFactory;
                            createMediaCanister = baseDependencies.createMediaCanister;
                            productIndex = mockedProductIndex.productIndex;
                        });

                        await ShopAPI.syncDeletedProduct(api, shopId, Fixtures.productDeletedEvent(9));

                        expect.nat(List.size(mockedProductIndex.syncDeletedProductsCalls)).equal(1);
                        let call = Option.unwrap(List.get(mockedProductIndex.syncDeletedProductsCalls, 0));
                        expect.principal(call.shopId).equal(shopId);
                        expect.nat(Array.size(call.productIds)).equal(1);
                        expect.nat32(call.productIds[0]).equal(9);
                    },
                );
            },
        );

        await suite(
            "addManagedShop",
            func() : async () {
                let registeredUser = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
                let shopId = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                let isRegisteredUser = func(principal : Principal) : Bool {
                    principal == registeredUser;
                };

                await test(
                    "returns Unauthorized for anonymous caller",
                    func() : async () {
                        let api = ShopAPI.API(Fixtures.makeDependencies(null));
                        let res = ShopAPI.addManagedShop(api, Principal.anonymous(), shopId, isRegisteredUser);
                        assert (res == #err(#Unauthorized("Must be signed in to add a shop")));
                    },
                );

                await test(
                    "returns Unauthorized for unregistered user",
                    func() : async () {
                        let api = ShopAPI.API(Fixtures.makeDependencies(null));
                        let res = ShopAPI.addManagedShop(api, Principal.fromText("aaaaa-aa"), shopId, isRegisteredUser);
                        assert (res == #err(#Unauthorized("User not registered")));
                    },
                );

                await test(
                    "returns NotFound when shop is not in registry",
                    func() : async () {
                        let api = ShopAPI.API(Fixtures.makeDependencies(null));
                        let res = ShopAPI.addManagedShop(api, registeredUser, shopId, isRegisteredUser);
                        assert (res == #err(#NotFound("Shop not found")));
                    },
                );

                await test(
                    "returns AlreadyAdded when shop is already managed",
                    func() : async () {
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopId,
                            Fixtures.shopRegistryItem(shopId, "Managed Shop", "Description", null, null, false),
                        );
                        let api = ShopAPI.API(Fixtures.makeDependencies(?registry));
                        let _ = Map.put(api.managedShopsByUser, Map.phash, registeredUser, [shopId]);

                        let res = ShopAPI.addManagedShop(api, registeredUser, shopId, isRegisteredUser);
                        assert (res == #err(#AlreadyAdded("You already manage this shop")));
                    },
                );

                await test(
                    "adds shop to managed shops for registered user",
                    func() : async () {
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopId,
                            Fixtures.shopRegistryItem(shopId, "Managed Shop", "Description", null, null, false),
                        );
                        let api = ShopAPI.API(Fixtures.makeDependencies(?registry));

                        let res = ShopAPI.addManagedShop(api, registeredUser, shopId, isRegisteredUser);
                        assert (res == #ok);

                        let managedShops = Option.unwrap(Map.get(api.managedShopsByUser, Map.phash, registeredUser));
                        expect.nat(Array.size(managedShops)).equal(1);
                        expect.principal(managedShops[0]).equal(shopId);
                    },
                );
            },
        );

        await suite(
            "getUserShops",
            func() : async () {
                let user = Principal.fromText("vg3po-ix777-77774-qaafa-cai");
                let shopA = Principal.fromText("uxrrr-q7777-77774-qaaaq-cai");
                let shopB = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");

                await test(
                    "returns empty list when user has no shops",
                    func() : async () {
                        let api = ShopAPI.API(Fixtures.makeDependencies(null));
                        let shops = ShopAPI.getUserShops(api, user);
                        expect.nat(Array.size(shops)).equal(0);
                    },
                );

                await test(
                    "returns managed shops with names",
                    func() : async () {
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopA,
                            Fixtures.shopRegistryItem(shopA, "Shop A", "First shop", null, null, false),
                        );
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopB,
                            Fixtures.shopRegistryItem(shopB, "Shop B", "Second shop", null, null, false),
                        );
                        let api = ShopAPI.API(Fixtures.makeDependencies(?registry));
                        let _ = Map.put(api.managedShopsByUser, Map.phash, user, [shopA, shopB]);

                        let shops = ShopAPI.getUserShops(api, user);
                        expect.nat(Array.size(shops)).equal(2);
                        expect.principal(shops[0].canisterId).equal(shopA);
                        expect.text(shops[0].name).equal("Shop A");
                        expect.principal(shops[1].canisterId).equal(shopB);
                        expect.text(shops[1].name).equal("Shop B");
                    },
                );

                await test(
                    "falls back to owner index when user has no managed shops",
                    func() : async () {
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let item = {
                            canisterId = shopA;
                            slug = "shop-" # Principal.toText(shopA);
                            owner = user;
                            shopDetails = {
                                name = "Owned Shop";
                                description = "Owned by user";
                                logoUrl = null;
                                bannerImageUrl = null;
                                physicalLocation = null;
                                locationPublic = false;
                            };
                            registeredBy = user;
                            registrationDate = Time.now();
                            presentation = #storefront;
                        };
                        let _ = Map.put(registry, Map.phash, shopA, item);
                        let api = ShopAPI.API(Fixtures.makeDependencies(?registry));

                        let shops = ShopAPI.getUserShops(api, user);
                        expect.nat(Array.size(shops)).equal(1);
                        expect.principal(shops[0].canisterId).equal(shopA);
                        expect.text(shops[0].name).equal("Owned Shop");
                    },
                );

                await test(
                    "skips managed shop ids that are not in registry",
                    func() : async () {
                        let registry = Map.new<Principal, ShopAPI.ShopRegistryItem>();
                        let _ = Map.put(
                            registry,
                            Map.phash,
                            shopA,
                            Fixtures.shopRegistryItem(shopA, "Shop A", "First shop", null, null, false),
                        );
                        let missingShop = Principal.fromText("aaaaa-aa");
                        let api = ShopAPI.API(Fixtures.makeDependencies(?registry));
                        let _ = Map.put(api.managedShopsByUser, Map.phash, user, [shopA, missingShop]);

                        let shops = ShopAPI.getUserShops(api, user);
                        expect.nat(Array.size(shops)).equal(1);
                        expect.principal(shops[0].canisterId).equal(shopA);
                        expect.text(shops[0].name).equal("Shop A");
                    },
                );
            },
        );
    },
);
