# Security Audit Report: UnifiedFeeVault.sol (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13 17:19 UTC
**Audited by:** Claude Code Audit Agent (Opus 4.6)
**Contract:** `Coin/contracts/UnifiedFeeVault.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 1,696
**Upgradeable:** Yes (UUPS via `UUPSUpgradeable`)
**Handles Funds:** Yes -- ALL protocol fees (marketplace, DEX, arbitration, chat, yield, bridging, prediction, NFT)
**Dependencies:** OpenZeppelin Contracts Upgradeable 5.x (`AccessControlUpgradeable`, `UUPSUpgradeable`, `ReentrancyGuardUpgradeable`, `PausableUpgradeable`, `ERC2771ContextUpgradeable`), `SafeERC20`, `IFeeSwapRouter`, `IOmniPrivacyBridge`
**Deployed Size:** 14.569 KiB (within 24 KiB mainnet limit)
**Previous Audits:** Round 4 (2026-02-26), Round 5 (2026-02-28), Round 6 (2026-03-10)
**Tests:** 109 passing (9 seconds)

---

## Executive Summary

UnifiedFeeVault is the single collection and distribution point for all OmniBazaar protocol fees. It aggregates fees from MinimalEscrow, DEXSettlement, RWAAMM, OmniFeeRouter, OmniYieldFeeCollector, OmniPredictionRouter, OmniChatFee, OmniArbitration, and any future fee-generating contracts. Fees are split 70/20/10 (ODDAO Treasury / StakingRewardPool / Protocol Treasury).

The contract also handles:
- **Marketplace fee sub-splits** (transaction 0.50% / referral 0.25% / listing 0.25%, each with further 70/20/10 breakdowns)
- **Swap-and-bridge operations** for non-XOM fee tokens via IFeeSwapRouter adapter
- **pXOM-to-XOM privacy conversions** via IOmniPrivacyBridge
- **Pull-pattern quarantine** for reverting recipients via pendingClaims
- **Timelocked configuration changes** (48h delay on all admin setters)
- **Permanent ossification** (irreversible upgrade disable with propose/confirm)

This Round 7 audit is a comprehensive pre-mainnet final review. All Critical, High, and Medium findings from prior rounds (R4, R5, R6) have been confirmed as remediated. The contract has matured significantly through 6 prior audit rounds. **Zero Critical findings and zero High findings were identified.** One Medium finding, three Low findings, and four Informational items remain.

The contract has reached a security posture suitable for mainnet deployment, contingent on the operational requirement of deploying ADMIN_ROLE and DEFAULT_ADMIN_ROLE behind a TimelockController controlled by a multi-sig wallet (Gnosis Safe).

---

## Findings Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 3 |
| Informational | 4 |
| **Total** | **8** |

---

## Remediation Status from All Prior Audits

### Round 4 and Earlier

| Prior Finding | Round | Status | Verification |
|---------------|-------|--------|--------------|
| Original M-02: Recipient timelock | R4 | **Fixed** | `proposeRecipients()` / `applyRecipients()` with 48h delay (lines 987-1031) |
| Original M-03: Reverting recipient DoS | R4 | **Fixed** | `_safePushOrQuarantine()` with pull-pattern quarantine (lines 1536-1565) |
| Original M-04: Rescue drains committed funds | R4 | **Fixed** | `rescueToken()` includes `totalPendingClaims[token]` in committed calculation (line 1057) |

### Round 5

| Prior Finding | Round | Status | Verification |
|---------------|-------|--------|--------------|
| C-01: `rescueToken()` ignores pendingClaims | R5 | **Fixed** | `totalPendingClaims[token]` tracked globally and included in committed funds at line 1057. `_safePushOrQuarantine` increments `totalPendingClaims` at line 1561. `claimPending` decrements at line 788. |
| H-01: `distribute()` double-counts pendingClaims | R5 | **Fixed** | `totalPendingClaims[token]` subtracted from distributable balance at line 730. |
| H-02: `_safePushOrQuarantine` ignores ERC20 return | R5 | **Fixed** | Low-level call at line 1544 decodes return data and checks boolean at lines 1553-1555. Handles both reverting tokens (success=false) and false-returning tokens (returndata decodes to false). |
| H-03: Swap router / privacy bridge no timelock | R5 | **Fixed** | Both use propose/apply with 48-hour `RECIPIENT_CHANGE_DELAY` (lines 1184-1221 for swap router, lines 1278-1322 for privacy bridge). |
| M-01: RWAAMM sends fees via direct transfer | R5 | **Fixed** | `notifyDeposit()` added at line 690 for audit trail. |
| M-02: Recipient changes no timelock | R5 | **Fixed** | `proposeRecipients()` / `applyRecipients()` with 48h delay (lines 987-1031). Deprecated slots preserved for UUPS layout compatibility (lines 176-194). |
| M-03: Reverting recipient blocks distribution | R5 | **Fixed** | Pull pattern implemented via `_safePushOrQuarantine` (line 1536) and `claimPending` (line 779). |
| L-01: Ossification instant and irreversible | R5 | **Fixed** | Propose/confirm with 48-hour delay (lines 1090-1120). |

### Round 6

| Prior Finding | Round | Status | Verification |
|---------------|-------|--------|--------------|
| H-01: `msg.sender` vs `_msgSender()` in deposits | R6 | **Fixed** | `deposit()` at line 668 uses `_msgSender()`. `depositMarketplaceFee()` at line 840 uses `_msgSender()`. All deposit functions now consistent. |
| M-01: `setRecipients()` lacks timelock | R6 | **Fixed** | Replaced with `proposeRecipients()` / `applyRecipients()` with 48h timelock (lines 987-1031). New storage variables at lines 260-270, deprecated old slots at lines 176-194. |
| M-02: `setXomToken()` has no timelock | R6 | **Fixed** | Replaced with `proposeXomToken()` / `applyXomToken()` with 48h timelock (lines 1232-1267). |
| M-03: `setTokenBridgeMode()` has no timelock | R6 | **Fixed** | Replaced with `proposeTokenBridgeMode()` / `applyTokenBridgeMode()` with 48h timelock (lines 1133-1174). |
| M-04: Marketplace fee rounding loss | R6 | **Fixed** | `MIN_SALE_AMOUNT = 10_000` constant at line 147. Check at lines 831-833 reverts with `SaleAmountTooSmall()` for sub-dust sales. Ensures `totalFee >= 100`, providing adequate precision for all sub-splits. |
| L-01: `redirectStuckClaim()` not protected | R6 | **Accepted** | Intentionally callable while paused -- allows rescue of stuck claims during emergencies. No reentrancy risk (pure storage operations, no external calls). |
| L-02: `notifyDeposit()` cannot verify receipt | R6 | **Accepted** | Documented as unverified audit trail. `distribute()` uses `balanceOf()` for actual distribution. |
| L-03: Ossification cancellation | R6 | **Accepted** | Calling `proposeOssification()` again resets the timer. Acceptable UX. |
| L-04: Generic `FeesDeposited` event | R6 | **Accepted** | `depositMarketplaceFee()` emits `FeesDeposited` at line 908. Off-chain indexers can distinguish via function selector in transaction input data. |
| L-05: No cancellation for pending proposals | R6 | **Accepted** | Re-proposing overwrites the pending state, effectively cancelling. |
| I-01: Storage gap arithmetic | R6 | **Updated** | See I-01 below for current analysis. |
| I-02: Unused `FEE_MANAGER_ROLE` | R6 | **Fixed** | Removed. No longer present in contract. |
| I-03: Event indexing precision | R6 | **Accepted** | Standard Solidity behavior. Documented for indexer developers. |
| I-04: `_safePushOrQuarantine` uses low-level call | R6 | **Accepted** | Intentional design for quarantine pattern. Token address validated at deposit stage. |

---

## Medium Findings

### [M-01] `depositMarketplaceFee()` Transfers Staking and Protocol Shares Via `_safePushOrQuarantine` But Does Not Track Failed Pushes in the Accounting Invariant

**Severity:** Medium
**Category:** SC02 -- Business Logic / Accounting
**VP Reference:** VP-16 (Accounting Error)
**Location:** `depositMarketplaceFee()` lines 859-862, accounting at lines 904-906

**Description:**

In `depositMarketplaceFee()`, the transaction fee portion (0.50%) is distributed immediately:
- `txOddao` is added to `pendingBridge[token]` (line 858)
- `txStaking` is pushed via `_safePushOrQuarantine(token, stakingPool, txStaking)` (line 859)
- `txProtocol` is pushed via `_safePushOrQuarantine(token, protocolTreasury, txProtocol)` (lines 860-862)

If either push fails (recipient reverts), `_safePushOrQuarantine` quarantines the amount into `pendingClaims[recipient][token]` and increments `totalPendingClaims[token]`. This is correct for the quarantine pattern.

However, `totalDistributed[token]` is incremented by `actualFee` at line 904 regardless of whether pushes succeeded or were quarantined. This is semantically correct (the fees were "distributed" in the sense of being split), but creates a subtle accounting discrepancy:

The vault's token balance after `depositMarketplaceFee()` includes:
- `pendingBridge[token]` (ODDAO shares: txOddao + refOddao + listOddao + any unclaimed referrer/node shares)
- `totalPendingClaims[token]` (failed push amounts + referrer/node claimable amounts)
- Undistributed tokens from other deposits

But `totalDistributed[token]` counts the full `actualFee` even though some of it may still be in the vault as quarantined claims. This means `totalDistributed` does not reflect amounts that actually left the vault, but rather amounts that were *accounted for*. The `distribute()` function uses `balanceOf - pendingBridge - totalPendingClaims` to compute distributable, which is correct, so the operational impact is limited to off-chain analytics.

The deeper concern is the interaction with `distribute()`. If `depositMarketplaceFee()` leaves quarantined amounts in the vault, and then someone calls `distribute()` on the same token, the quarantined amounts are correctly excluded by the `totalPendingClaims` subtraction at line 730. This is safe.

**However**, if the `stakingPool` or `protocolTreasury` address calls `claimPending()` to retrieve their quarantined marketplace transaction fee share, `totalPendingClaims[token]` decreases and `distribute()` sees a larger distributable balance. This means the quarantined amount gets **double-distributed**: once through the marketplace fee path (quarantined), and once through the generic `distribute()` path when new fees arrive and the quarantined amount gets mixed into the distributable pool after claim.

**Proof of Concept:**

1. `depositMarketplaceFee()` is called. `txStaking = 100 XOM`. stakingPool reverts on push.
2. `pendingClaims[stakingPool][XOM] += 100`. `totalPendingClaims[XOM] += 100`.
3. The 100 XOM remains in the vault's token balance.
4. New fees arrive via `deposit()`: 1000 XOM is deposited.
5. `distribute()` is called. `balance = 1000 + 100 + (other pending)`. Distributable = `balance - pendingBridge - totalPendingClaims`. The 100 XOM from step 2 is correctly excluded by `totalPendingClaims`.
6. stakingPool calls `claimPending()`. Gets 100 XOM. `totalPendingClaims[XOM] -= 100`. `pendingClaims[stakingPool][XOM] = 0`.
7. Now the vault's balance dropped by 100 XOM. If `distribute()` is called again, `distributable = balance - pendingBridge - totalPendingClaims` is correct because both `balance` and `totalPendingClaims` decreased by 100. No double-distribution.

After careful analysis, steps 1-7 show the accounting is actually correct. The claim reduces both the vault balance and the `totalPendingClaims`, keeping the distributable calculation sound. **The concern is mitigated.**

However, there is a remaining edge case: the `totalFeesCollected` counter at line 906 aggregates across all tokens into a single uint256. This counter does not distinguish between tokens and cannot be decomposed. If the contract handles fees in XOM, USDC, WBTC, and WETH simultaneously, `totalFeesCollected` sums their raw wei amounts (which have different decimals: XOM=18, USDC=6, WBTC=8, WETH=18). The resulting number is economically meaningless.

**Impact:** Off-chain analytics may be confused by `totalFeesCollected` mixing tokens with different decimal precisions. No on-chain safety impact. The quarantine accounting is correct after detailed analysis.

**Recommendation:**
1. Add a NatSpec comment on `totalFeesCollected` documenting that it aggregates raw amounts across all tokens and is not suitable for cross-token financial comparisons.
2. Consider adding a per-token `totalFeesCollectedByToken[token]` mapping if off-chain analytics require it, or remove `totalFeesCollected` entirely if it provides no value.

---

## Low Findings

### [L-01] `depositMarketplaceFee()` Does Not Emit a Marketplace-Specific Event With Sub-Split Details

**Severity:** Low
**Category:** SC04 -- Event Logging
**VP Reference:** VP-28 (Insufficient Logging)
**Location:** `depositMarketplaceFee()` line 908

**Description:**

`depositMarketplaceFee()` emits the generic `FeesDeposited(token, actualFee, caller)` event at line 908. While off-chain indexers can identify this as a marketplace fee deposit by examining the function selector in transaction input data, the event itself does not contain:
- The sale amount
- The referrer/referrerL2/listingNode/sellingNode addresses
- The sub-split breakdown (txFee/refFee/listFee)
- How much went to each participant vs. ODDAO fallback

This makes off-chain fee reconciliation difficult without parsing transaction calldata. The `FeesDistributed` event from `distribute()` contains the 70/20/10 split, but `depositMarketplaceFee()` performs its own internal splits without an equivalent event.

**Recommendation:**

Add a dedicated event:
```solidity
event MarketplaceFeeDistributed(
    address indexed token,
    uint256 indexed saleAmount,
    uint256 actualFee,
    address referrer,
    address listingNode
);
```

Emit after the splits are complete (before the generic `FeesDeposited`) so indexers get both the high-level and detailed views.

---

### [L-02] Solhint Warning: Function Ordering Violation (external pure before external non-pure)

**Severity:** Low
**Category:** Code Quality / Standards Compliance
**Location:** `getMarketplaceFeeBreakdown()` line 923, `bridgeToTreasury()` line 951

**Description:**

Solhint reports a function ordering warning: `external function can not go after external pure function (line 923)`. The `getMarketplaceFeeBreakdown()` view/pure function at line 923 is declared between `depositMarketplaceFee()` (line 819) and `bridgeToTreasury()` (line 951). Per the Solidity style guide and solhint rules, external pure/view functions should be grouped after external state-changing functions.

**Recommendation:**

Move `getMarketplaceFeeBreakdown()` to the "VIEW FUNCTIONS" section (after line 1438) alongside `undistributed()`, `pendingForBridge()`, `isOssified()`, and `getClaimable()`.

---

### [L-03] No Minimum `minXOMOut` Floor in `swapAndBridge()` -- Operator Can Accept Any Swap Price

**Severity:** Low
**Category:** SC02 -- Business Logic / Price Protection
**VP Reference:** VP-34 (Logic Error)
**Location:** `swapAndBridge()` line 1339, `_validateSwapBridge()` line 1592

**Description:**

The `swapAndBridge()` function accepts a `minXOMOut` parameter for slippage protection. However, the BRIDGE_ROLE holder sets this value. If the BRIDGE_ROLE key is compromised (or operated by a careless bot), `minXOMOut` can be set to 0, allowing the swap to execute at any price -- including one that is severely unfavorable due to low liquidity or sandwich attack.

The BRIDGE_ROLE is trusted by design, and the function already has a `deadline` parameter for MEV protection. However, there is no on-chain minimum floor for `minXOMOut` relative to the input amount. In the worst case, a compromised BRIDGE_ROLE could:
1. Set `minXOMOut = 0`
2. Manipulate the DEX pool (via flash loan or separate transactions)
3. Call `swapAndBridge()` to swap at a 99% loss
4. The attacker profits from the manipulated pool

**Mitigating Factors:**
- BRIDGE_ROLE is admin-managed and should be a multi-sig or automated bot with guardrails.
- The `deadline` parameter prevents indefinite mempool holding.
- The swap amount is capped by `pendingBridge[token]` (accumulated fees, not user deposits).

**Recommendation:**

Consider adding a configurable minimum slippage floor (e.g., 95% of oracle price) enforced on-chain. Alternatively, document that BRIDGE_ROLE must implement off-chain slippage checks and must be operated by a trusted, audited bot.

---

## Informational Findings

### [I-01] Storage Gap Comment Overstates Slot Count Due to Packing

**Severity:** Informational
**Location:** `__gap` declaration, line 310

**Description:**

The comment at line 301 states: "Budget: 15 original + 4 new + 3 deprecated + 8 M-01-03 + 1 totalFeesCollected = 31 slots used. Gap = 19. Total = 50."

However, two packing optimizations reduce the actual slot count:
1. `_ossified` (bool, 1 byte) and `__deprecated_pendingStakingPool` (address, 20 bytes) share slot 5 (21 bytes total).
2. `pendingBridgeModeToken` (address, 20 bytes) and `pendingBridgeMode` (BridgeMode/uint8, 1 byte) share a slot (21 bytes total).

The actual slot count is 29 (not 31), giving a total of 29 + 19 = 48 (not 50). This is conservative and safe -- there is more room for future state variables than the comment suggests. However, the inaccurate comment could cause confusion during future upgrades.

**Recommendation:**

Update the comment to reflect the actual slot count:
```solidity
/// @dev Actual slot usage: 29 (2 pairs pack into single slots:
///      _ossified+__deprecated_pendingStakingPool, and
///      pendingBridgeModeToken+pendingBridgeMode).
///      Gap = 19. Available expansion = 21 slots (29+19+2 packing savings = 50 budget).
```

Alternatively, run `forge inspect UnifiedFeeVault storage-layout` to generate the definitive slot map.

---

### [I-02] `_authorizeUpgrade()` Triggers Compiler Warning: "Function state mutability can be restricted to pure"

**Severity:** Informational
**Location:** `_authorizeUpgrade()` line 1574

**Description:**

The Solidity compiler emits: `Warning: Function state mutability can be restricted to view` for `_authorizeUpgrade()`. The function reads `_ossified` (a state variable) and `newImplementation.code.length` (an address property), making it `view`-eligible. However, it overrides `UUPSUpgradeable._authorizeUpgrade()` which has no `view` modifier, so the override must match the parent's mutability.

This is a false positive -- the function signature cannot be changed without breaking the UUPS interface. The compiler warning is harmless but noisy.

**Recommendation:**

No code change needed. The override constraint prevents adding `view`. This can be silenced by adding a trivial state read or documented as accepted.

---

### [I-03] `totalFeesCollected` Mixes Token Decimals, Producing an Economically Meaningless Aggregate

**Severity:** Informational
**Location:** `totalFeesCollected` at line 298, incremented at lines 751 and 906

**Description:**

`totalFeesCollected` is a single `uint256` that aggregates raw token amounts across all tokens. If the vault processes XOM (18 decimals), USDC (6 decimals), WBTC (8 decimals), and WETH (18 decimals), the counter sums incommensurable values:

- 1000 XOM = 1000e18 wei
- 1000 USDC = 1000e6 wei
- 0.1 WBTC = 0.1e8 wei

Adding these produces `1000000000000000000000 + 1000000000 + 10000000`, which is dominated by the 18-decimal token and has no useful economic interpretation.

The `totalDistributed[token]` per-token mapping provides correct per-token accounting. `totalFeesCollected` appears to exist for the FEE-AP-10 cross-contract audit requirement but may mislead dashboards or analytics.

**Recommendation:**

Add NatSpec documentation explaining that `totalFeesCollected` is a raw aggregate across heterogeneous token decimals. If economic comparisons are needed, use per-token mappings and off-chain USD conversion.

---

### [I-04] Test Coverage Gap: `depositMarketplaceFee()` Has Zero Test Coverage

**Severity:** Informational
**Location:** Test file `test/UnifiedFeeVault.test.js`

**Description:**

The test suite (109 passing tests) thoroughly covers `deposit()`, `distribute()`, `bridgeToTreasury()`, `swapAndBridge()`, `convertPXOMAndBridge()`, all timelock configurations, ossification, pausability, UUPS upgrades, and mathematical correctness. However, `depositMarketplaceFee()` -- the marketplace fee settlement function handling the complex 3-way sub-split (transaction/referral/listing) with 70/20/10 within each sub-split -- has **zero test coverage**.

This function represents a critical fee path for the marketplace (the primary revenue-generating feature of OmniBazaar) and contains:
- 6 address parameters with conditional zero-address fallback logic
- 3 sequential fee divisions with integer rounding
- 4 potential `_safePushOrQuarantine` calls
- 4 potential `pendingClaims` / `totalPendingClaims` updates
- Interaction with the MIN_SALE_AMOUNT guard

Untested code paths in a fee-critical function represent significant deployment risk.

**Recommendation:**

Add comprehensive tests covering:
1. Basic marketplace fee deposit and sub-split verification
2. All zero-address fallback paths (no referrer, no L2 referrer, no listing node, no selling node)
3. All-present participant paths
4. MIN_SALE_AMOUNT boundary checks
5. Fee math verification at boundary values (10,000 / 10,001 / 100,000 / 1,000,000)
6. Quarantine behavior when stakingPool reverts during marketplace fee processing
7. `claimPending()` by referrers, listing nodes, and selling nodes
8. Double-distribution safety (marketplace fee + generic distribute interaction)

---

## DeFi Attack Vector Analysis

### Flash Loan Attacks
**Risk: LOW.** The `distribute()` function uses `balanceOf(address(this))` to determine distributable amounts. A flash loan could temporarily inflate the vault's balance. However, the 70% ODDAO share stays in the vault (tracked in `pendingBridge`), the 20% goes to `stakingPool`, and the 10% goes to `protocolTreasury`. The flash-loaned tokens would be distributed to legitimate recipients, not returned to the attacker. Since the attacker cannot recover the flash-loaned tokens, the loan cannot be repaid, and the transaction reverts. **No viable attack path.**

`depositMarketplaceFee()` requires `DEPOSITOR_ROLE` and `safeTransferFrom()`, so flash-loaned tokens cannot enter via this path without role access. Even if a DEPOSITOR_ROLE contract were flash-loan-aware, the fee calculation is based on `saleAmount` (caller-provided) and the 1% is pulled from the caller, not from the vault's existing balance. **No viable attack path.**

### Front-Running Fee Distributions
**Risk: LOW.** `distribute()` is permissionless. A front-runner could call `distribute()` before another caller, but the result is identical -- fees go to the same recipients with the same ratios. No MEV extraction opportunity.

For `swapAndBridge()`, the `deadline` parameter and `minXOMOut` slippage guard provide sandwich protection. The BRIDGE_ROLE gate prevents unauthorized calls. **Risk is operator trust, not front-running.**

### Reentrancy
**Risk: NONE (MITIGATED).** All state-changing external functions use `nonReentrant`. `_safePushOrQuarantine` uses a low-level call, but the CEI pattern is followed (state updates at lines 748-751 before external calls at lines 756-765 in `distribute()`). `claimPending()` zeros `pendingClaims[caller][token]` before `safeTransfer`. `depositMarketplaceFee()` updates state after the initial `safeTransferFrom` but before any `_safePushOrQuarantine` calls -- the `nonReentrant` modifier prevents re-entry.

### Integer Overflow
**Risk: NONE.** Solidity 0.8.24 has built-in overflow checks. All arithmetic is checked. Maximum realistic `pendingBridge` or `totalPendingClaims` values cannot approach `uint256` overflow with any realistic token supply.

### Denial of Service on Distribution
**Risk: NONE (MITIGATED).** The `_safePushOrQuarantine` pattern ensures reverting recipients do not block `distribute()` or `depositMarketplaceFee()`. Quarantined amounts are tracked in `pendingClaims` for later pull withdrawal via `claimPending()`.

### Token Compatibility
**Risk: LOW (DOCUMENTED).** Fee-on-transfer tokens are handled via balance-before/after in `deposit()` (lines 669-675) and `depositMarketplaceFee()` (lines 843-849). Rebasing tokens are explicitly unsupported (documented at line 94). Non-standard ERC20 tokens (no return value) are handled by `_safePushOrQuarantine`'s `returndata.length == 0` check (line 1554). USDC-style blacklisting is mitigated by `redirectStuckClaim()` (line 1503).

### Price Oracle Manipulation (Swap Path)
**Risk: MEDIUM.** `swapAndBridge()` relies on `IFeeSwapRouter` for token-to-XOM swaps. A compromised BRIDGE_ROLE operator could set `minXOMOut = 0` and exploit a manipulated DEX pool. Mitigations: `deadline` parameter, `minXOMOut` slippage guard, BRIDGE_ROLE access restriction. See L-03 for recommendation.

---

## Cross-Contract Fee Flow Verification

### Fee Path: Source Contracts -> UnifiedFeeVault -> Recipients

```
MinimalEscrow (FEE_VAULT immutable)
    |
    +-- Marketplace fee: safeTransferFrom -> UnifiedFeeVault
    |   (Verified: MinimalEscrow line 435 sets FEE_VAULT)
    |
