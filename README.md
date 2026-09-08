# OmniBazaar + OmniCoin Smart Contracts

Smart contracts for the OmniBazaar decentralized marketplace platform and the OmniCoin
blockchain that powers it.

- **Platform (OmniBazaar):** marketplace escrow and dispute resolution, registration and
  KYC attestation, DEX/CLOB settlement and swap routing, prediction markets, yield/RWA
  vaults, NFT marketplace, fee routing, ENS integration.
- **Chain (OmniCoin):** XOM token (ERC20Votes, 18 decimals, 16.8B supply), staking core,
  validator rewards, protocol governance and timelock, cross-chain bridges, and
  privacy-shielded assets (pXOM on COTI V2).
- **Public chain:** OmniCoin L1, an Avalanche Subnet-EVM with ~1–2s finality — chain ID
  **88008** (config key `omnibazaar`, display name `OmniCoin`). Also deployed on COTI V2
  and Ethereum-family chains for bridging and liquidity.

## Deployed addresses

The canonical, machine-synced deployment manifest is **`deployments/mainnet.json`**
(OmniCoin L1, chain 88008). Additional live-chain manifests sit alongside it
(`coti-mainnet.json`, `ethereum-mainnet.json`, `ethereum.json`). Addresses in the
manifest are the source of truth used by the application clients.

Recommended verification flow:

1. Find the address in `deployments/mainnet.json`.
2. Compare the deployed bytecode against a local build of this repository
   (`npm run compile`, then `scripts/verify-deployment.js` reads the manifest and checks
   the chain).
3. Cross-check with the explorer for the chain when the deployed source is published
   there.

> Status note: source is published here so anyone can reproduce the bytecode. Where a
> chain's explorer supports source verification (Ethereum-family), contracts are being
> verified there. Independent audit reports will be published here when available; see
> `SECURITY.md` for the disclosure policy.

## Repository layout

| Path | Contents |
|---|---|
| `contracts/` | All Solidity sources, grouped by domain (marketplace, dex, privacy, bridge, governance, liquidity, nft, attestation, ...) |
| `contracts/coti-helium/`, `coti-contracts/` | Vendored COTI MPC primitives required by the privacy contracts and `MinimalEscrow` (MIT; kept to the exact import closure) |
| `test/` | Hardhat/Mocha/Chai tests (unit, integration, adversarial) |
| `deployments/` | Deployment manifests (`mainnet.json` is the source of truth) |
| `scripts/` | `deploy.js` (deploy runner), `verify-deployment.js` (bytecode verification against a live chain), test-support libraries |
| `hardhat.config.js` | Compiler settings, networks, Etherscan/Sourcify verification config |

## Building

Requirements: Node.js >= 22.18, npm >= 10.

```bash
npm install
npm run compile
```

The contracts compile with the settings pinned in `hardhat.config.js` (per-contract
Solidity versions, optimizer runs, `viaIR`, EVM `paris`). Recompile the exact bytecode
with `npm run compile`; `scripts/verify-deployment.js` can then compare it to a live
chain.

## Testing

```bash
npm test                 # full suite (long)
npm run test:security    # security-focused suites
npm run test:integration # integration suites
```

The full suite is large; run a single file with
`npx hardhat test test/<area>/<file>.test.js` when iterating.

## Deploying / verifying

Deployments are state-changing, mainnet operations — see `SECURITY.md` and the
per-chain network configuration in `hardhat.config.js` before running anything.

```bash
npx hardhat run scripts/deploy.js --network <network>   # localhost / mainnet / ...
npx hardhat verify --network <network> <address>        # Etherscan-family verification
npm run verify:deployment                               # bytecode check vs deployments/mainnet.json
```

## Trustless design

Validators handle off-chain computation (order matching, listing storage, search,
indexing) but cannot steal user funds, fabricate transactions, or censor settlement.
All financial state and settlement logic lives on-chain with cryptographic enforcement:
EIP-712 typed signatures, ECDSA recovery, Merkle proofs for bonus eligibility, voting
snapshots, 2-of-3 escrow, and permissionless dispute arbitration. The `Validator`
backend and the application interfaces are separate, closed-source repositories.

## Security

- **License:** Business Source License 1.1 — see `LICENSE`. After the change date
  (2027-08-17) the code converts to MIT.
- **Bug reports / disclosures:** see `SECURITY.md`. No independent audit report has been
  published yet; internal assurance reports are not published.
- **Contributing:** see `CONTRIBUTING.md`.

## Chain registration

OmniCoin (chain ID 88008) is registered in the public `ethereum-lists/chains` registry
(entry `eip155-88008.json`) and resolves on chainid.network, so wallets can add the
network by chain ID. Public RPC: `https://rpc.omnicoin.net`.
