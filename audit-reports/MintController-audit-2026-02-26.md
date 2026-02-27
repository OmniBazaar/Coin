# Security Audit Report: MintController

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/MintController.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 269
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (controls all future XOM token minting -- ~12.47 billion XOM over 40 years)
**OpenZeppelin Version:** 5.4.0
**Dependencies:** `AccessControl`, `Pausable`, `ReentrancyGuard`, `IERC20`, custom `IOmniCoinMintable` interface
**Test Coverage:** `Coin/test/MintController.test.js` (14 tests, all passing)
**Previous Audit:** `MintController-audit-2026-02-21.md` (1 High, 4 Medium, 3 Low, 1 Informational)

---

## Executive Summary

MintController serves as the sole chokepoint for all XOM token minting. It wraps OmniCoin's `mint()` function with three layers of protection: an immutable `MAX_SUPPLY` cap of 16.6 billion XOM, a per-epoch rate limit of 100 million XOM per hour, and a post-mint assertion that eliminates TOCTOU race conditions. The contract uses role-based access control (`MINTER_ROLE` for authorized minting, `PAUSER_ROLE` for emergency halt, `DEFAULT_ADMIN_ROLE` for role management), `ReentrancyGuard` for callback protection, and `Pausable` for emergency stops.

**Comparison to Previous Audit (2026-02-21):** The contract has been substantially improved since the prior audit. All four findings rated High or Medium have been remediated:

| Previous Finding | Status | Resolution |
|-----------------|--------|------------|
| H-01: TOCTOU race condition | **FIXED** | Post-mint `totalSupply()` assertion added (line 195-198) |
| M-01: Unsafe low-level call | **FIXED** | Typed `IOmniCoinMintable` interface replaces `address.call()` |
| M-02: No emergency pause | **FIXED** | `Pausable` with `PAUSER_ROLE` added |
| M-03: No rate limiting | **FIXED** | Per-epoch (1 hour) rate limit of 100M XOM |
| M-04: No timelock on admin | **OPEN** | Not addressed in this contract (see M-01 below) |

The current contract is significantly more robust. This fresh audit identified **0 Critical**, **0 High**, **3 Medium**, **2 Low**, and **3 Informational** findings. The most significant remaining issue is that `DEFAULT_ADMIN_ROLE` uses basic `AccessControl` (single-step transfer, no timelock delay) rather than `AccessControlDefaultAdminRules`, which creates a single point of failure if the admin key is compromised.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 2 |
| Informational | 3 |

---

## Architecture Analysis

### Design Strengths

1. **Defense-in-Depth Supply Protection:** Three independent guards against exceeding MAX_SUPPLY: (a) pre-mint `totalSupply()` check (line 180-187), (b) OmniCoin's own `MAX_SUPPLY` check in its `mint()` function (OmniCoin.sol line 124), and (c) post-mint `totalSupply()` assertion (line 195-198). All three must fail for an over-mint to occur.

2. **TOCTOU Elimination:** The post-mint assertion reads `TOKEN.totalSupply()` after the actual mint and reverts if the cap is violated. This eliminates the theoretical race condition where concurrent minters could each pass the pre-mint check with the same stale supply value.

3. **Typed Interface:** `IOmniCoinMintable` provides compile-time function signature verification. If OmniCoin's `mint()` signature changes, compilation fails instead of silently reverting at runtime.

4. **Rate Limiting:** The per-epoch rate limit (100M XOM/hour) bounds the blast radius of a compromised `MINTER_ROLE` key. At the expected block reward rate (~28,080 XOM/hour), this provides ~3,560x headroom for legitimate operations while capping damage from exploitation to 100M per hour.

5. **Immutable TOKEN:** The `TOKEN` address cannot be changed post-deployment, preventing token substitution attacks.

6. **Separation of Concerns:** `PAUSER_ROLE` is separate from `MINTER_ROLE` and `DEFAULT_ADMIN_ROLE`, allowing a dedicated hot-wallet to pause minting instantly without needing minting or admin authority.

7. **Custom Errors:** All revert conditions use gas-efficient custom errors with descriptive parameters.