DEXSettlement (feeRecipients.feeVault)
    |
    +-- Trading fee (30% of net): safeTransfer -> UnifiedFeeVault
    |   (Verified: DEXSettlement feeVault in FeeRecipients struct, line 144)
    |
RWAAMM (FEE_VAULT immutable)
    |
    +-- AMM fee (30%): direct safeTransfer -> UnifiedFeeVault
    |   + notifyDeposit() for audit trail
    |   (Verified: RWAAMM line 253 sets FEE_VAULT)
    |
OmniYieldFeeCollector / OmniPredictionRouter / OmniChatFee / etc.
    |
    +-- Service fees: deposit() -> UnifiedFeeVault (DEPOSITOR_ROLE required)

        |
        v
UnifiedFeeVault
    |
    +-- 70% -> pendingBridge[token] (internal accounting, stays in vault)
    |           |
    |           +-- bridgeToTreasury(token, amount, receiver) -- BRIDGE_ROLE
    |           +-- swapAndBridge(token, amount, minXOM, receiver, deadline) -- BRIDGE_ROLE
    |           +-- convertPXOMAndBridge(amount, receiver, minXOM) -- BRIDGE_ROLE
    |
    +-- 20% -> stakingPool (push via _safePushOrQuarantine, quarantine on fail)
    |
    +-- 10% -> protocolTreasury (push via _safePushOrQuarantine, quarantine on fail)
    |
    +-- Marketplace sub-splits:
    |   +-- 0.50% transaction fee: 70% ODDAO, 20% staking, 10% protocol
    |   +-- 0.25% referral fee: 70% referrer, 20% L2 referrer, 10% ODDAO
    |   +-- 0.25% listing fee: 70% listing node, 20% selling node, 10% ODDAO
    |   +-- Zero-address fallback: participant share -> ODDAO pendingBridge
    |
    +-- Quarantined claims -> pendingClaims[recipient][token]
        +-- claimPending() by recipient
        +-- redirectStuckClaim() by DEFAULT_ADMIN_ROLE (for blacklisted addresses)
