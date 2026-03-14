# Security Audit Report: MintController

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7)
**Contract:** `Coin/contracts/MintController.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 455
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (controls future XOM token minting -- up to 16.6 billion XOM)
**OpenZeppelin Version:** 5.4.0
**Dependencies:** `AccessControlDefaultAdminRules`, `Pausable`, `ReentrancyGuard`, `IERC20`, custom `IOmniCoinMintable` interface
**Test Coverage:** `Coin/test/MintController.test.js` (14 tests, all passing)
**Previous Audits:** Round 1 (2026-02-21), Round 2 (2026-02-26) -- not included in Round 6 (contract marked DEPRECATED)

---

## Deprecation Context

MintController is explicitly marked as **DEPRECATED -- DO NOT DEPLOY** in its own NatSpec (lines 10-30). The OmniBazaar architecture pre-mints all 16.6 billion XOM at genesis via `OmniCoin.initialize()` and distributes tokens from pre-funded pool contracts (OmniRewardManager, LegacyBalanceClaim, StakingRewardPool) using `SafeERC20.safeTransfer()`. After genesis deployment, `MINTER_ROLE` on OmniCoin is revoked from all addresses, and no MintController is deployed.

The production deployment scripts (`deploy-mainnet.js`, `deploy-mainnet-phase1b.js`) confirm this: they print "Transfer-based -- NO MINTER_ROLE. Trustless architecture." and never deploy MintController. The `revoke-minter-role-mainnet.js` script permanently removes all minting authority.

**This audit is conducted for completeness** (the contract exists in the codebase and compiles) and to verify that no one could accidentally or maliciously deploy it alongside a future OmniCoin instance.

---

## Executive Summary

MintController has been significantly improved across three audit rounds. All critical findings from Rounds 1 and 2 have been remediated: the TOCTOU race condition is eliminated via a post-mint assertion, the unsafe low-level call is replaced with a typed interface, `AccessControlDefaultAdminRules` replaces basic `AccessControl` (fixing the prior M-01), and `unpause()` is now restricted to `DEFAULT_ADMIN_ROLE` (fixing the prior M-02). The stale epoch state variables have NatSpec warnings and a comprehensive `currentEpochInfo()` view function (fixing the prior M-03). The event indexing issue (prior L-01) is fixed.

This round identified **0 Critical**, **0 High**, **1 Medium**, **2 Low**, and **3 Informational** findings. The most notable is a logic error in `currentEpochInfo()` that conflates two different epoch timescales, producing wildly incorrect block reward estimates. Given the contract's deprecated status, the practical impact is zero -- but the bug would be material if the contract were ever deployed.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 2 |
| Informational | 3 |

---

## Remediation Status from Previous Audits

### Round 1 (2026-02-21) Findings

| ID | Finding | Severity | Status | Verification |
|----|---------|----------|--------|--------------|
| H-01 | TOCTOU race condition on totalSupply() | High | **FIXED** | Post-mint assertion at lines 267-272 reads `TOKEN.totalSupply()` after mint and reverts if > MAX_SUPPLY. |
| M-01 | Unsafe low-level call | Medium | **FIXED** | `IOmniCoinMintable` typed interface (lines 45-50) replaces `address.call()`. Call at line 263 uses `TOKEN.mint(to, amount)`. |
| M-02 | No emergency pause | Medium | **FIXED** | Contract inherits `Pausable` (line 62). `PAUSER_ROLE` (line 73) controls `pause()` (line 284). `mint()` has `whenNotPaused` modifier (line 234). |
| M-03 | No rate limiting | Medium | **FIXED** | Per-epoch rate limit at lines 239-250. `MAX_MINT_PER_EPOCH = 100_000_000e18` (line 90). Epoch duration is 1 hour (line 82). Counter resets on epoch boundary. |
| M-04 | No timelock on admin | Medium | **FIXED** | Now uses `AccessControlDefaultAdminRules` with 48-hour delay (lines 32, 60, 94, 197-198). |
| L-01 | Event emits calculated supply | Low | **FIXED** | Event emits `postMintSupply` from actual `TOKEN.totalSupply()` read at line 267, emitted at line 274. |
| L-02 | No batch minting | Low | **OPEN** | Not addressed. See I-02 below. |
| L-03 | Immutable TOKEN -- no migration path | Low | **ACCEPTED** | By design. |
| I-01 | MAX_SUPPLY not verified against token | Info | **OPEN** | See I-03 below. |

### Round 2 (2026-02-26) Findings

| ID | Finding | Severity | Status | Verification |
|----|---------|----------|--------|--------------|
| M-01 | No two-step admin transfer | Medium | **FIXED** | Replaced `AccessControl` with `AccessControlDefaultAdminRules` (line 60). Constructor passes `ADMIN_TRANSFER_DELAY` (48 hours) at line 197-198. |
| M-02 | PAUSER_ROLE can both pause and unpause | Medium | **FIXED** | `unpause()` now requires `DEFAULT_ADMIN_ROLE` (line 299). `pause()` requires `PAUSER_ROLE` (line 284). Asymmetric model matches EmergencyGuardian pattern. |
| M-03 | Stale epoch state confusion | Medium | **FIXED** | NatSpec warnings added to `currentEpoch` (lines 109-112) and `epochMinted` (lines 114-118). `currentEpochInfo()` view function added (lines 374-410) for accurate data. |
| L-01 | Indexed uint256 in ControlledMint event | Low | **FIXED** | `amount` and `newTotalSupply` are now non-indexed (lines 133-137). Only `to` is indexed. Explicit NatSpec explains the reasoning (lines 127-131). |
| L-02 | No batch minting capability | Low | **OPEN** | Not addressed. Acceptable given deprecation. |
| I-01 | Constructor does not verify TOKEN is a contract | Info | **ACCEPTED** | Typed interface provides implicit protection. |
| I-02 | MAX_SUPPLY not cross-validated against token | Info | **OPEN** | See I-03 below. |
| I-03 | Test coverage gaps | Info | **OPEN** | 14 tests cover core paths but lack pause, epoch rate limit, and reentrancy test cases. See I-01 below. |

---

## Architecture Analysis

### Design Strengths

1. **Defense-in-Depth Supply Protection:** Three independent guards: (a) pre-mint `totalSupply()` check (lines 253-260), (b) OmniCoin's own `MAX_SUPPLY` check in its `mint()` function, (c) post-mint `totalSupply()` assertion (lines 267-272). All three must fail for an over-mint.

2. **TOCTOU Elimination:** The post-mint assertion (line 267) reads `TOKEN.totalSupply()` after the actual mint and reverts via `SupplyCapViolated` if the cap is violated. This eliminates the race condition identified in Round 1.

3. **Two-Step Admin Transfer:** `AccessControlDefaultAdminRules` with 48-hour delay (line 94) prevents instant admin key transfers and provides a cancellation window. Matches OmniCoin's own admin delay.

4. **Asymmetric Pause/Unpause:** `pause()` requires `PAUSER_ROLE` (hot wallet, fast response), `unpause()` requires `DEFAULT_ADMIN_ROLE` (timelock/multisig, deliberate governance action). A compromised pauser cannot undo a legitimate emergency pause.

5. **Rate Limiting:** Per-epoch rate limit of 100M XOM per hour bounds blast radius of compromised `MINTER_ROLE`. At expected block reward rate (~28,080 XOM/hour), this provides ~3,560x headroom.

6. **Typed Interface:** `IOmniCoinMintable` (lines 45-50) provides compile-time `mint()` signature verification.

7. **Immutable TOKEN:** Cannot be changed post-deployment (line 103), preventing token substitution attacks.

8. **Custom Errors:** All revert conditions use gas-efficient custom errors with descriptive parameters (lines 144-174).

9. **Complete NatSpec:** All public/external functions, state variables, events, errors, and constants have proper NatSpec documentation, including stale-data warnings on epoch variables.

### Dependency Analysis

- **OpenZeppelin AccessControlDefaultAdminRules (v5.4.0):** Provides two-step admin transfer with configurable delay. The 48-hour delay matches OmniCoin. Well-audited.

- **OpenZeppelin Pausable (v5.4.0):** Standard pause/unpause. `whenNotPaused` on `mint()` correctly blocks all minting when paused.

- **OpenZeppelin ReentrancyGuard (v5.4.0):** `nonReentrant` on `mint()` prevents reentrancy through `TOKEN.mint()` callbacks. Defense-in-depth -- standard ERC20 `_mint()` does not trigger callbacks in OZ v5.

- **IOmniCoinMintable:** Custom interface extending `IERC20` with `mint(address, uint256)`. Matches OmniCoin.sol's `mint` function signature.

### Control Flow Analysis

```
mint(to, amount)
  |-- Access: onlyRole(MINTER_ROLE)
  |-- Reentrancy: nonReentrant
  |-- State: whenNotPaused
  |
  |-- Input Validation
  |   |-- amount == 0 --> revert ZeroAmount()
  |   |-- to == address(0) --> revert InvalidAddress()
  |
  |-- Rate Limit Check
  |   |-- epoch = block.timestamp / 3600
  |   |-- If new epoch: reset currentEpoch, epochMinted = 0
  |   |-- If epochMinted + amount > 100M XOM --> revert EpochRateLimitExceeded()
  |   |-- epochMinted += amount
  |
  |-- Pre-mint Supply Check
  |   |-- preMintSupply = TOKEN.totalSupply()
  |   |-- remaining = MAX_SUPPLY - preMintSupply (or 0 if supply >= cap)
  |   |-- If amount > remaining --> revert MaxSupplyExceeded()
  |
  |-- Execute Mint
  |   |-- TOKEN.mint(to, amount)  [typed interface call]
  |
  |-- Post-mint Assertion (TOCTOU guard)
  |   |-- postMintSupply = TOKEN.totalSupply()
  |   |-- If postMintSupply > MAX_SUPPLY --> revert SupplyCapViolated()
  |
  |-- Emit ControlledMint(to, amount, postMintSupply)
