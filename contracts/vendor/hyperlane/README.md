# Vendored Hyperlane core (message-id multisig ISM path + HypERC20 token path)

Authentic source files from **`@hyperlane-xyz/core@11.3.1`** (npm), copied
verbatim except for documented OZ-compatibility patches. Used by:
- `contracts/privacy/CommitteeMessageIdMultisigIsm.sol` — the committee-backed
  custom ISM securing the XOM↔COTI Hyperlane Warp Route (ISM path below).
- the **`HypERC20` synthetic** (wXOM) deployed on COTI mainnet via
  `scripts/deploy-warp-synthetic-coti.cjs` (token path below).

**Why the synthetic is vendored + Hardhat-deployed (not `hyperlane warp deploy`):**
the stock Hyperlane CLI ships only `cancun`-compiled token bytecode (emits
`PUSH0`), and COTI mainnet is a `paris` EVM with no `PUSH0` opcode (verified live
2026-05-31 via state-override `eth_call`). Compiling the vendored `HypERC20` with
our default `evmVersion: paris` yields COTI-runnable bytecode — exactly how
Hyperlane deployed COTI's own core (Cotiscan shows the live Mailbox at
`EVMVersion: paris`). The 88008 collateral side deployed fine via the stock CLI
(88008 supports PUSH0); only the COTI synthetic needed the paris build.

Decision: `memory/decision_privacy_bridge_hyperlane_2026-05-30.md`.

## Why vendored (not an npm dependency)

`@hyperlane-xyz/core@11.3.1` unpacks to ~414 MB (full TS SDK + Tron typechain +
artifacts) and pulls peer deps unrelated to our Solidity build. We only need the
9 Solidity files on the message-id multisig verification path, so we vendor just
those — same convention as `contracts/coti-helium` and the OZ patches. The repo
is a per-app monorepo on V1; adding the full package to `Coin/package.json` would
bloat installs for nine source files.

## Files (9) — exactly the message-id multisig path

```
interfaces/IInterchainSecurityModule.sol      ISM interface + ISpecifies… + Types enum
interfaces/isms/IMultisigIsm.sol              adds validatorsAndThreshold()
PackageVersioned.sol                          PACKAGE_VERSION = "11.3.1"
libs/TypeCasts.sol                            address<->bytes32
libs/Message.sol                              Hyperlane message field accessors
libs/CheckpointLib.sol                        checkpoint digest + domainHash  ⚠ PATCHED
isms/libs/MessageIdMultisigIsmMetadata.sol    metadata layout (root/index/sigs)
isms/multisig/AbstractMultisigIsm.sol         AbstractMultisig + verify() two-pointer
isms/multisig/AbstractMessageIdMultisigIsm.sol  message-id digest() override
```

`libs/Merkle.sol` is intentionally NOT vendored — it is only used by the
merkle-root multisig variant (`AbstractMerkleRootMultisigIsm`), which we do not
use. The message-id path never imports it.

## The one patch — `libs/CheckpointLib.sol`

OpenZeppelin 5.x moved `toEthSignedMessageHash(bytes32)` out of `ECDSA` into
`MessageHashUtils`. The repo pins OZ `~5.3.0`. So:

- import `ECDSA` → import `MessageHashUtils`
- `ECDSA.toEthSignedMessageHash(...)` → `MessageHashUtils.toEthSignedMessageHash(...)`

Byte-identical output (the `"\x19Ethereum Signed Message:\n32"` envelope). No
other file is modified; `AbstractMultisigIsm.sol` still imports `ECDSA` for
`recover`, which remains in OZ 5.3.0.

## Token path (13 files) — the HypERC20 synthetic dependency closure

Computed as the exact relative-import closure of `token/HypERC20.sol` (the
synthetic) — `@openzeppelin/*` imports resolve from `node_modules` at compile:

```
token/HypERC20.sol                      synthetic ERC20 router (mint/burn)
token/libs/TokenRouter.sol              transfer/quote logic                ⚠ PATCHED
token/libs/TokenMessage.sol             token message encoding
token/libs/Quotes.sol                   quote helpers
client/GasRouter.sol                    per-domain gas config
client/Router.sol                       enrollRemoteRouter / routers
client/MailboxClient.sol                mailbox + ISM + hook wiring          ⚠ PATCHED
libs/EnumerableMapExtended.sol          uint32->bytes32 enumerable map
hooks/libs/StandardHookMetadata.sol     post-dispatch hook metadata
interfaces/IMailbox.sol, ITokenBridge.sol, IMessageRecipient.sol,
interfaces/hooks/IPostDispatchHook.sol  router/mailbox interfaces
```

(`libs/Message.sol`, `libs/TypeCasts.sol`, `interfaces/IInterchainSecurityModule.sol`,
`PackageVersioned.sol` are shared with the ISM path and were already vendored.)

`HypERC20Collateral` is NOT vendored — the 88008 collateral side deployed via the
stock CLI (88008 supports PUSH0).

### Token-path OZ-5.x patches (all in OZ-5.3.0 API drift; documented inline)

- `client/MailboxClient.sol` — `Address.isContract(a)` → `a.code.length > 0`
  (OZ v5 removed `Address.isContract`); the now-unused `Address` import removed.
- `client/MailboxClient.sol` — `__Ownable_init()` → `__Ownable_init(_owner)`
  (OZ v5 `OwnableUpgradeable` requires the initial-owner argument).
- `token/libs/TokenRouter.sol` — `Math.Rounding.Down` → `Math.Rounding.Floor`
  (×2; OZ v5 renamed the enum members). Identical rounding semantics.

No logic changes — only OZ-5.x API renames. Compiles `evm target: paris`.

## Upgrading

To bump the vendored version: `npm pack @hyperlane-xyz/core@<version>`, extract
the same ISM (9) + token (13) paths, re-apply the documented OZ patches, then
`npx hardhat compile` + run `test/CommitteeMessageIdMultisigIsm.test.ts`. Diff the
digest/verify logic against the prior version — a change there alters checkpoint
compatibility with the relayer/validator agents.
