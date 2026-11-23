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
icp build
mops test
```

The wasms land in `.icp/cache/artifacts/<name>`.

## Verify a deployed canister

Releases are built from this tree with `icp build` on Linux. To check that a canister runs this code, compare its module hash with a build of the commit it was released from:

```bash
icp canister status <canister-id> -e ic --public
```

Every commit's **Build** workflow run lists the hash of each wasm under **Module hashes**, both in the run summary and in the step's log. That's the easiest build to compare against. A deployed canister can be a commit or two behind the latest one, so look back through recent runs.

To build it yourself, check out that commit and run the build above, then:

```bash
shasum -a 256 .icp/cache/artifacts/shop
```

Build on Linux (x86-64), for example in Docker. The Motoko compiler's macOS and Linux binaries embed different build IDs in the wasm's `moc:version` metadata, so a macOS build never matches, even from the same source and compiler version.

## Contributing

Issues are welcome. Pull requests can't be merged here directly, because this repository is overwritten on every sync. A change we accept is applied upstream and then appears here.

## License

Copyright 2026 the Breeze Marketplace authors. Licensed under the [Apache License, Version 2.0](LICENSE).