```

---

## Findings

### [M-01] `currentEpochInfo()` Conflates Rate-Limit Epochs with Block Reward Epochs -- Incorrect Reward and blocksInEpoch Values

**Severity:** Medium
**Lines:** 387, 403, 406-409
**Status:** NEW

**Description:**

MintController uses two fundamentally different epoch concepts but treats them as interchangeable in `currentEpochInfo()`:

1. **Rate-limit epoch:** `block.timestamp / EPOCH_DURATION` where `EPOCH_DURATION = 1 hours`. This produces the number of hours since Unix epoch. At current time (~March 2026), this value is approximately 492,000.

2. **Block reward epoch:** In OmniValidatorRewards, `EPOCH_DURATION = 2` (2 seconds). Each "epoch" is one block. Block reward reductions occur every `BLOCKS_PER_REDUCTION = 6,311,520` epochs (blocks), which equals ~146 days at 2-second blocks.

In `currentEpochInfo()` at line 403, the rate-limit epoch number (hours since Unix epoch) is passed to `_approximateBlockReward()`, which divides by `6,311,520` to determine reduction count:

```solidity
// Line 387: epoch ~ 492,000 (hours since Unix epoch)
epoch = block.timestamp / EPOCH_DURATION;

// Line 403: Feeds hours-epoch into a function expecting 2s-epoch
reward = _approximateBlockReward(epoch);