8. **Complete NatSpec:** All public/external functions, state variables, events, errors, and constants have proper NatSpec documentation.

### Dependency Analysis

- **OpenZeppelin AccessControl (v5.4.0):** Well-audited role management. Note: basic `AccessControl`, not `AccessControlDefaultAdminRules` -- this is a deliberate trade-off but introduces centralization risk (see M-01).

- **OpenZeppelin Pausable (v5.4.0):** Standard pause/unpause pattern. The `whenNotPaused` modifier on `mint()` correctly blocks all minting when paused.

- **OpenZeppelin ReentrancyGuard (v5.4.0):** The `nonReentrant` modifier on `mint()` prevents reentrancy through `TOKEN.mint()` callbacks. While standard ERC20 `_mint()` does not trigger callbacks (no `_beforeTokenTransfer` hook in OZ v5), this is prudent defense-in-depth.

- **IOmniCoinMintable:** Custom interface extending `IERC20` with `mint(address, uint256)`. This matches OmniCoin.sol's `mint` function signature exactly.

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
  |   |-- Calculate current epoch (block.timestamp / 3600)
  |   |-- If new epoch: reset epochMinted to 0
  |   |-- If epochMinted + amount > 100M XOM --> revert EpochRateLimitExceeded()
  |   |-- Increment epochMinted
  |
  |-- Pre-mint Supply Check
  |   |-- Read TOKEN.totalSupply()
  |   |-- Calculate remaining = MAX_SUPPLY - totalSupply()
  |   |-- If amount > remaining --> revert MaxSupplyExceeded()
  |
  |-- Execute Mint
  |   |-- TOKEN.mint(to, amount)  [typed interface call]
  |
  |-- Post-mint Assertion (TOCTOU guard)
  |   |-- Read TOKEN.totalSupply() again
  |   |-- If postMintSupply > MAX_SUPPLY --> revert SupplyCapViolated()
  |
  |-- Emit ControlledMint(to, amount, postMintSupply)
