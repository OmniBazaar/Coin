# Security Audit Report: EscrowV2

**Date:** 2026-10-19
**Audited by:** 8-pass audit agent (4 semantic agents → 5-profile red team → adversarial re-audit → verification pass)
**Contract:** `Coin/contracts/EscrowV2.sol` (2,812 lines, Solidity 0.8.24, paris, via-IR, optimizer 200)
**Upgradeable:** No — standalone contract, constructor-configured immutables.
**Handles funds:** Yes — user escrow principal in any vault-allowlisted ERC-20, plus dispute stakes.
**Baseline:** `MinimalEscrow.sol` (live v1) — EscrowV2 is a token-per-escrow fork; the audit focused on the delta and on every path the delta touches.

---

## Executive summary

One High-severity unit-of-account defect was found independently by two auditors in the first round (dispute stake and arbitration fee computed from the escrowed token's raw units but charged in XOM), plus a Medium fee-on-transfer insolvency, a Medium/unpinned fee configuration, and a creation-ABI break. **All were remediated.** The re-audit then found a **Critical regression introduced by the remediation itself** — non-XOM disputes could be opened but never resolved, handing the buyer a guaranteed full refund — which was also fixed and is now covered by an end-to-end test. Final verification pass: **GO for deploy**, with two operational conditions (seed an arbitrator; keep the panel wiring rules).

| Severity | Found | Fixed | Open |
|---|---|---|---|
| Critical | 1 | 1 | 0 |
| High | 3 | 3 | 0 |
| Medium | 6 | 4 | 2 (liveness-only, documented) |
| Low | 10 | 7 | 3 (documentation / UX) |
| Info | 9 | — | — |

No path was found that allows an attacker to steal principal or stakes, double-pay, or make `totalEscrowed` under-report so that admin rescue could sweep user funds.

## Static analysis

| Tool | Result |
|---|---|
| Solhint | 0 errors, 24 warnings (complexity, not-rely-on-time, gas-indexed-events — all pre-existing in V1 and expected for an escrow) |
| Slither 0.11.5 | **Did not complete.** It compiles the full COTI MPC import tree (`coti-contracts/.../MpcCore.sol`); the run exceeded 45 minutes and was killed. This matches the audit runbook's noted COTI compile hazard. The semantic passes read the MpcCore surface manually; the private path is unchanged from the audited V1. |
| Aderyn 0.1.9 | **Failed to run** — `StripPrefixError(())` on hoisted `node_modules` (known, supplementary only). |
| Mythril | Not run — Slither's compile stall already consumed the symbolic-execution budget; every finding here was reachable by inspection, and no arithmetic/oracle surface is new. |

## Findings

### [C-01] Non-XOM disputed escrows were unresolvable once the arbitration panel was wired (regression introduced by remediation)
**Severity:** Critical · **Category:** Business logic / liveness · **Location:** `vote()`, `commitDispute`, `revealDispute`, `markDisputed`
The remediation made `commitDispute`/`revealDispute` defer to the external panel only for XOM escrows, so a USDC escrow could enter `disputed = true` — but `vote()` still reverted unconditionally whenever a panel was configured. `markDisputed` then refused the non-XOM escrow, so `OmniArbitration.createDispute` failed closed and `resolveDispute` was unreachable. The only surviving exit was `claimDisputeTimeout` (buyer-only, `expiry + 30 days`), i.e. a guaranteed 100% refund to a buyer who kept the goods, and the seller's stake stranded.
**Fix:** `vote()` now keys on the internal-dispute marker — `arbitrationContract != address(0) && escrow.arbitrator == address(0)` — because `revealDispute` always assigns an arbitrator and the panel's `markDisputed` never does. Verified end-to-end by a test that creates a USDC escrow, opens and reveals an internal dispute **with the panel wired**, votes buyer+seller, and pays the seller 99 USDC from claimable.

### [H-01] Dispute stake and 5% arbitration fee were computed in token units but charged in XOM
**Severity:** High · **Category:** Unit/denominator confusion · **Location:** `commitDispute`, `postCounterpartyStake`, `_collectArbitrationFee`, `_returnDisputeStake`, `reclaimExpiredStake`
For 50,000 USDC the required stake was 1.25e9 **wei XOM** (a billionth of a XOM) instead of 2.5% of the principal, making disputes free and arbitrators unpaid; for a cheap high-decimal token the same formula demanded thousands of XOM against a dust escrow, blocking the seller's only protection.
**Fix:** new `_stakeToken(escrowId)` — the escrow's own token for public escrows, XOM for private pXOM escrows (pXOM is 1:1 and 18-decimal, so v1's arithmetic was already correct there). Every stake and fee movement uses it; all stake accounting is per-token.