// Line 407: Treats hours-epoch as block count
uint256 epochBlock = epoch; // 1 epoch = 1 block (2s)  <-- WRONG
```

The comment on line 407 says "1 epoch = 1 block (2s)" but this is false in MintController's context. Here, 1 epoch = 1 hour = 1,800 blocks.

**Concrete impact:**

- At deployment (~March 2026), the rate-limit epoch is ~492,000.
- `_approximateBlockReward(492000)` computes `492000 / 6311520 = 0` reductions, returning the initial 15.602 XOM. This happens to be approximately correct by coincidence (the chain has not been running long enough for a reduction).
- However, `blocksInEpoch = 6311520 - (492000 % 6311520) = 5,819,520`. This represents "hours remaining" not "blocks remaining." The actual blocks remaining would be `5,819,520 * 1,800 = ~10.47 billion`, which overflows the semantic meaning.
- After ~7,200 hours (~300 days), the epoch hits 500,000 and still shows 0 reductions. But by that time, the actual block count would be ~900,000 (far below the first reduction at 6,311,520), so the reward is still coincidentally correct.
- The conflation becomes materially wrong only after years of operation when the two timescales diverge significantly.

**Impact:** The `reward` and `blocksInEpoch` return values from `currentEpochInfo()` are semantically incorrect. Off-chain integrations (dashboards, analytics) consuming these values would display wrong data. Since MintController is deprecated and will not be deployed, practical impact is zero.

**Recommendation:**

If this contract were to be deployed, `currentEpochInfo()` should use `block.number` (or a block-count parameter) for the reward calculation instead of the rate-limit epoch:

```solidity
// Use block.number for reward calculation
reward = _approximateBlockReward(block.number);
uint256 reductionPeriod = 6_311_520;
blocksInEpoch = reductionPeriod - (block.number % reductionPeriod);
```

Alternatively, since the reward calculation is purely informational and not authoritative (OmniValidatorRewards is the canonical source), consider removing the `reward` and `blocksInEpoch` return values entirely to avoid confusion.

---

### [L-01] Test Coverage Remains Incomplete for Post-Round-1 Features

**Severity:** Low
**Lines:** N/A (test file: `Coin/test/MintController.test.js`)
**Status:** Carried forward from Round 2 I-03

**Description:**

The test suite (14 tests, all passing) was written against the original Round 1 contract version. Features added during remediation lack dedicated test coverage:

1. **Pause/Unpause:** No tests verify `mint()` reverts when paused, that `pause()` requires `PAUSER_ROLE`, that `unpause()` requires `DEFAULT_ADMIN_ROLE` (not `PAUSER_ROLE`), or that non-authorized callers cannot pause/unpause.

2. **Epoch Rate Limiting:** No tests verify that minting up to `MAX_MINT_PER_EPOCH` succeeds, that exceeding it reverts with `EpochRateLimitExceeded`, that epoch rollover resets the counter, or that `remainingInCurrentEpoch()` returns accurate values for both current and stale epochs.

3. **PAUSER_ROLE in Constructor:** No test verifies the deployer receives `PAUSER_ROLE` at construction.

4. **AccessControlDefaultAdminRules:** No tests verify the 48-hour admin transfer delay, two-step transfer process, or that instant admin transfers are impossible.

5. **currentEpochInfo():** No tests verify any of the six return values.

6. **Post-mint TOCTOU Assertion:** The `SupplyCapViolated` error path is untested (difficult to trigger without a malicious token contract mock).

**Impact:** Remediations from Rounds 1 and 2 are code-reviewed but not test-validated. Given the contract is deprecated, the practical risk is zero.

**Recommendation:**

If the contract were to be deployed, add test cases covering the above scenarios. Hardhat's `time.increase()` enables epoch rollover testing. A mock OmniCoin that mints extra tokens in its `mint()` callback could test the TOCTOU assertion path.

---

### [L-02] `solhint-disable` at Line 4 Suppresses All Lint Warnings for Entire File

**Severity:** Low
**Lines:** 4
**Status:** NEW

**Description:**

Line 4 contains a blanket `// solhint-disable` directive that suppresses all solhint warnings for the entire file. While the contract passes solhint cleanly (0 errors, 0 warnings), this blanket suppression means that future modifications to the contract would also bypass all linting -- including checks for reentrancy patterns, function ordering, gas optimizations, and naming conventions.