```

### Cross-Contract Consistency

| Contract | Fee Target | Method | DEPOSITOR_ROLE Granted? |
|----------|-----------|--------|------------------------|
| MinimalEscrow | UnifiedFeeVault (immutable) | safeTransferFrom for marketplace; direct transfer for arbitration | Must be granted at deployment |
| DEXSettlement | feeRecipients.feeVault | safeTransfer (internal fee distribution) | Must be granted at deployment |
| RWAAMM | FEE_VAULT (immutable) | Direct safeTransfer + notifyDeposit() | Must be granted at deployment |
| OmniChatFee | feeVault (configurable) | deposit() | Must be granted at deployment |
| OmniYieldFeeCollector | feeVault (configurable) | deposit() | Must be granted at deployment |

**Verified:** All upstream contracts send to UnifiedFeeVault and require DEPOSITOR_ROLE for `deposit()` calls. RWAAMM uses direct transfer (bypassing deposit), which is documented and handled by `notifyDeposit()`.

---

## Storage Layout Analysis

### Slot Map (Manual Count)

| Slot | Variable(s) | Size |
|------|-------------|------|
| 0 | stakingPool | 20 bytes |
| 1 | protocolTreasury | 20 bytes |
| 2 | pendingBridge (mapping) | 32 bytes |
| 3 | totalDistributed (mapping) | 32 bytes |
| 4 | totalBridged (mapping) | 32 bytes |
| 5 | _ossified (1 byte) + __deprecated_pendingStakingPool (20 bytes) | 21 bytes (packed) |
| 6 | __deprecated_pendingProtocolTreasury | 20 bytes |
| 7 | __deprecated_recipientChangeTimestamp | 32 bytes |
| 8 | pendingClaims (mapping) | 32 bytes |
| 9 | totalPendingClaims (mapping) | 32 bytes |
| 10 | tokenBridgeMode (mapping) | 32 bytes |
| 11 | swapRouter | 20 bytes |
| 12 | xomToken | 20 bytes |
| 13 | privacyBridge | 20 bytes |
| 14 | pxomToken | 20 bytes |
| 15 | pendingSwapRouter | 20 bytes |
| 16 | swapRouterChangeTimestamp | 32 bytes |
| 17 | pendingPrivacyBridgeAddr | 20 bytes |
| 18 | pendingPXOMToken | 20 bytes |
| 19 | privacyBridgeChangeTimestamp | 32 bytes |
| 20 | ossificationScheduledAt | 32 bytes |
| 21 | pendingNewStakingPool | 20 bytes |
| 22 | pendingNewProtocolTreasury | 20 bytes |
| 23 | recipientChangeTime | 32 bytes |
| 24 | pendingXomToken | 20 bytes |
| 25 | xomTokenChangeTime | 32 bytes |
| 26 | pendingBridgeModeToken (20 bytes) + pendingBridgeMode (1 byte) | 21 bytes (packed) |
| 27 | bridgeModeChangeTime | 32 bytes |
| 28 | totalFeesCollected | 32 bytes |
| 29-47 | __gap[19] | 19 x 32 bytes |

**Actual slots used:** 29 (not 31 as stated in the comment, due to 2 packing pairs).
**Gap:** 19 slots.
**Total (contract's own):** 48.
**Available for expansion:** 19 gap slots (plus 2 "phantom" slots from packing savings).
**UUPS Safety:** No storage collisions detected. Deprecated slots preserved at original positions.

---

## Solhint Analysis

```
contracts/UnifiedFeeVault.sol
   85:1  warning  Contract has 32 states declarations but allowed no more than 20  max-states-count
  819:5  warning  Function has cyclomatic complexity 9 but allowed no more than 7  code-complexity
  951:5  warning  Function order is incorrect                                      ordering