### [H-02] `getAmount()` silently changed unit; the arbitration panel priced its XOM deposit from it
**Severity:** High · **Category:** Cross-contract interface · **Location:** `getAmount`, `markDisputed`; consumer `OmniArbitration.createDispute`
The panel pulled a 5% XOM dispute deposit computed from the escrow's token amount, so a USDC dispute cost dust and a cheap-token dispute could be unaffordable.
**Fix:** `markDisputed` refuses any non-XOM escrow (`UseInternalArbitration`), so a panel dispute on such an escrow reverts atomically before any fee is taken; commit/reveal/vote/counter-stake all use the same token predicate. NatSpec corrected in `EscrowV2`; the panel keeps its XOM assumption, which is now true for every escrow it can see.

### [H-03] `createEscrow` / `createEscrowWithReferrers` selectors changed, breaking every client
**Severity:** High (availability, no fund loss) · **Category:** Integration
**Fix:** legacy XOM-defaulting overloads restored alongside the token-taking versions, routing through the same `_createEscrow` (identical allowlist, seller-self, duration and transfer-delta checks). No selector collision; clients that encode the v1 selector keep working, and new clients must disambiguate by full signature.

### [M-01] Fee-on-transfer / negative-rebasing tokens made escrows insolvent and unrecoverable
**Severity:** Medium · **Category:** Token accounting
**Fix:** `_pullExact` measures the balance delta on **every** inbound transfer (principal, private deposit, both stakes) and reverts `TokenTransferMismatch` on any shortfall. This also closes the post-creation case where a token starts charging a fee after an escrow exists.