The contract already uses targeted `solhint-disable-next-line` directives for specific legitimate suppressions (lines 239, 319, 348, 386 for `not-rely-on-time` and line 124 for `gas-indexed-events`). These targeted directives are the proper approach.

**Impact:** The blanket disable means the solhint pass reported (0 errors, 0 warnings) provides no assurance -- all warnings are suppressed. Any lint violations that exist are invisible.

**Recommendation:**

Remove the blanket `// solhint-disable` at line 4. The targeted `solhint-disable-next-line` directives already handle the legitimate suppressions. If additional warnings appear after removal, address them individually with either fixes or targeted disable comments with justification.

---

### [I-01] Batch Minting Not Implemented

**Severity:** Informational
**Lines:** N/A (missing feature)
**Status:** Carried forward from Round 1 L-02, Round 2 L-02

**Description:**

Block reward distribution requires multiple mint calls per block (staking pool, ODDAO, block producer). No `batchMint()` function exists to aggregate these into a single transaction.

**Impact:** Higher gas costs per block for validators. On Avalanche C-Chain with low gas costs, the financial impact is minimal. Given the contract is deprecated in favor of pre-minted pool transfers, this is moot.

**Recommendation:** No action needed. The production architecture uses `SafeERC20.safeTransfer()` from pre-funded pools, which does not require minting at all.