```

---

## Findings

### [M-01] No Two-Step Admin Transfer or Timelock Delay on Role Management

**Severity:** Medium
**Lines:** 4 (import), 39 (contract declaration), 136 (constructor)
**Status:** Carried forward from previous audit (was M-04)

**Description:**

MintController inherits `AccessControl` (basic) rather than `AccessControlDefaultAdminRules`. This means:

1. **Single-step admin transfer:** `grantRole(DEFAULT_ADMIN_ROLE, newAddress)` followed by `revokeRole(DEFAULT_ADMIN_ROLE, oldAddress)` completes instantly. If `newAddress` is wrong (typo, wrong checksum, contract that cannot call `grantRole`), admin access is permanently lost.

2. **No delay on role grants:** A compromised admin can instantly grant `MINTER_ROLE` to an attacker address and mint 100M XOM (one epoch) before anyone notices.

3. **Inconsistency with OmniCoin:** OmniCoin.sol uses `AccessControlDefaultAdminRules` with a 48-hour delay. MintController does not, creating an asymmetry where the wrapper has weaker admin protections than the underlying token.

The OmniTimelockController and EmergencyGuardian contracts exist in the ecosystem and are designed to manage exactly this kind of role administration. However, the MintController constructor grants `DEFAULT_ADMIN_ROLE` to `msg.sender` with no documentation requiring transfer to the timelock.

**Impact:** Single point of failure. A compromised admin key allows instant, unauthorized role grants. The rate limit bounds damage to 100M XOM/epoch, but over a weekend (48 epochs) that is 4.8 billion XOM.

**Recommendation:**

Option A (preferred): Replace `AccessControl` with `AccessControlDefaultAdminRules`:

```solidity
import {AccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

contract MintController is AccessControlDefaultAdminRules, Pausable, ReentrancyGuard {
    constructor(address token_)
        AccessControlDefaultAdminRules(48 hours, msg.sender)
    { ... }
}
```

Option B: Transfer `DEFAULT_ADMIN_ROLE` to `OmniTimelockController` in the deployment script and document this as a deployment requirement in NatSpec.

---

### [M-02] PAUSER_ROLE Can Both Pause and Unpause -- Asymmetric Risk

**Severity:** Medium
**Lines:** 208-218

**Description:**

Both `pause()` and `unpause()` require only `PAUSER_ROLE`:

```solidity
function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
```

The design intent of separating `PAUSER_ROLE` from `DEFAULT_ADMIN_ROLE` is that a hot wallet can quickly halt minting during emergencies. However, granting `unpause()` to the same role means a compromised pauser key can also undo an emergency pause initiated by a legitimate guardian.

The EmergencyGuardian contract (deployed 2026-02-26) follows a stricter pattern: guardians can pause but cannot unpause. Unpausing requires going through the timelock/governance process, ensuring that the pause is lifted only after proper investigation.

**Impact:** If the `PAUSER_ROLE` holder's key is compromised, the attacker can unpause minting that was legitimately paused during a security incident. Combined with a compromised `MINTER_ROLE` key, this defeats the emergency stop mechanism.

**Recommendation:**

Restrict `unpause()` to `DEFAULT_ADMIN_ROLE` (which should be the timelock):

```solidity
function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }
```

This matches the asymmetric security model: pausing is a fast emergency action (hot wallet), unpausing is a deliberate governance action (timelock/multisig).

---

### [M-03] Epoch Rate Limit Uses Storage Variables Instead of Mapping -- State Confusion Risk

**Severity:** Medium
**Lines:** 74-77, 167-177

**Description:**

The epoch rate limiting uses two storage variables:

```solidity
uint256 public currentEpoch;
uint256 public epochMinted;
```

When a new epoch begins, `epochMinted` is reset to 0 (line 172). This means the `epochMinted` value only reflects the current epoch's usage -- historical epoch data is lost. While this is gas-efficient, it introduces a subtle issue:

The `remainingInCurrentEpoch()` view function (line 249-256) reads `currentEpoch` and `epochMinted` but these values may be stale if no `mint()` call has occurred in the current epoch. In that case, `currentEpoch` points to a past epoch and `epochMinted` shows that past epoch's usage. The function handles this correctly (returning `MAX_MINT_PER_EPOCH` if epoch differs), but external integrations reading `epochMinted` directly via the public getter will see stale data without context.

More critically, the epoch calculation `block.timestamp / EPOCH_DURATION` (line 169) uses integer division. If `block.timestamp` is manipulated by a miner/validator (Avalanche validators have limited timestamp flexibility, but the contract should not assume this), the epoch boundary could be shifted. On Avalanche C-Chain, validators can set timestamps within a few seconds of wall-clock time, so this is low risk in practice. However, the `not-rely-on-time` solhint directive is appropriately suppressed.

**Impact:** Off-chain integrations may misinterpret stale `epochMinted` values. The epoch-boundary manipulation risk is mitigated by Avalanche's consensus, but the pattern is fragile for chains with weaker timestamp guarantees.

**Recommendation:**

1. Add NatSpec to `currentEpoch` and `epochMinted` public variables warning that values may be stale:

```solidity
/// @notice Current epoch number (block.timestamp / EPOCH_DURATION)
/// @dev May be stale if no mint() called this epoch. Use remainingInCurrentEpoch() for accurate data.
uint256 public currentEpoch;
```

2. Consider adding a `currentEpochInfo()` view function that returns both the actual current epoch and the accurate remaining amount, to prevent misuse of the raw storage variables:

```solidity
function currentEpochInfo() external view returns (uint256 epoch, uint256 minted, uint256 remaining) {
    epoch = block.timestamp / EPOCH_DURATION;
    if (epoch == currentEpoch) {
        minted = epochMinted;
        remaining = MAX_MINT_PER_EPOCH > epochMinted ? MAX_MINT_PER_EPOCH - epochMinted : 0;
    } else {
        minted = 0;
        remaining = MAX_MINT_PER_EPOCH;
    }
}
```

---

### [L-01] ControlledMint Event Indexes Both `amount` and `newTotalSupply` -- Limited Indexing Utility

**Severity:** Low
**Lines:** 87-91

**Description:**

The `ControlledMint` event indexes all three parameters:

```solidity
event ControlledMint(
    address indexed to,
    uint256 indexed amount,
    uint256 indexed newTotalSupply
);
```

EVM topics are limited to 3 indexed parameters (plus the event signature topic). Indexing `uint256` values like `amount` and `newTotalSupply` is unusual because:

1. **`uint256` indexed values are stored as `keccak256(value)`** -- they cannot be recovered from the log topic alone. The raw value is NOT stored in the indexed topic; only its hash is.
2. Log filtering by exact `amount` or `newTotalSupply` is rarely useful (unlike filtering by `to` address).
3. The actual `amount` and `newTotalSupply` values are lost from the non-indexed data section, making it impossible for off-chain indexers to read these values from event logs without the transaction receipt's input data.

**Impact:** Off-chain indexers (block explorer, analytics, OmniEventIndexer) cannot directly read `amount` or `newTotalSupply` from the event data field -- they would need to decode the indexed topics (which are hashed) or reconstruct from transaction input. This breaks standard event parsing patterns.

**Recommendation:**

Only index the `to` address. Keep `amount` and `newTotalSupply` as non-indexed data:

```solidity
event ControlledMint(
    address indexed to,
    uint256 amount,
    uint256 newTotalSupply
);
```

---

### [L-02] No Batch Minting Capability

**Severity:** Low
**Lines:** N/A (missing feature)
**Status:** Carried forward from previous audit (was L-02)

**Description:**

Block reward distribution requires multiple mint calls per block: staking pool allocation, ODDAO share, and block producer reward. At 2-second block intervals, this amounts to ~129,600+ individual `mint()` transactions per day. Each call pays full overhead: role check, reentrancy guard, pause check, epoch calculation, two `totalSupply()` reads, and event emission.

A `batchMint()` function could aggregate these into a single transaction with one role check, one reentrancy guard entry, one epoch update, and one post-mint assertion.

**Impact:** Higher gas costs for validators. On Avalanche C-Chain, gas costs are low, so the financial impact is minimal. However, it increases block space consumption and validator workload.

**Recommendation:**

Consider adding a batch mint function:

```solidity
function batchMint(
    address[] calldata recipients,
    uint256[] calldata amounts
) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused {
    if (recipients.length != amounts.length) revert ArrayLengthMismatch();
    if (recipients.length > 10) revert TooManyRecipients();

    uint256 totalAmount;
    for (uint256 i = 0; i < recipients.length; ++i) {
        totalAmount += amounts[i];
    }

    // Single epoch check for aggregate amount
    // Single pre-mint supply check for aggregate amount
    // Loop: TOKEN.mint(recipients[i], amounts[i])
    // Single post-mint assertion
}
```

---

### [I-01] Constructor Does Not Verify TOKEN Is a Contract

**Severity:** Informational
**Lines:** 131-139

**Description:**

The constructor checks `token_ != address(0)` but does not verify that `token_` contains code (i.e., is a deployed contract). If MintController is deployed with a not-yet-deployed token address (e.g., in a CREATE2 predictive deployment), `TOKEN.mint()` would silently succeed (in Solidity 0.8.24, calls to EOAs via interfaces revert with empty returndata, so this is actually caught). However, there is no explicit contract existence check.

In practice, the typed `IOmniCoinMintable` interface call will revert on a non-contract address because the EVM returns empty data for calls to EOAs, which the ABI decoder rejects. This is a defense provided by the compiler, not by explicit contract logic.

**Recommendation:**

Acceptable as-is. The typed interface provides implicit protection. If explicit validation is desired:

```solidity
if (token_.code.length == 0) revert InvalidAddress();
```

---

### [I-02] MAX_SUPPLY Not Cross-Validated Against Token Contract

**Severity:** Informational
**Lines:** 51
**Status:** Carried forward from previous audit (was I-01)

**Description:**

MintController defines `MAX_SUPPLY = 16_600_000_000e18` as a hardcoded constant. OmniCoin.sol also defines `MAX_SUPPLY = 16_600_000_000 * 10 ** 18`. These values currently match. However, if either contract is redeployed with a different cap, MintController would enforce a stale value without any runtime detection.

**Recommendation:**

Consider adding a constructor-time cross-validation:

```solidity
// In constructor, after setting TOKEN:
uint256 tokenCap = IOmniCoinMintable(token_).MAX_SUPPLY();
if (tokenCap != MAX_SUPPLY) revert CapMismatch(tokenCap, MAX_SUPPLY);
```

This requires adding `function MAX_SUPPLY() external view returns (uint256);` to `IOmniCoinMintable`. The benefit is deployment-time detection of cap mismatches.

---

### [I-03] Test Coverage Gaps for New Features

**Severity:** Informational
**Lines:** N/A (test file)
**File:** `Coin/test/MintController.test.js`

**Description:**

The current test suite (14 tests, all passing) covers deployment, view functions, basic minting, supply cap enforcement, and role management. However, several features added since the previous audit lack dedicated test coverage:

1. **Pause/Unpause:** No tests verify that `mint()` reverts when paused, that `pause()` requires `PAUSER_ROLE`, or that non-pausers cannot pause/unpause.

2. **Epoch Rate Limiting:** No tests directly verify:
   - Minting up to `MAX_MINT_PER_EPOCH` succeeds within one epoch
   - Minting above `MAX_MINT_PER_EPOCH` reverts with `EpochRateLimitExceeded`
   - Epoch rollover correctly resets the counter
   - `remainingInCurrentEpoch()` returns accurate values

3. **Post-mint TOCTOU Assertion:** No test verifies the `SupplyCapViolated` error path. This is difficult to trigger in a standard test environment (requires concurrent minting bypassing MintController), but should at minimum be documented as a known untested path.

4. **ReentrancyGuard:** No test attempts reentrant calls.

5. **PAUSER_ROLE in constructor:** No test verifies the deployer receives `PAUSER_ROLE`.

**Recommendation:**

Add test cases for the above scenarios. The epoch rate limit tests are straightforward using Hardhat's `time.increase()`. Example:

```javascript
describe("Epoch Rate Limiting", function () {
    it("should revert when exceeding per-epoch limit", async function () {
        const amount = ethers.parseEther("100000001"); // 100M + 1
        await expect(
            controller.connect(minter).mint(recipient.address, amount)
        ).to.be.revertedWithCustomError(controller, "EpochRateLimitExceeded");
    });

    it("should reset limit in a new epoch", async function () {
        await controller.connect(minter).mint(recipient.address, ethers.parseEther("99000000"));
        await time.increase(3601); // advance past epoch boundary
        // Should succeed in new epoch
        await controller.connect(minter).mint(recipient.address, ethers.parseEther("99000000"));
    });
});