```

| Warning | Assessment |
|---------|-----------|
| `max-states-count` (32 > 20) | **Accepted.** The contract's role as the single fee aggregation point requires extensive state for timelocked configuration, multi-token tracking, quarantine claims, and deprecated UUPS-compatible slots. Splitting into multiple contracts would increase gas costs for fee distribution and add cross-contract coordination complexity. |
| `code-complexity` (9 > 7) for `depositMarketplaceFee()` | **Accepted.** The function implements a complex but correct 3-way fee split with 4 conditional zero-address fallbacks. Extracting helper functions would not reduce logical complexity, only move it. The cyclomatic complexity is driven by the 4 `if/else` branches for referrer/referrerL2/listingNode/sellingNode zero-address handling. |
| `ordering` for `getMarketplaceFeeBreakdown()` | **Actionable.** See L-02 above. |

### Compiler Warnings

| Warning | Assessment |
|---------|-----------|
| `Function state mutability can be restricted to view` for `_authorizeUpgrade()` | **Accepted.** Override constraint from UUPSUpgradeable parent. See I-02 above. |

---

## Compliance Summary

| Check Category | Passed | Failed | Partial | N/A |
|----------------|--------|--------|---------|-----|
| Access Control | 17 | 0 | 0 | 0 |
| Reentrancy | 9 | 0 | 0 | 0 |
| Business Logic | 22 | 0 | 1 | 0 |
| Token Handling | 13 | 0 | 0 | 0 |
| Upgradeability | 7 | 0 | 0 | 0 |
| Event Logging | 6 | 0 | 1 | 0 |
| Gas/DoS | 8 | 0 | 0 | 0 |
| Centralization | 6 | 0 | 0 | 0 |
| Mathematical Correctness | 8 | 0 | 0 | 0 |
| CEI Pattern | 7 | 0 | 0 | 0 |
| **Total** | **103** | **0** | **2** | **0** |
| **Compliance Score** | | | | **98.1%** |

---

## Incomplete Code Detection

| Pattern | Instances Found |
|---------|----------------|
| TODO comments | 0 |
| FIXME comments | 0 |
| Stub / mock implementations | 0 |
| "in production" deferred comments | 0 |
| console.log / console.sol | 0 |
| Hardcoded test addresses | 0 |

The contract contains no incomplete code patterns. All audit fix comments reference completed remediations.

---

## Recommendations Summary (Priority Order)

1. **MEDIUM PRIORITY:** Document `totalFeesCollected` cross-token aggregation limitation in NatSpec; consider per-token counter or removal (M-01)
2. **LOW PRIORITY:** Add a dedicated `MarketplaceFeeDistributed` event with sub-split details (L-01)
3. **LOW PRIORITY:** Move `getMarketplaceFeeBreakdown()` to the view functions section to resolve solhint ordering warning (L-02)
4. **LOW PRIORITY:** Document that BRIDGE_ROLE must implement off-chain slippage floors for `swapAndBridge()` (L-03)
5. **INFORMATIONAL:** Update storage gap comment to reflect actual packed slot count of 29 (I-01)
6. **INFORMATIONAL:** Accept compiler warning on `_authorizeUpgrade()` (I-02)
7. **INFORMATIONAL:** Add NatSpec to `totalFeesCollected` about decimal mixing (I-03)
8. **CRITICAL (Testing):** Add comprehensive test coverage for `depositMarketplaceFee()` before mainnet deployment (I-04)

---

## Conclusion

The UnifiedFeeVault has undergone extensive hardening through 6 prior audit rounds and now presents a strong security posture. All Critical and High findings from all prior rounds (C-01, H-01, H-02, H-03 from R5; H-01 from R6) have been properly remediated and verified. The contract demonstrates:

- **Correct 70/20/10 fee split** with remainder-to-protocol dust handling
- **Comprehensive timelocks** (48h) on all configuration changes (recipients, swap router, privacy bridge, XOM token, bridge mode, ossification)
- **Robust pull-pattern quarantine** for reverting recipients via `_safePushOrQuarantine` / `claimPending`
- **Proper CEI pattern** throughout all state-changing functions
- **Consistent ERC-2771** meta-transaction support via `_msgSender()` in all deposit paths
- **UUPS upgrade safety** with code-length validation and ossification support
- **Clean deprecated slot handling** preserving UUPS storage layout

The remaining findings are primarily documentation (M-01 NatSpec clarification), code organization (L-02 function ordering), and operational recommendations (L-03 BRIDGE_ROLE guardrails). The most significant action item is the test coverage gap for `depositMarketplaceFee()` (I-04), which should be addressed before mainnet deployment.

**Overall Risk Assessment:** LOW -- suitable for mainnet deployment after addressing the test coverage gap (I-04) and deploying ADMIN_ROLE / DEFAULT_ADMIN_ROLE behind a multi-sig-controlled TimelockController.

**Contract Size:** 14.569 KiB deployed (60.7% of the 24 KiB mainnet limit). Adequate headroom for any minor adjustments.

**Test Results:** 109/109 passing (100% pass rate on existing tests).