---

### [I-02] MAX_SUPPLY Not Cross-Validated Against Token Contract in Constructor

**Severity:** Informational
**Lines:** 79, 194-207
**Status:** Carried forward from Round 1 I-01, Round 2 I-02

**Description:**

MintController defines `MAX_SUPPLY = 16_600_000_000e18` as a hardcoded constant. OmniCoin.sol also defines `MAX_SUPPLY = 16_600_000_000 * 10 ** 18`. These values match, but there is no runtime verification of this agreement. If either contract were redeployed with a different cap, MintController would enforce a stale value.

**Impact:** Deployment-time misconfiguration risk. Given the contract is deprecated and will not be deployed, risk is zero.

**Recommendation:** No action needed given deprecation. If deployed, add constructor-time validation:

```solidity
// Would require adding MAX_SUPPLY() to IOmniCoinMintable interface
uint256 tokenCap = TOKEN.MAX_SUPPLY();
if (tokenCap != MAX_SUPPLY) revert CapMismatch(tokenCap, MAX_SUPPLY);
```

---

### [I-03] Contract Retained in Codebase Despite Deprecation -- Accidental Deployment Risk

**Severity:** Informational
**Lines:** 1-455 (entire file)
**Status:** NEW

**Description:**

The contract is marked "DEPRECATED -- DO NOT DEPLOY" in NatSpec but remains fully compilable, passes all tests, and produces deployment artifacts in `artifacts/contracts/MintController.sol/`. A developer unfamiliar with the deprecation history could deploy it alongside a future OmniCoin instance, creating an unauthorized minting pathway if `MINTER_ROLE` were granted to the MintController address on OmniCoin.

The production deployment scripts (`deploy-mainnet.js`, `deploy-mainnet-phase1b.js`) correctly exclude MintController, and `revoke-minter-role-mainnet.js` permanently removes minting authority. However, future deploy scripts written by new team members might not follow this pattern.

**Impact:** Low probability. The contract cannot mint tokens unless explicitly granted `MINTER_ROLE` on OmniCoin, and the production flow revokes all minting authority. However, defense-in-depth suggests eliminating the possibility entirely.

**Recommendation:**

Consider one of the following:

1. **Move to a `deprecated/` directory** outside the main `contracts/` folder so it does not compile by default.
2. **Add a constructor revert** to make deployment impossible:
   ```solidity
   constructor(address) {
       revert("DEPRECATED: Use OmniRewardManager for token distribution");
   }
   ```
3. **Delete the file** entirely if the team is confident it is no longer needed for reference.

---

## Access Control Map

| Role | Functions | Holders (intended) | Risk Level |
|------|-----------|-------------------|------------|
| DEFAULT_ADMIN_ROLE | `grantRole()`, `revokeRole()`, `unpause()` | OmniTimelockController (via 48h two-step transfer) | 7/10 |
| MINTER_ROLE | `mint()` | BlockRewardService, BonusService (if deployed) | 7/10 |
| PAUSER_ROLE | `pause()` | EmergencyGuardian (hot wallet) | 3/10 |
| (public) | All view/pure functions | Anyone | 0/10 |

### Centralization Risk Assessment

**Rating: 5/10** (improved from 6/10 in Round 2)

The upgrade from `AccessControl` to `AccessControlDefaultAdminRules` adds a 48-hour delay to admin transfers, closing the instant-admin-compromise gap. Combined with the existing rate limiting (100M XOM/hour), asymmetric pause/unpause, and defense-in-depth supply checks, the centralization risk is well-mitigated.