### [M-02] A reverting fee transfer could block a release
**Severity:** Medium · **Category:** DoS / liveness
**Fix:** the fallback fee transfer is a checked low-level call; on refusal the seller is paid their **net** amount (never the gross — that would hand the seller the protocol's 1%) and `MarketplaceFeeWaived` records it. The fee counts as collected only when it actually moved. The arbitration-fee vault share uses the same best-effort `_payOrHold` with `FeeTransferDeferred`.

### [M-03] `MARKETPLACE_FEE_BPS` was not pinned to 100
**Severity:** Medium · **Category:** Economic configuration
Any other value silently disabled the canonical 70/20/10 split, and 0 disabled the fee entirely.
**Fix:** constructor rejects any value other than `DEFAULT_MARKETPLACE_FEE_BPS` and requires the fee vault to have code.

### [M-04] Venue race: a panel dispute could be opened on top of an internal dispute — OPEN (liveness only)
**Severity:** Medium · **Location:** `markDisputed`
If an internal XOM dispute is opened while no panel is configured and the admin later wires the panel, `OmniArbitration.createDispute` can add a second venue. Whichever resolves first wins; the loser reverts atomically, leaving a panel dispute active and its fee unrecoverable.
**Partial fix:** `markDisputed` now refuses an escrow that already has an internal arbitrator. Residual risk is limited to wiring the panel while an internal XOM dispute is live — an operational rule recorded in the deploy runbook (do not call `setArbitrationContract` with open internal disputes).

### [M-05] Seller stake recovery depends on the buyer — OPEN (documented)
**Severity:** Medium · **Location:** `claimDisputeTimeout`
A revealed-then-abandoned dispute resolves only via vote, panel, or the buyer-only timeout. Recovering a seller's stake therefore needs the buyer to act. Pre-existing in V1; fixing it would need a seller-side timeout that does not let a seller self-deal — a design change, not a patch.

### [L] Low / informational (fixed)
`claimDisputeTimeout` on a private escrow refunded zero and stranded pXOM (now reads/zeroes the private amount); `seller == address(this)` accepted (rejected in both create paths); pXOM allowed in the public path (rejected); `markDelivered` on a private escrow removed the buyer's only exit (rejected); allowlist staticcall could brick creation (try/catch + `AllowlistUnavailable`); EIP-712 domain identical to V1 (now `OmniBazaar EscrowV2` / `3`); privacy chain-id list wrong/incomplete (now COTI mainnet 2632500, testnet 7082400, devnet 13068200); dust escrows below the fee floor (rejected below 100 raw units); `revealDispute` could act on a settled escrow (guarded).

### [L] Low / informational (open)
Stale NatSpec in `OmniArbitration.IArbitrationEscrow.getAmount` (still says "Amount in XOM"); the waived-fee surplus is recoverable by the admin sweeper but not documented in the vault docs; `claimDisputeTimeout` and `refundBuyer` remain callable while paused (deliberate, but the asymmetry with `vote` should be documented); the three client surfaces still call `markDelivered` without a private-escrow guard (the contract reverts, so this is copy, not safety).

## Verified invariants

- **No double payout.** `resolved`/`amount`/`privateEscrowAmounts` are zeroed before every transfer; stakes are zeroed before being credited. Reviewed on all 13 resolution paths.
- **Per-token accounting.** Every mutation of `totalEscrowed` / `totalClaimable` / `claimable` was traced; principal and stake share a bucket but each debit matches its credit, so `recoverERC20` can never reach user funds and no exit can pay a stake as principal.
- **Stake cannot exceed principal.** Stake = floor(P/40), half-fee = floor(floor(P/20)/2) = floor(P/40); the cap makes over-collection impossible.
- **Reentrancy.** Every value-moving entry point is `nonReentrant`; state precedes transfers; the fee-waiver low-level call runs inside guarded frames.
- **Panel containment.** A panel-sourced escrow always has `arbitrator == 0` and cannot be internally voted; an internally disputed escrow always has a non-zero arbitrator and cannot be panel-marked.
- **Replay.** EIP-712 domain binds `verifyingContract` and a distinct name/version; `resolved` is the single-use flag.

## Deploy conditions

1. **Seed an arbitrator in the deploy transaction sequence.** `selectArbitrator` reverts on an empty list, so `revealDispute` (internal path) is dead until `addArbitrator` is called.
2. **Do not wire `setArbitrationContract` while any internal XOM dispute is open** (see M-04).
3. **Fresh deployment only.** `Escrow` gained a field; never use this as an in-place implementation swap for a live `MinimalEscrow`. Re-point the escrow address in `omnicoin-integration.ts`, run `scripts/sync-contract-addresses.js mainnet`, then migrate the validator and three clients (new create signature, `getEscrow` tuple, `getToken`).
4. **Allowlist check:** XOM must be seeded in `UnifiedFeeVault.supportedPaymentTokens` (it is, verified on-chain) and the vault must expose `supportedPaymentTokens` — otherwise every create fails closed with `TokenAllowlistUnavailable` / `TokenNotSupported`.

## Test evidence

`npx hardhat test test/EscrowV2.test.ts` → **15 passing**, including: token recorded; unlisted token refused; zero/codeless token refused; release takes the fee in the escrow token; refund in token; stake denominated in the escrow token; XOM path unchanged; first-sale bonus XOM-only; legacy XOM overload; fee-on-transfer refused; non-XOM dispute resolved through the internal vote **with the panel wired**; reveal-after-settlement refused; expired stake reclaimed; dust escrow refused; private entry point unavailable off-COTI.

## Refuted / non-findings

- "Panic/precision loss in the 1% computation": refuted — `floor(amount*100/10000) == floor(amount/100)` exactly for every uint256, and the vault uses the same expression, so the approved amount always equals the pulled amount.
- "Stake can be replayed as principal": refuted — every stake return zeroes the mapping first and credits `claimable`, never the principal bucket's available balance.
- "Fee-on-transfer token can still pass creation": refuted — the delta check is on the actual received amount.

---

# Re-audit addendum — 2026-10-20: library extraction (EIP-170)

**Why:** the revision's `EscrowV2` compiled to 27,290 bytes deployed against the
24,576-byte limit, so it could not be deployed. The code was split across two
external libraries and re-audited as a delta.

## What moved

| New location | Moved from `EscrowV2` |
|---|---|
| `contracts/libraries/EscrowFeeRouter.sol` | `_collectMarketplaceFee`, `_recordFirstSale`, `_collectArbitrationFee`, `_payOrHold`, `_returnDisputeStake`, `_requireSupportedToken`, `_validateAttributionNodes`, `validateReferrerPair` |
| `contracts/libraries/EscrowPrivacyOps.sol` | `createPrivateEscrow`, `releasePrivateFunds`, `refundPrivateBuyer` (bodies) |
| `contracts/interfaces/EscrowV2Types.sol` | the `Escrow` struct (shared type; layout unchanged) |

Both libraries are state-free and reachable only by DELEGATECALL from the
escrow, so every mapping reference resolves to the escrow's slots and every log
is emitted at the escrow's address with unchanged topics. `hardhat.config.js`
adds per-file overrides (`runs: 1`, `bytecodeHash: none`) for the three files.

Result: **23,867 bytes deployed**, 25,954 init code.

## Verification performed

- No library declares state, immutables, `receive`/`fallback`, or a constructor.
- No `msg.sender` / `tx.origin` / `_msgSender` in either library: the caller is
  resolved once in the escrow and passed in (ERC-2771 preserved).
- `address(this)` inside the libraries is the escrow, which is what the balance
  delta and the `seller == address(this)` guard require.
- No library calls another library's external function (that would switch
  storage context); `MpcCore.decrypt`/`offBoard` are `internal` and inline.
