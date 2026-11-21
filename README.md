# Breeze canisters

The source of three Breeze marketplace canisters on the Internet Computer:

- **core** (`src/backend/canisters/core`, built as `backend`): the user and shop registries, paid shop creation, the cross-shop order index, and the upgrades of shops and vaults.
- **shop** (`src/backend/canisters/shop`): one per merchant. Products, inventory, orders, ICP, ckUSDC and card payments, the shop's wallet, digital delivery, storefront, roles.
- **vault** (`src/backend/canisters/vault`): one per merchant. Certified asset storage and ticket-gated digital delivery.

This repository is a one-way mirror of these canisters and the shared code they import. Other platform canisters (product index, trust & safety, canister factory, cycles dispenser) and the web app aren't published. Core reaches them only through actor interfaces it declares itself.

## Build

You need Node 22, [icp-cli](https://cli.internetcomputer.org) 1.7+ and mops 3.4.2. `mops.toml` pins the Motoko compiler, and `mops.lock` pins the dependencies.

```bash
npm install -g @icp-sdk/icp-cli @icp-sdk/ic-wasm ic-mops@3.4.2
mops install
icp build backend shop vault
mops test
```

The wasms land in `.icp/cache/artifacts/<name>`.

## Verify a deployed canister

Releases are built from this tree with `icp build`, as above. To check that a canister runs this code, compare its module hash with your build:

```bash
icp canister status <canister-id> -e ic --public
```

```bash
shasum -a 256 .icp/cache/artifacts/shop
```

The mirror's commit message names the commit of the private repo it was exported from.

## Contributing

Issues are welcome. Pull requests can't be merged here directly, because this repository is overwritten on every sync. A change we accept is applied upstream and then appears here.

## License

Copyright 2026 the Breeze Marketplace authors. Licensed under the [Apache License, Version 2.0](LICENSE).