**Maximum single-key damage scenarios:**

- **Compromised MINTER_ROLE:** 100M XOM per hour until paused. Pauser can halt immediately.
- **Compromised PAUSER_ROLE:** Can pause minting (DoS) but cannot unpause (requires admin). Cannot mint.
- **Compromised DEFAULT_ADMIN_ROLE:** Must wait 48 hours for admin transfer to complete (can be cancelled). Can grant MINTER_ROLE and mint 100M XOM/hour, but rate limit bounds damage.
- **Compromised MINTER + PAUSER:** Can mint 100M/hour and prevent pause by a legitimate guardian. Admin can still revoke both roles.

---

## Static Analysis Results

### Solhint

```
0 errors, 0 warnings
```

Note: The blanket `// solhint-disable` at line 4 suppresses all warnings. The zero-warning result is not meaningful -- see L-02. Global config warnings (`contract-name-camelcase`, `event-name-camelcase` non-existent rules) are not related to MintController code.

### Manual Pattern Checks

| Pattern | Status | Notes |
|---------|--------|-------|
| Reentrancy | PASS | `nonReentrant` on `mint()` (line 234) |
| Integer overflow | PASS | Solidity 0.8.24 checked arithmetic. `epochMinted + amount` cannot overflow uint256. |
| Access control | PASS | `onlyRole(MINTER_ROLE)` on `mint()`. `onlyRole(PAUSER_ROLE)` on `pause()`. `onlyRole(DEFAULT_ADMIN_ROLE)` on `unpause()`. |
| Admin transfer safety | PASS | `AccessControlDefaultAdminRules` with 48-hour delay. Two-step process with cancellation window. |
| Frontrunning | PASS | Rate limiting bounds damage. Post-mint assertion catches cap violations. |
| Denial of service | PASS | No unbounded loops in state-changing functions. `_approximateBlockReward` loops up to 99 iterations but is in a view function only. |
| Timestamp dependence | ACCEPTABLE | `block.timestamp / EPOCH_DURATION` for rate limiting (line 240). Avalanche validators have limited timestamp flexibility (~few seconds). Epoch granularity is 1 hour, so minor timestamp variance is negligible. |
| tx.origin usage | PASS | Not used. |
| Unchecked return values | PASS | Typed interface call reverts on failure via ABI decoder. |
| Self-destruct | PASS | Not present. |
| Token recovery | N/A | Contract holds no tokens. No accidental token lock risk. |
| Flash loan attacks | N/A | `totalSupply()` reads are not manipulable by flash loans. Supply cap enforcement is sound. |

---

## Gas Analysis

| Function | Estimated Gas | Notes |
|----------|--------------|-------|
| `mint()` (first in epoch) | ~85,000 | Two SSTORE (epoch reset + epochMinted), two external calls (totalSupply x2 + mint), event |
| `mint()` (same epoch) | ~65,000 | One SSTORE (epochMinted), two external calls, event |
| `pause()` | ~28,000 | One SSTORE (paused flag) |
| `unpause()` | ~28,000 | One SSTORE (paused flag) |
| `remainingMintable()` | ~2,600 | One external call |
| `remainingInCurrentEpoch()` | ~2,400 | Two SLOAD |
| `currentEpochInfo()` | ~5,000 | Two SLOAD, one external call, loop in pure helper |
| `maxSupplyCap()` | ~200 | Pure function, no storage |
| `currentSupply()` | ~2,600 | One external call |

Gas costs are reasonable for Avalanche C-Chain.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance to MintController |
|---------|------|------|-----------------------------|
| Cover Protocol | 2020-12 | N/A | Unlimited minting via logic flaw -- triple supply cap guard prevents this class |
| DAO Maker | 2021-09 | $4M | Unauthorized minting via compromised key -- rate limit (100M/hr) + 48h admin delay bounds damage |
| Ronin Network | 2022-03 | $624M | Compromised admin keys -- `AccessControlDefaultAdminRules` with 48h delay + cancellation window addresses this |
| Harmony Bridge | 2022-06 | $100M | Compromised multisig -- `PAUSER_ROLE` separation + asymmetric unpause helps here |
| VTVL | 2022-09 | N/A | Supply cap bypass -- triple guard (pre-mint, OmniCoin internal, post-mint) prevents this |
| SafeMoon | 2023-03 | $8.9M | Unprotected minting -- `MINTER_ROLE` prevents unauthorized minting |