- All 11 call sites checked for positional/type agreement, including the 14- and
  13-argument cases; `claimable[token][user]` and `disputeStakes[escrowId][party]`
  orientations unchanged.
- Immutable values are read at every call site from the escrow's own state; no
  second source of truth exists for fee vault, pXOM, fee bps, durations or the
  arbitrator delay.
- Every event and error the libraries emit/raise is still declared in the
  escrow, so the ABI and client decoding are unchanged. No function was removed.

## Findings and remediation

| ID | Sev | Finding | Disposition |
|---|---|---|---|
| D-01 | Medium | Three creation-time validators were moved to library calls that **returned nothing**. A DELEGATECALL to a codeless address succeeds with empty returndata, so a mislinked library would let `createEscrow` accept an unallowlisted token, accept pXOM in a public escrow, and skip the attribution checks. | **FIXED.** Each validator now returns `bool` and the escrow requires it, so empty returndata reverts on decode. Deploy scripts additionally assert library code exists, that the escrow's bytecode embeds both addresses, and that a library-mediated read (`getEscrow(0)`) does not revert. |
| D-02 | Low | `deploy-escrowv2.cjs` wrote the manifest only at the end, after a `DEPOSITOR_ROLE` grant the deployer cannot make — so a failed grant left the escrow and both libraries unrecorded. | **FIXED.** Addresses are written immediately after deployment (and the libraries recorded), and the grant is tried/caught with the correct explanation. |
| D-03 | Low | Nothing asserted the EIP-170 size, and the local network allows unlimited contract size. | **FIXED.** Both deploy scripts assert `size <= 24576`; the runbook records 23,867 / 25,954 as the expected figures. |
| D-04 | Low | `EscrowPrivacyOps` had no compiler override, so the standalone artifact could be built at `runs: 200` while the escrow linked a `runs: 1` build. | **FIXED.** Override added; the two builds now match. |
| D-05 | Low | The moved private (pXOM) path has no test coverage: on any non-COTI chain `createPrivateEscrow` reverts before reaching the library, and `MpcCore`'s precompile does not exist in Hardhat. | **OPEN — accepted, recorded.** Identical to the pre-existing gap on `MinimalEscrow` (`test/MinimalEscrowPrivacy.test.js` documents the same limitation). The path is unreachable on the deployment target (OmniCoin L1); on COTI it must be verified on-chain. |
| D-06 | Low | `runs: 1` + `bytecodeHash: none` change no runtime behaviour, but bytecode-level source matching is gone and per-call gas rises. | **Documented** in the runbook: verify with the library addresses supplied, and re-estimate client `gasLimit` values before rollout. |
| D-07 | Info | `_payOrHold` / `payOrHold` became dead code after the arbitration-fee split moved. | **FIXED.** Both deleted. |
| D-08 | Info | `Escrow` struct slot comments were off by one. | **FIXED.** |
| D-09 | Info | A duplicate `IFeeVaultTokenAllowlist` declaration remained in the escrow. | **FIXED.** Removed. |
| D-10 | Info | The private ops rely on `address(this)`/`block.timestamp` meaning the escrow, which holds only because external library calls are DELEGATECALL. | **Accepted**, covered by the library-level NatSpec that forbids inlining or direct calls. |

No Critical or High finding was raised by the delta audit. The extraction moves
bodies only; no signature, event topic, error selector or storage slot changed.

## Test evidence (post-remediation)

`npx hardhat test test/EscrowV2.test.ts` → **18 passing**.
Combined run with `OmniArbitration.test.js` + `OmniArbitration.guards.test.js` +
`MinimalEscrowV2.fees.test.ts` → **107 passing, 0 failing**.