describe("Pausable", function () {
    it("should revert mint when paused", async function () {
        await controller.connect(deployer).pause();
        await expect(
            controller.connect(minter).mint(recipient.address, ethers.parseEther("100"))
        ).to.be.revertedWithCustomError(controller, "EnforcedPause");
    });
});
```

---

## Remediation Status from Previous Audit (2026-02-21)

| ID | Finding | Severity | Status | Verification |
|----|---------|----------|--------|--------------|
| H-01 | TOCTOU race condition on totalSupply() | High | **FIXED** | Post-mint assertion at line 195-198 reads `TOKEN.totalSupply()` after mint and reverts if `> MAX_SUPPLY`. Event now emits actual post-mint supply. |
| M-01 | Unsafe low-level call | Medium | **FIXED** | `IOmniCoinMintable` typed interface at line 16-21 provides compile-time verification. Call at line 190 uses `TOKEN.mint(to, amount)` instead of `address.call()`. |
| M-02 | No emergency pause | Medium | **FIXED** | Contract inherits `Pausable` (line 7, 39). `PAUSER_ROLE` (line 48) controls `pause()` and `unpause()` (lines 208-218). `mint()` has `whenNotPaused` modifier (line 163). |
| M-03 | No rate limiting | Medium | **FIXED** | Per-epoch rate limit at lines 167-177. `MAX_MINT_PER_EPOCH = 100_000_000e18` (line 60). Epoch duration is 1 hour (line 54). Counter resets on epoch boundary. |
| M-04 | No timelock on admin | Medium | **OPEN** | MintController still uses basic `AccessControl`. See M-01 of this audit. Mitigation exists via deployment procedures (transfer admin to OmniTimelockController), but this is not enforced in contract code. |
| L-01 | Event emits calculated supply | Low | **FIXED** | Event now emits `postMintSupply` (actual post-mint value from `TOKEN.totalSupply()`) at line 200. |
| L-02 | No batch minting | Low | **OPEN** | See L-02 of this audit. |
| L-03 | Immutable TOKEN -- no migration path | Low | **ACCEPTED** | Intentional design decision. Immutability provides security guarantee. |
| I-01 | MAX_SUPPLY not verified against token | Info | **OPEN** | See I-02 of this audit. |

---

## Static Analysis Results

### Solhint

```
0 errors, 0 warnings (contract-specific)
```

Only global config warnings for non-existent rules (`contract-name-camelcase`, `event-name-camelcase`) -- not related to MintController code.

### Compiler (solc 0.8.24)

```
0 errors, 0 warnings
```

Contract compiles cleanly with no compiler warnings.

### Manual Pattern Checks

| Pattern | Status | Notes |
|---------|--------|-------|
| Reentrancy | PASS | `nonReentrant` on `mint()` |
| Integer overflow | PASS | Solidity 0.8.24 checked arithmetic; `epochMinted + amount` cannot overflow `uint256` |
| Access control | PASS | `onlyRole(MINTER_ROLE)` on `mint()`; `onlyRole(PAUSER_ROLE)` on `pause()`/`unpause()` |
| Frontrunning | PASS | Rate limiting bounds damage; post-mint assertion catches any cap violation |
| Denial of service | PASS | No unbounded loops; no external calls that could revert unexpectedly (TOKEN.mint has role check) |
| Timestamp dependence | ACCEPTABLE | `block.timestamp / EPOCH_DURATION` for rate limiting; Avalanche validators have limited timestamp control |
| tx.origin usage | PASS | Not used |
| Unchecked return values | PASS | Typed interface call reverts on failure |
| Self-destruct | PASS | Not present; `selfdestruct` is deprecated in 0.8.24 |

---

## Access Control Map

| Role | Functions | Holders (intended) | Risk Level |
|------|-----------|-------------------|------------|
| DEFAULT_ADMIN_ROLE | `grantRole()`, `revokeRole()` | OmniTimelockController | 8/10 |
| MINTER_ROLE | `mint()` | BlockRewardService, BonusService, OmniRewardManager | 7/10 |
| PAUSER_ROLE | `pause()`, `unpause()` | EmergencyGuardian (hot wallet) | 4/10 |
| (public) | `remainingMintable()`, `currentSupply()`, `maxSupplyCap()`, `remainingInCurrentEpoch()` | Anyone | 0/10 |

### Centralization Risk Assessment

**Rating: 6/10** (improved from 9/10 in prior audit)

The addition of `PAUSER_ROLE` separation and rate limiting significantly reduces centralization risk:

- **Compromised MINTER_ROLE:** Damage bounded to 100M XOM per epoch (1 hour). Pauser can halt immediately.
- **Compromised PAUSER_ROLE:** Can pause minting (DoS) or unpause after legitimate pause. Cannot mint tokens.
- **Compromised DEFAULT_ADMIN_ROLE:** Can grant MINTER_ROLE and then mint. Rate limit still applies. However, instant role grants (no timelock) mean attacker has continuous access until detected.

**Maximum single-key damage scenario:** Compromised admin grants MINTER_ROLE, mints 100M XOM, waits 1 hour, mints another 100M, repeating until detected and paused. Over 24 hours: 2.4 billion XOM. This is significant but bounded, compared to the unlimited minting possible in the previous version.

---

## Gas Analysis

| Function | Estimated Gas | Notes |
|----------|--------------|-------|
| `mint()` (first in epoch) | ~85,000 | Two SSTORE (epoch reset + epochMinted), two external calls (totalSupply + mint), event |
| `mint()` (same epoch) | ~65,000 | One SSTORE (epochMinted update), skip epoch reset, two external calls, event |
| `pause()` | ~28,000 | One SSTORE (paused flag) |
| `unpause()` | ~28,000 | One SSTORE (paused flag) |
| `remainingMintable()` | ~2,600 | One external call (totalSupply) |
| `remainingInCurrentEpoch()` | ~2,400 | Two SLOAD (currentEpoch, epochMinted) |

Gas costs are reasonable for Avalanche C-Chain where base fee is low.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance to MintController |
|---------|------|------|-----------------------------|
| Cover Protocol | 2020-12 | N/A | Unlimited minting via logic flaw -- MintController's rate limit and cap prevent this class |
| DAO Maker | 2021-09 | $4M | Unauthorized minting via compromised key -- rate limit bounds damage per epoch |
| Ronin Network | 2022-03 | $624M | Compromised admin keys -- M-01 (no timelock) is the remaining gap |
| Harmony Bridge | 2022-06 | $100M | Compromised multisig -- PAUSER_ROLE separation helps here |
| VTVL | 2022-09 | N/A | Supply cap bypass -- triple guard (pre, token, post) prevents this |
| SafeMoon | 2023-03 | $8.9M | Unprotected minting -- MINTER_ROLE prevents unauthorized minting |

---

## Remediation Priority

| Priority | Finding | Severity | Effort | Impact |
|----------|---------|----------|--------|--------|
| 1 | M-01: Use AccessControlDefaultAdminRules | Medium | Low | Prevents permanent admin loss and adds delay to role changes |
| 2 | M-02: Restrict unpause() to DEFAULT_ADMIN_ROLE | Medium | Trivial | Prevents compromised pauser from undoing emergency pause |
| 3 | L-01: Fix indexed event parameters | Low | Trivial | Enables off-chain indexers to read amount/supply from logs |
| 4 | M-03: Add NatSpec for stale epoch state | Medium | Low | Prevents off-chain integration errors |
| 5 | I-03: Add test coverage for pause/epoch/reentrancy | Info | Medium | Validates remediations from prior audit |
| 6 | L-02: Add batch minting | Low | Medium | Reduces gas overhead for block reward distribution |
| 7 | I-02: Cross-validate MAX_SUPPLY in constructor | Info | Low | Deployment-time cap mismatch detection |
| 8 | I-01: Verify TOKEN is a contract | Info | Trivial | Explicit validation (implicit protection already exists) |

---

## Test Results

```
MintController
  Deployment
    ✔ should set the token address correctly (4448ms)
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

14 passing (5s)
```

---

## Conclusion

MintController has been substantially hardened since the 2026-02-21 audit. The four previously identified High/Medium findings (TOCTOU race, unsafe low-level call, missing pause, missing rate limit) have all been properly remediated. The contract now provides robust, multi-layered protection for the XOM supply cap.

The remaining findings are Medium severity at worst. The most actionable improvement is upgrading from `AccessControl` to `AccessControlDefaultAdminRules` (M-01) to match OmniCoin's own admin protection level. The asymmetric pause/unpause authority (M-02) is a one-line fix. The indexed event parameters (L-01) should be corrected before deployment to avoid breaking off-chain indexers.

Overall, MintController is well-suited for its purpose as the sole minting chokepoint for the OmniCoin ecosystem. The combination of immutable supply cap, per-epoch rate limiting, post-mint assertion, reentrancy guard, and emergency pause provides defense-in-depth appropriate for a contract governing ~12.47 billion XOM in future emissions.

---

*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced with exploit database cross-referencing*
*Previous audit: MintController-audit-2026-02-21.md (1H, 4M, 3L, 1I)*
*Reference data: 58 vulnerability patterns, 166 Cyfrin checks, 640+ DeFiHackLabs incidents*