---

## Remediation Priority

| Priority | Finding | Severity | Effort | Impact | Notes |
|----------|---------|----------|--------|--------|-------|
| 1 | M-01: currentEpochInfo epoch conflation | Medium | Low | Incorrect off-chain data | Only relevant if contract is deployed |
| 2 | L-02: Blanket solhint-disable | Low | Trivial | Masks lint issues | Remove line 4, fix any surfaced warnings |
| 3 | L-01: Test coverage gaps | Low | Medium | Untested remediations | 14 tests cover core paths only |
| 4 | I-03: Deprecation enforcement | Info | Trivial | Prevent accidental deployment | Move to deprecated/ dir or add constructor revert |
| 5 | I-01: No batch minting | Info | N/A | N/A | Moot given deprecation |
| 6 | I-02: No MAX_SUPPLY cross-validation | Info | Low | Deployment misconfiguration | Moot given deprecation |

**Overall recommendation:** Given this contract is deprecated and will not be deployed, no remediations are required. If the contract were to be reactivated, M-01 (epoch conflation) should be fixed before deployment. The most actionable step for the current codebase is I-03 -- either move the file to a `deprecated/` directory or add a constructor revert to prevent accidental deployment.

---

## Test Results

```
MintController
  Deployment
    ✔ should set the token address correctly
    ✔ should revert deployment with zero address
    ✔ should grant deployer DEFAULT_ADMIN_ROLE and MINTER_ROLE
  View Functions
    ✔ maxSupplyCap should return 16.6 billion
    ✔ remainingMintable should account for initial supply
    ✔ currentSupply should match token totalSupply
  Minting
    ✔ should mint tokens successfully under the cap
    ✔ should revert when minting zero amount
    ✔ should revert when minting to zero address
    ✔ should revert when minting exceeds MAX_SUPPLY
    ✔ should allow minting exactly to the cap
    ✔ should revert any mint after cap is reached
  Access Control
    ✔ should revert when non-minter tries to mint
    ✔ should allow admin to grant and revoke minter role

14 passing
```

---

## Conclusion

MintController has matured considerably across three audit rounds. All prior High and Medium findings from Rounds 1 and 2 have been properly remediated:

- **H-01 (TOCTOU):** Fixed with post-mint assertion
- **M-01 Round 1 (unsafe call):** Fixed with typed interface
- **M-02 Round 1 (no pause):** Fixed with Pausable + PAUSER_ROLE
- **M-03 Round 1 (no rate limit):** Fixed with per-epoch rate limiting
- **M-04 Round 1 / M-01 Round 2 (no admin delay):** Fixed with AccessControlDefaultAdminRules
- **M-02 Round 2 (symmetric pause/unpause):** Fixed with asymmetric roles
- **M-03 Round 2 (stale epoch state):** Fixed with NatSpec + currentEpochInfo()
- **L-01 Round 2 (indexed uint256 events):** Fixed with non-indexed amount/supply

The one new Medium finding (M-01, epoch conflation in `currentEpochInfo()`) is a logic bug that produces incorrect informational data, but does not affect the core minting safety mechanisms (supply cap, rate limiting, access control, TOCTOU guard).

The contract is well-engineered for its stated purpose. However, since the production architecture uses pre-minted pool-based distribution via `SafeERC20.safeTransfer()`, MintController is correctly deprecated and should not be deployed. The pre-minted approach is architecturally superior: it eliminates the entire class of infinite-mint attack vectors by removing minting authority from all addresses post-genesis.

**Final assessment:** The contract is sound but unnecessary. The team's decision to deprecate it in favor of the trustless pre-mint architecture is the correct one.

---

*Generated by Claude Code Audit Agent -- Round 7*
*Previous audits: Round 1 (2026-02-21, 1H/4M/3L/1I), Round 2 (2026-02-26, 0H/3M/2L/3I)*
*Contract status: DEPRECATED -- DO NOT DEPLOY*
