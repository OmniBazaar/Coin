# Security Audit Report: PrivateOmniCoin (Round 6 -- Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Multi-Pass Pre-Mainnet)
**Contract:** `Coin/contracts/PrivateOmniCoin.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 968
**Upgradeable:** Yes (UUPS with ossification)
**Handles Funds:** Yes (ERC20 token with privacy-preserving balances via COTI V2 MPC)
**OpenZeppelin Version:** 5.x (upgradeable contracts)
**Dependencies:** `MpcCore.sol` (COTI V2 MPC library), `OmniPrivacyBridge.sol` (fee collection and XOM locking)
**Test Suite:** `Coin/test/PrivateOmniCoin.test.js`
**Previous Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26)
**Static Analysis:** Slither output not available; Mythril output not available

---

## Executive Summary

PrivateOmniCoin is a UUPS-upgradeable ERC20 token (pXOM) providing privacy-preserving balances using COTI V2's MPC (Multi-Party Computation) garbled circuits. Users convert public pXOM to encrypted private balances via `convertToPrivate()`, transfer privately via `privateTransfer()`, and convert back via `convertToPublic()`. The contract acts as the token layer; fee collection (0.5%) is handled by the separate `OmniPrivacyBridge` contract.

This Round 6 audit is a comprehensive pre-mainnet security review covering OWASP SC Top 10, business logic, access control, DeFi exploit patterns, Cyfrin checklist items, and an adversarial hacker review. The contract has undergone significant improvements since Rounds 1 and 3:

**Round 3 Remediation Status:**
- **M-01 (Unchecked MPC arithmetic):** FIXED -- All MPC arithmetic now uses `checkedAdd()`/`checkedSub()` which revert on overflow/underflow via COTI's `checkOverflow()` mechanism.
- **M-02 (Fee constant mismatch):** FIXED -- `PRIVACY_FEE_BPS` updated from 30 to 50 (0.5%). All NatSpec references corrected.
- **M-03 (Scaling dust destroyed):** FIXED -- Only the cleanly-scaled portion (`scaledAmount * PRIVACY_SCALING_FACTOR`) is now burned. Sub-1e12 dust remains in the user's public balance.
- **L-01 (No MAX_SUPPLY on emergency recovery):** FIXED -- `emergencyRecoverPrivateBalance()` now enforces `MAX_SUPPLY` check before `_mint`.
- **L-02 (convertToPublic ordering):** FIXED -- `convertToPublic()` now also has the `MAX_SUPPLY` defense-in-depth check.
- **L-03 (Function ordering):** No longer flagged in current layout.
- **I-01 (Vestigial feeRecipient):** FIXED -- Now marked with `VESTIGIAL` in NatSpec.
- **I-02 (Event over-indexing):** FIXED -- `ConvertedToPrivate` event now has only `address indexed user, uint256 publicAmount` (fee parameter removed).
- **I-03 (Unused newImplementation):** FIXED -- `solhint-disable-line no-unused-vars` comment added.
- **I-04 (Storage gap):** Updated -- gap now accounts for `privacyDisableScheduledAt` (5 sequential slots, 45 gap).

**New features since Round 3:** ATK-H07 7-day timelock for privacy disable, ATK-H08 shadow ledger update on `privateTransfer`, ATK-H05 owner-only balance decryption, `PrivateLedgerUpdated` event.

**Round 6 findings:** The contract is in strong shape for mainnet. This audit found **0 Critical**, **0 High**, **1 Medium**, **4 Low**, and **6 Informational** findings.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 4 |
| Informational | 6 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | PrivateLedgerUpdated event emits plaintext transfer amount -- defeats MPC privacy | **FIXED** |

---

## Round 3 Remediation Verification

| Round 3 ID | Severity | Status | Verification |
|------------|----------|--------|--------------|
| M-01 | Medium | FIXED | All six MPC arithmetic sites now use `checkedAdd`/`checkedSub`. Lines 435, 446, 488, 496, 577, 585. Confirmed against `MpcCore.checkRes64()` which calls `checkOverflow()` -> `require(decrypt(not(bit)) == true, "overflow error")`. |
| M-02 | Medium | FIXED | `PRIVACY_FEE_BPS = 50` (line 121). NatSpec at lines 54-57 correctly states "bridge charges 0.5%". Contract-level documentation is consistent with `OmniPrivacyBridge.PRIVACY_FEE_BPS = 50`. |
| M-03 | Medium | FIXED | Lines 421-424: `actualBurnAmount = scaledAmount * PRIVACY_SCALING_FACTOR`. Only the scaled portion is burned; dust stays in user's public balance. Event at line 453 emits `actualBurnAmount`. |
| L-01 | Low | FIXED | Lines 520-522: `if (totalSupply() + publicAmount > MAX_SUPPLY) revert ExceedsMaxSupply()` in `convertToPublic()`. Lines 730-732: same check in `emergencyRecoverPrivateBalance()`. |
| L-02 | Low | FIXED | The `MAX_SUPPLY` check at line 520 occurs before `_mint` at line 525 in `convertToPublic()`, ensuring revert before state inconsistency. |
| L-03 | Low | FIXED | Function ordering is now consistent in current layout. |
| I-01 | Info | FIXED | Lines 156-162: `feeRecipient` marked `VESTIGIAL`. Lines 617-629: `setFeeRecipient` NatSpec states "Retained solely for storage layout compatibility". |
| I-02 | Info | FIXED | Lines 213-217: `event ConvertedToPrivate(address indexed user, uint256 publicAmount)`. Fee parameter removed. `publicAmount` no longer indexed (correct). |
| I-03 | Info | FIXED | Line 913: `// solhint-disable-line no-unused-vars` on `newImplementation`. |
| I-04 | Info | FIXED | Lines 189-203: Storage gap comment now correctly counts 5 sequential slots (`totalPrivateSupply`, `feeRecipient`, `privacyEnabled`, `_ossified`, `privacyDisableScheduledAt`). Gap = 50 - 5 = 45. Mappings excluded per OZ convention. |

---

## PASS 2A -- OWASP Smart Contract Top 10

### SC01: Reentrancy

**Status: PASS**

`ReentrancyGuardUpgradeable` is inherited (line 83) and `nonReentrant` is applied to all three state-mutating privacy functions:
- `convertToPrivate()` (line 410)
- `convertToPublic()` (line 472)
- `privateTransfer()` (line 557)

All MPC precompile calls (`MpcCore.onBoard`, `offBoard`, `setPublic64`, `checkedAdd`, `checkedSub`, `ge`, `decrypt`) are internal library calls to the COTI precompile at address `0x64`. These are static calls to a system precompile, not external contract calls, so they cannot trigger reentrancy via callback. The `nonReentrant` guard is defense-in-depth.

The `_mint` and `_burn` calls are internal OZ functions that do not make external calls. The `_update` override (lines 933-942) only calls `super._update` (ERC20PausableUpgradeable), which applies the pause check and then calls `ERC20Upgradeable._update` -- no external calls.

**Verdict:** Reentrancy is well-guarded. No MPC callback vector exists.

### SC02: Integer Overflow/Underflow

**Status: PASS (with note)**

**Solidity 0.8.24 checked arithmetic:** All plaintext arithmetic is protected by default. Key operations:
- `scaledAmount * PRIVACY_SCALING_FACTOR` (lines 423-424, 503-504, 727): Cannot overflow because `scaledAmount <= type(uint64).max` (18,446,744,073,709,551,615) and `PRIVACY_SCALING_FACTOR = 1e12`, so the product is at most ~1.84e31, well within uint256.
- `privateDepositLedger[msg.sender] += scaledAmount` (line 451): Uses checked arithmetic. Could theoretically overflow uint256 after 2^192 deposits, which is physically impossible.
- `privateDepositLedger[msg.sender] -= transferAmount` (line 596): Protected by the `>=` check at line 595.

**MPC encrypted arithmetic:** All six sites now use `checkedAdd`/`checkedSub` (lines 435, 446, 488, 496, 577, 585). These call `MpcCore.checkRes64()` -> `checkOverflow()` which reverts with `"overflow error"` on overflow/underflow. Confirmed by reading MpcCore.sol lines 145-158, 184-189.

**Verdict:** Both plaintext and encrypted arithmetic are overflow-safe.

### SC03: Timestamp Dependence

**Status: PASS**

`PRIVACY_DISABLE_DELAY = 7 days` (line 141) is used in `proposePrivacyDisable()` (line 658) and `executePrivacyDisable()` (line 675). The 7-day window is large enough that miner timestamp manipulation (typically bounded to ~15 seconds) cannot meaningfully affect the timelock. The `solhint-disable-next-line not-rely-on-time` comments at lines 657 and 674 acknowledge and suppress the warning appropriately.

`_detectPrivacyAvailability()` uses `block.chainid` (line 960), not `block.timestamp`. No timestamp dependence there.

**Verdict:** Timestamp usage is appropriate for a 7-day timelock.

### SC04: Access Control

**Status: PASS (with findings -- see PASS 2C below)**

Four roles are defined: `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`, `BURNER_ROLE`, `BRIDGE_ROLE`. All admin functions use `onlyRole()` modifiers. See PASS 2C for detailed role mapping and findings.

### SC05: Front-Running

**Status: PASS (with informational note)**

- `convertToPrivate()`: Burns the caller's own tokens and credits their own private balance. No front-running vector -- the caller is the sole beneficiary.
- `convertToPublic()`: Operates on the caller's own encrypted balance. The `encryptedAmount` parameter is an MPC garbled circuit value, not a plaintext value, so front-runners cannot determine the amount to copy.
- `privateTransfer()`: The `encryptedAmount` is an MPC value. A front-runner cannot construct a valid `gtUint64` without access to the MPC precompile's garbled circuit state.

**Privacy disable front-running:** The 7-day timelock (ATK-H07) gives users ample time to exit private positions before emergency recovery becomes possible. See L-01 for a related nuance.

**ossify() front-running:** See L-03 below.

**Verdict:** No economically exploitable front-running vectors identified.

### SC06: Denial of Service

**Status: PASS**

- No unbounded loops.
- No external calls that could be used for griefing (MPC precompile calls are system-level).
- The `emergencyRecoverPrivateBalance()` function operates on a single user at a time, not in batches, so it cannot be DoS'd via array length manipulation.
- The `privateDepositLedger` mapping is per-address, so no storage collision DoS.

**Verdict:** No DoS vectors identified.

### SC07: Bad Randomness

**Status: N/A**

No randomness is used in this contract. MPC operations use COTI's garbled circuits, which provide cryptographic privacy guarantees, not randomness.

### SC08: Race Conditions

**Status: PASS**

The `to == msg.sender` check in `privateTransfer()` (line 562) prevents same-slot read/write races on `encryptedBalances`. For different addresses, sender and recipient balances occupy different storage slots, so concurrent MPC operations on different users cannot interfere.

The `nonReentrant` modifier prevents recursive calls within the same transaction.

**Verdict:** No race conditions identified.

### SC09: Unhandled Exceptions

**Status: PASS**

- `MpcCore.decrypt()` returns a value (uint64 or bool); the contract checks all return values.
- `MpcCore.checkedAdd()`/`checkedSub()` revert on overflow via `require(decrypt(not(bit)) == true, "overflow error")` -- this is a checked exception path.
- `_burn()` and `_mint()` revert on insufficient balance or zero address (OZ built-in checks).
- All custom errors are explicit and cover all revert conditions.

**Verdict:** All exceptions are handled.

### SC10: Known Vulnerabilities

**Status: PASS**

- Solidity 0.8.24: No known compiler vulnerabilities at this version.
- OpenZeppelin 5.x upgradeable: Standard, well-audited library.
- UUPS pattern: Properly implemented with `_disableInitializers()` in constructor and `initializer` modifier on `initialize()`.
- No delegatecall to untrusted contracts.
- No `selfdestruct`.

**Verdict:** No known vulnerability patterns present.

---

## PASS 2B -- Business Logic Verification

### Privacy Conversion: XOM to pXOM (18 to 6 Decimal Scaling)

**Lines 408-454**

Flow:
1. Check `privacyEnabled` (line 411)
2. Scale: `scaledAmount = amount / PRIVACY_SCALING_FACTOR` (line 415)
3. Validate: `scaledAmount == 0` -> revert (line 416); `scaledAmount > type(uint64).max` -> revert (line 417-419)
4. M-03 fix: `actualBurnAmount = scaledAmount * PRIVACY_SCALING_FACTOR` (line 423-424)
5. Burn only the cleanly-scaled portion (line 425)
6. Create MPC encrypted value: `setPublic64(uint64(scaledAmount))` (line 428-429)
7. Checked add to user's encrypted balance (lines 432-439)
8. Checked add to total private supply (lines 443-448)
9. Update shadow ledger (line 451)
10. Emit event (line 453)

**Verification:** Correct. The `uint64(scaledAmount)` cast at line 429 is safe because the check at line 417-419 guarantees `scaledAmount <= type(uint64).max`.

### Dust Handling (M-03 Fix)

**Lines 421-425**

```solidity
uint256 actualBurnAmount = scaledAmount * PRIVACY_SCALING_FACTOR;
_burn(msg.sender, actualBurnAmount);
```

Example: User converts 1,000,000,000,000,000,001 wei (1.000000000000000001 XOM):
- `scaledAmount` = 1,000,000,000,000,000,001 / 1e12 = 1,000,000 (truncated)
- `actualBurnAmount` = 1,000,000 * 1e12 = 1,000,000,000,000,000,000 (1.0 XOM exactly)
- Dust remaining in public balance: 1 wei
- Private balance credited: 1,000,000 (6-decimal)

**Verification:** Correct. Dust is preserved in the user's public balance.

### No Fee in This Contract

**Verification:** Confirmed. No fee calculation or deduction in `convertToPrivate()`, `convertToPublic()`, or `privateTransfer()`. The `PRIVACY_FEE_BPS = 50` constant is retained for external reference only. Fee is charged by `OmniPrivacyBridge.convertXOMtoPXOM()` at line 323-324 of that contract.

### Shadow Ledger for Emergency Recovery

**Lines 173, 451, 507-517, 592-603, 713-737**

The shadow ledger (`privateDepositLedger`) tracks plaintext balances for emergency recovery when MPC is unavailable:

- **convertToPrivate:** Increments ledger by `scaledAmount` (line 451). Correct.
- **convertToPublic:** Decrements ledger by `plainAmount` with underflow protection (lines 507-517). If ledger < plainAmount (due to received transfers), zeros it out instead of reverting. Correct.
- **privateTransfer (ATK-H08):** Decrypts the transfer amount (line 592), debits sender's ledger (lines 595-602), credits recipient's ledger (line 603). Emits `PrivateLedgerUpdated` event. Correct.
- **emergencyRecoverPrivateBalance:** Reads ledger, zeros it, scales up, enforces MAX_SUPPLY, mints. Correct.

**Finding:** See M-01 below regarding shadow ledger inflation through transfer sequences.

### MPC Overflow Protection (checkedAdd/checkedSub)

**Verification:** All six MPC arithmetic sites use checked variants. The `checkRes64()` function (MpcCore.sol line 184) calls `checkOverflow()` (line 145) which does `require(decrypt(not(bit)) == true, "overflow error")`. This reverts the transaction if the overflow bit is set by the MPC precompile's `CheckedAdd`/`CheckedSub` operations.

### MAX_SUPPLY Enforcement on All Mint Paths

**Mint paths in this contract:**
1. `mint()` (line 750): Checks `totalSupply() + amount > MAX_SUPPLY`. Correct.
2. `convertToPublic()` (line 520): Checks `totalSupply() + publicAmount > MAX_SUPPLY`. Correct.
3. `emergencyRecoverPrivateBalance()` (line 730): Checks `totalSupply() + publicAmount > MAX_SUPPLY`. Correct.
4. `initialize()` (line 375): Mints `INITIAL_SUPPLY = 1B`. This is less than `MAX_SUPPLY = 16.6B`. Correct.

**No other `_mint` calls exist.**

### INITIAL_SUPPLY of 1 Billion

**Lines 107-109:** `uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;`

**Business Logic Question:** OmniCoin (XOM) has `INITIAL_SUPPLY = 16,600,000,000 * 10**18` (16.6 billion, all pre-minted). PrivateOmniCoin (pXOM) has 1 billion pre-minted at genesis. This discrepancy is intentional:

- pXOM is a separate token, not a 1:1 pre-minted mirror of XOM.
- The 1 billion pXOM genesis supply provides initial liquidity for privacy operations.
- Additional pXOM is minted by the bridge when users convert XOM to pXOM.
- The `MAX_SUPPLY = 16.6B` ensures total pXOM can never exceed the total XOM supply.

**Verification:** The 1B initial supply is a design choice, not a bug. However, see I-03 below for documentation clarity.

### uint64 Overflow Boundary for Total Private Supply

`totalPrivateSupply` is a `ctUint64` (line 154), which under the hood is a `uint256` wrapper containing an encrypted uint64 value. The MPC precompile treats it as a 64-bit integer. Maximum value: `type(uint64).max = 18,446,744,073,709,551,615`.

In 6-decimal precision, this represents ~18,446,744,073,709.551615 XOM (~18.4 trillion XOM). Since `MAX_SUPPLY` is 16.6 billion XOM and total private supply is a subset, the uint64 boundary at ~18.4 trillion will never be reached. Even converting the entire 16.6B XOM supply to private would only use `16,600,000,000,000,000` out of `18,446,744,073,709,551,615` -- about 90% of capacity.

**Verification:** uint64 is sufficient. The `checkedAdd` on total private supply (line 446) provides defense-in-depth.

### Emergency Recovery Limitations

**Lines 698-710 NatSpec:**
> Limitations: Only deposits made via convertToPrivate are recoverable. Amounts received via privateTransfer are NOT tracked in the shadow ledger and cannot be recovered this way.

**Post ATK-H08 fix:** This NatSpec is now **outdated**. Since the ATK-H08 fix, `privateTransfer` *does* update the shadow ledger (lines 592-603): it debits the sender and credits the recipient. Therefore, amounts received via `privateTransfer` *are* now tracked and *are* recoverable via `emergencyRecoverPrivateBalance`. See I-01 below.

---

## PASS 2C -- Access Control Mapping

### Role Definitions

| Role | Hash | Granted To | Purpose |
|------|------|------------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Deployer (initialize) | Admin functions, role management, upgrade authorization |
| `MINTER_ROLE` | `keccak256("MINTER_ROLE")` | Deployer, OmniPrivacyBridge | Mint public pXOM tokens |
| `BURNER_ROLE` | `keccak256("BURNER_ROLE")` | Deployer, OmniPrivacyBridge | Burn tokens from any address |
| `BRIDGE_ROLE` | `keccak256("BRIDGE_ROLE")` | Deployer, OmniPrivacyBridge | Currently unused in contract logic |

### Function Access Map

| Function | Access Control | Modifier |
|----------|---------------|----------|
| `convertToPrivate()` | Any user | `whenNotPaused`, `nonReentrant` |
| `convertToPublic()` | Any user | `whenNotPaused`, `nonReentrant` |
| `privateTransfer()` | Any user | `whenNotPaused`, `nonReentrant` |
| `decryptedPrivateBalanceOf()` | Account owner only | `msg.sender == account` check |
| `mint()` | `MINTER_ROLE` | `onlyRole` |
| `burnFrom()` | `BURNER_ROLE` | `onlyRole` |
| `setFeeRecipient()` | `DEFAULT_ADMIN_ROLE` | `onlyRole` |
| `enablePrivacy()` | `DEFAULT_ADMIN_ROLE` | `onlyRole` |
| `proposePrivacyDisable()` | `DEFAULT_ADMIN_ROLE` | `onlyRole` |
| `executePrivacyDisable()` | `DEFAULT_ADMIN_ROLE` | `onlyRole` |
| `cancelPrivacyDisable()` | `DEFAULT_ADMIN_ROLE` | `onlyRole` |
| `emergencyRecoverPrivateBalance()` | `DEFAULT_ADMIN_ROLE` | `onlyRole` |
| `pause()` | `DEFAULT_ADMIN_ROLE` | `onlyRole` |
| `unpause()` | `DEFAULT_ADMIN_ROLE` | `onlyRole` |
| `ossify()` | `DEFAULT_ADMIN_ROLE` | `onlyRole` |
| `_authorizeUpgrade()` | `DEFAULT_ADMIN_ROLE` | `onlyRole`, ossification check |

### Ossification Mechanism

**Lines 784-787:**
```solidity
function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _ossified = true;
    emit ContractOssified(address(this));
}
```

One-way, irreversible. Once set, `_authorizeUpgrade()` (line 919) reverts with `ContractIsOssified`. No `isOssified()` public getter exists -- see I-04 below.

### Privacy Disable Timelock (ATK-H07)

**Flow:**
1. Admin calls `proposePrivacyDisable()` -- sets `privacyDisableScheduledAt = block.timestamp + 7 days`
2. 7-day waiting period
3. Admin calls `executePrivacyDisable()` -- checks `block.timestamp >= privacyDisableScheduledAt`, sets `privacyEnabled = false`, clears schedule
4. Admin can cancel anytime via `cancelPrivacyDisable()` -- clears schedule

**Enable/Disable Asymmetry:** Enabling privacy is instant (`enablePrivacy()`). Disabling requires 7-day timelock. This is correct because:
- Enabling privacy does not put funds at risk.
- Disabling privacy enables `emergencyRecoverPrivateBalance()`, which could be used to exploit stale shadow ledger entries if users don't have time to exit.

**Finding:** See L-01 regarding propose/cancel griefing.

### BRIDGE_ROLE

**Observation:** `BRIDGE_ROLE` is defined (line 104) and granted during initialization (line 366), but no function in PrivateOmniCoin uses `onlyRole(BRIDGE_ROLE)`. The bridge interacts with this contract via `MINTER_ROLE` (to call `mint()`) and `BURNER_ROLE` (to call `burnFrom()`). See I-05 below.

---

## PASS 2D -- DeFi Exploit Patterns

### Attack 1: Front-Running Privacy Disable to Drain Before Recovery

**Scenario:** Admin proposes privacy disable. Attacker front-runs `executePrivacyDisable()` to convert private funds back to public before emergency recovery activates.

**Analysis:** This is not an exploit -- it is the intended behavior. The 7-day timelock exists precisely to give users time to `convertToPublic()` before privacy is disabled. Users who convert back keep their actual MPC-verified balance, which is correct. The shadow ledger is updated via `convertToPublic()` (lines 507-517), so recovered amounts decrease accordingly.

**Verdict:** Not exploitable. Working as designed.

### Attack 2: Shadow Ledger Manipulation via Convert-Transfer-Convert Sequence

**Scenario:** Alice converts 100 XOM to private (shadow ledger: Alice=100). Alice privately transfers 100 to Bob (shadow ledger: Alice=0, Bob=100). Bob converts 100 back to public (shadow ledger: Bob=0, public balance restored). If emergency recovery is triggered, neither Alice nor Bob has a shadow ledger balance to claim. No inflation.

**Alternative:** Alice converts 100 to private (ledger: Alice=100). Alice transfers 50 to Bob (ledger: Alice=50, Bob=50). Privacy is disabled. Admin recovers Alice (mints 50 * 1e12). Admin recovers Bob (mints 50 * 1e12). Total recovered: 100 XOM (matches the 100 XOM originally burned). No inflation.

**Deeper scenario -- partial transfers back:** Alice converts 100 to private (ledger: Alice=100). Alice transfers 50 to Bob (ledger: Alice=50, Bob=50). Bob converts 50 back to public (ledger: Bob=0). Alice's encrypted balance is now 50. Privacy disabled. Admin recovers Alice (mints 50). Total public mint via recovery = 50. Total public mint via Bob's convertToPublic = 50. Total = 100. Correct.

**Edge case -- transfers in excess of deposits:** Eve receives 200 via `privateTransfer` from multiple senders. Eve's ledger = 200 (credited at line 603). Eve converts all 200 back to public. The `convertToPublic` ledger debit (lines 507-517): `plainAmount = 200`, `privateDepositLedger[Eve] = 200`, so `200 >= 200` passes, ledger becomes 0. No inflation.

**Verdict:** The shadow ledger correctly tracks net balances through transfers since the ATK-H08 fix. No inflation vector found.

### Attack 3: Race Condition Between convertToPublic and privateTransfer

**Scenario:** Alice calls `convertToPublic(100)` and `privateTransfer(to=Bob, 100)` in the same block, both with the same encrypted amount representing her full balance.

**Analysis:** Both functions have `nonReentrant`. If called in separate transactions within the same block, they execute sequentially. The first to execute succeeds; the second reverts because the MPC `ge` check will fail (balance is now 0). The `checkedSub` provides additional defense-in-depth.

Even without `nonReentrant`, the EVM executes transactions sequentially within a block. The first transaction updates `encryptedBalances[msg.sender]` via `offBoard`, and the second transaction's `onBoard` reads the updated value.

**Verdict:** Not exploitable. Sequential EVM execution + nonReentrant + ge check + checkedSub provide multiple layers of protection.

### Attack 4: Abuse BRIDGE_ROLE to Mint Unlimited Tokens

**Analysis:** `BRIDGE_ROLE` has no minting capability in this contract. Minting requires `MINTER_ROLE`. However, the deployer initially holds all four roles. If the deployer retains `MINTER_ROLE`, they can mint up to `MAX_SUPPLY - totalSupply()`.

The `MAX_SUPPLY = 16.6B` cap prevents unlimited minting even with a compromised `MINTER_ROLE`. With `INITIAL_SUPPLY = 1B`, a compromised minter could mint up to 15.6B additional pXOM. This would not be backed by locked XOM in the bridge.

**Mitigation:** After deployment, `MINTER_ROLE` should be granted exclusively to the OmniPrivacyBridge contract and revoked from the deployer. The bridge enforces 1:1 XOM backing for all pXOM minted.

**Verdict:** Protected by MAX_SUPPLY cap. Operational security (role revocation) is critical. See L-02 below.

### Attack 5: Front-Run ossify() to Upgrade to Backdoored Implementation

**Scenario:** Admin announces intention to ossify. Attacker (who has somehow obtained `DEFAULT_ADMIN_ROLE` or the admin's key) front-runs the `ossify()` call with `upgradeToAndCall()` pointing to a malicious implementation.

**Analysis:** This requires the attacker to already have `DEFAULT_ADMIN_ROLE`, which is the strongest assumption. If the admin key is compromised, the attacker can do anything regardless of ossification.

In a multi-sig/timelock scenario: the `ossify()` and `upgradeToAndCall()` would both go through the same governance process. Front-running is only possible if there's a race between two separate governance proposals.

**Mitigation:** Use a timelock controller for the admin role. Execute ossification as the final governance action after all upgrades are complete. See L-03 below.

**Verdict:** Not a contract-level vulnerability. Operational procedure matter.

### Attack 6: Grief by Proposing/Cancelling Privacy Disable Repeatedly

**Scenario:** Malicious admin repeatedly calls `proposePrivacyDisable()` followed by `cancelPrivacyDisable()` to cause confusion among users who monitor the `PrivacyDisableProposed` event and rush to exit positions.

**Analysis:** Each proposal overwrites the previous `privacyDisableScheduledAt` (line 657-658). There is no check for an existing pending proposal, so a new proposal can be made at any time. Each proposal emits `PrivacyDisableProposed`, which could cause user panic.

See L-01 below.

### Attack 7: Exploit BURNER_ROLE to Destroy Anyone's Balance

**Scenario:** A holder of `BURNER_ROLE` calls `burnFrom(victimAddress, amount)` to destroy any user's public pXOM balance without their approval.

**Analysis:** The `burnFrom()` override at lines 861-866 bypasses the standard ERC20 allowance check:

```solidity
function burnFrom(
    address from,
    uint256 amount
) public override onlyRole(BURNER_ROLE) {
    _burn(from, amount);
}
```

Standard `ERC20BurnableUpgradeable.burnFrom()` calls `_spendAllowance(from, _msgSender(), amount)` before `_burn()`. This override removes the allowance check entirely. Anyone with `BURNER_ROLE` can burn any user's public pXOM balance without approval.

This is by design -- the bridge needs to burn pXOM from users during `convertPXOMtoXOM`. The bridge calls `burnFrom(caller, amount)` at OmniPrivacyBridge.sol line 382, where `caller` is the user who initiated the conversion and has approved the bridge.

**However:** If a rogue or compromised `BURNER_ROLE` holder calls `burnFrom` directly (not through the bridge), they can destroy any user's public pXOM without consent. This is a trust assumption on the `BURNER_ROLE` holder.

**Mitigation:** After deployment, `BURNER_ROLE` should be granted exclusively to the OmniPrivacyBridge contract and revoked from the deployer. See L-02.

**Verdict:** By design but dangerous if BURNER_ROLE is mismanaged. See L-02.

### Attack 8: Privacy Deanonymization via Event Correlation

**Lines 239-242:**
```solidity
event PrivateTransfer(
    address indexed from,
    address indexed to
);
```

**Lines 275-283:**
```solidity
event PrivateLedgerUpdated(
    address indexed from,
    address indexed to,
    uint256 scaledAmount
);
```

**Analysis (ATK-H06):** The `PrivateTransfer` event reveals sender and recipient addresses. The ATK-H08 fix added `PrivateLedgerUpdated` which additionally reveals the plaintext transfer amount (`scaledAmount`). This means every private transfer emits both the participants AND the amount on-chain in plaintext events.

The `PrivateLedgerUpdated` event (line 605) emits `transferAmount` which is `uint256(plainAmount)` (line 593) -- the decrypted MPC amount. This effectively reveals the transaction amount in plaintext, significantly reducing the privacy guarantee.

The NatSpec at lines 547-548 notes that the decrypt call "reveals the amount to the contract/node but not to external observers (amount is not emitted in events)." This statement is **incorrect** -- the amount IS emitted in the `PrivateLedgerUpdated` event at line 605.

See M-01 below.

---

## PASS 3 -- Cyfrin Checklist

### Storage Gap Correctness

**Lines 189-203:**

Sequential state variables (mappings excluded per OZ convention):
1. `totalPrivateSupply` (ctUint64 = uint256) -- 1 slot
2. `feeRecipient` (address) -- 1 slot
3. `privacyEnabled` (bool) -- 1 slot (packed with feeRecipient? No -- address is 20 bytes, bool is 1 byte, but in separate declarations they occupy separate slots)
4. `_ossified` (bool) -- 1 slot
5. `privacyDisableScheduledAt` (uint256) -- 1 slot

**Note on slot packing:** `feeRecipient` (address, 20 bytes) is at slot N. `privacyEnabled` (bool, 1 byte) is at slot N+1. They are NOT packed because Solidity only packs consecutive state variables of compatible sizes when they fit in a single 32-byte slot. However, address (20 bytes) + bool (1 byte) = 21 bytes, which DOES fit in 32 bytes. So `feeRecipient` and `privacyEnabled` MIGHT be packed into the same slot if they are declared consecutively. Let me verify:

Looking at the declaration order (lines 162, 165):
```solidity
address private feeRecipient;       // 20 bytes
bool private privacyEnabled;         // 1 byte
```

These are consecutive, so Solidity WILL pack them into the same slot. Similarly, `_ossified` (bool, 1 byte) and `privacyDisableScheduledAt` (uint256, 32 bytes) are NOT packable because uint256 requires a full slot.

Revised slot count:
1. `totalPrivateSupply` (uint256 wrapper) -- 1 slot
2. `feeRecipient` + `privacyEnabled` (20 + 1 = 21 bytes, packed) -- 1 slot
3. `_ossified` (bool, 1 byte) -- 1 slot (cannot pack with preceding mapping)
4. `privacyDisableScheduledAt` (uint256) -- 1 slot

Wait -- between `privacyEnabled` (line 165) and `_ossified` (line 177), there is `privateDepositLedger` (mapping, line 173). Mappings take one slot for the mapping pointer itself but the gap convention excludes them. However, the mapping pointer DOES occupy a sequential slot and breaks packing. So `_ossified` is in its own slot.

Actual sequential slots (including mapping pointers):
1. `totalPrivateSupply` -- slot S
2. `feeRecipient` + `privacyEnabled` -- slot S+1 (packed)
3. `privateDepositLedger` mapping pointer -- slot S+2
4. `_ossified` -- slot S+3
5. `privacyDisableScheduledAt` -- slot S+4

That is 5 sequential slots (if we count packed feeRecipient+privacyEnabled as 1). The gap comment says "Sequential slots used: 5" and "Gap = 50 - 5 = 45". But this comment also says "mappings excluded per OZ convention." If mappings are excluded, there are only 4 sequential non-mapping slots, and the gap should be 50 - 4 = 46.

However, the OZ convention for storage gaps is actually based on total slot consumption by the contract's own state (excluding inherited contracts). The mapping pointer does consume a slot. The standard approach is:

- Count all state variable slots INCLUDING mapping pointers
- Subtract from 50
- The gap ensures total = 50

With this approach: 5 slots used (including `privateDepositLedger` pointer) + `encryptedBalances` pointer = 6 slots. But `encryptedBalances` is also a mapping. Total slot consumption: 2 (mapping pointers) + 4 (non-mapping) = 6 slots. Gap should be 50 - 6 = 44.

The contract says 5 slots and gap of 45, totaling 50. But with slot packing, feeRecipient + privacyEnabled use 1 slot instead of 2. And mappings consume slots despite the "excluded" note.

**This is complex and warrants verification.** See I-06 below.

### Initializer Safety

**Lines 344-346, 353:**
```solidity
constructor() { _disableInitializers(); }
function initialize() external initializer { ... }
```

Correct UUPS pattern. `_disableInitializers()` in constructor prevents implementation initialization. `initializer` modifier on `initialize()` prevents re-initialization via proxy. Verified by test at line 91-98 (test passes: re-initialization reverts with `InvalidInitialization`).

### UUPS Proxy Pattern

- `_authorizeUpgrade()` (lines 912-920): Checks `onlyRole(DEFAULT_ADMIN_ROLE)` and `_ossified`.
- `UUPSUpgradeable` inherited (line 84).
- `__UUPSUpgradeable_init()` called in `initialize()` (line 360).
- Ossification provides irreversible upgrade lock.

**Correct.**

### CEI Pattern (Checks-Effects-Interactions)

**convertToPrivate (lines 408-454):**
1. Checks: privacyEnabled, amount != 0, scaledAmount != 0, scaledAmount <= uint64.max
2. Effects: `_burn` (internal state change), encrypted balance update, total supply update, shadow ledger update
3. Interactions: MPC precompile calls (internal library, no external contracts)

**convertToPublic (lines 470-528):**
1. Checks: privacyEnabled
2. Effects: encrypted balance update, total supply update
3. Interactions: MPC decrypt (precompile)
4. More Checks: plainAmount != 0, MAX_SUPPLY check
5. More Effects: shadow ledger update, `_mint`

**Note:** The `_mint` at line 525 occurs after MPC decrypt at line 501. The MAX_SUPPLY check at line 520 is between decrypt and mint. The encrypted state changes (lines 487-498) occur before the plaintext amount is known (decrypt at line 501). However, since `checkedSub` reverts on underflow and the `ge` check precedes it, the encrypted state changes are safe. The overall pattern is acceptable because MPC precompile calls are not external contract interactions.

**privateTransfer (lines 554-609):**
1. Checks: privacyEnabled, to != address(0), to != msg.sender
2. Effects: sender balance decrement, recipient balance increment
3. Interactions: MPC precompile calls
4. More Effects: decrypt amount, shadow ledger update
5. Events

**Overall:** CEI is followed for external interactions. MPC precompile calls are treated as internal effects (correct, as they call a system precompile, not a user-deployed contract).

### Events on State Changes

| State Change | Event | Status |
|--------------|-------|--------|
| Privacy enabled | `PrivacyStatusChanged(true)` | OK |
| Privacy disable proposed | `PrivacyDisableProposed(executeAfter)` | OK |
| Privacy disabled | `PrivacyDisabled()` | OK |
| Privacy disable cancelled | `PrivacyDisableCancelled()` | OK |
| Convert to private | `ConvertedToPrivate(user, publicAmount)` | OK |
| Convert to public | `ConvertedToPublic(user, publicAmount)` | OK |
| Private transfer | `PrivateTransfer(from, to)` + `PrivateLedgerUpdated(from, to, scaledAmount)` | OK |
| Emergency recovery | `EmergencyPrivateRecovery(user, publicAmount)` | OK |
| Fee recipient change | `FeeRecipientUpdated(newRecipient)` | OK |
| Ossification | `ContractOssified(contractAddress)` | OK |
| Pause/Unpause | Inherited OZ events | OK |
| Mint | Inherited OZ `Transfer(0x0, to, amount)` | OK |
| Burn | Inherited OZ `Transfer(from, 0x0, amount)` | OK |

**All state changes emit events.** However, note the inconsistency: `enablePrivacy()` emits `PrivacyStatusChanged(true)` but `executePrivacyDisable()` emits `PrivacyDisabled()` -- a different event for the reverse operation. See I-02 below.

---

## PASS 5 -- Adversarial Hacker Review

### Attack 1: Double-Claim Emergency Recovery via Shadow Ledger

**Scenario:** Alice converts 100 to private (ledger: Alice=100). Privacy is disabled. Admin recovers Alice (mints 100, ledger zeroed). Can Alice claim again?

**Analysis:** No. `emergencyRecoverPrivateBalance()` at line 723 sets `privateDepositLedger[user] = 0` BEFORE minting. The next call for the same user will revert at line 721 with `NoBalanceToRecover` (0 == 0 is true).

**Verdict:** Not exploitable. Ledger is zeroed before mint.

### Attack 2: Convert-Transfer-Reconvert to Inflate Supply

**Full scenario:**
- Alice: 1000 public pXOM, 0 private
- Alice converts 1000 to private: burns 1000 public, gets 1000000 (6-dec) private. Ledger: Alice=1000000.
- Alice transfers 1000000 to Bob privately. Ledger: Alice=0, Bob=1000000.
- Bob converts 1000000 back to public: mints 1000 public. Ledger: Bob=0.
- Net public supply change: -1000 (Alice burn) + 1000 (Bob mint) = 0. No inflation.

**Can this be exploited?**
- What if Bob converts back and ALSO claims emergency recovery? Emergency recovery requires privacy to be disabled. If privacy is still enabled, Bob cannot use emergency recovery. If privacy is disabled during Bob's conversion, `convertToPublic` requires `privacyEnabled = true`, so Bob cannot convert while privacy is disabled.
- These are mutually exclusive: `convertToPublic` requires `privacyEnabled = true`; `emergencyRecoverPrivateBalance` requires `privacyEnabled = false`. No double-dipping.

**Verdict:** Not exploitable. Mutual exclusivity of privacy modes prevents double-claiming.

### Attack 3: Race Condition Between convertToPublic and privateTransfer

Already analyzed in PASS 2D Attack 3. Not exploitable.

### Attack 4: Abuse BRIDGE_ROLE to Mint Unlimited Tokens

Already analyzed in PASS 2D Attack 4. Protected by MAX_SUPPLY. Operational role management is critical.

### Attack 5: Front-Run ossify() to Upgrade to Backdoored Implementation

Already analyzed in PASS 2D Attack 5. Requires compromised admin key.

### Attack 6: Grief by Proposing/Cancelling Privacy Disable Repeatedly

**Analysis:** `proposePrivacyDisable()` (line 653) can be called any number of times. Each call overwrites `privacyDisableScheduledAt`, extending the timer. There is no cooldown or counter. A malicious admin could:
1. Propose disable (emits event, users panic)
2. Wait 6 days
3. Cancel (emits event, users relax)
4. Immediately re-propose (new 7-day timer, users panic again)
5. Repeat indefinitely

Each cycle emits events that cause user confusion. However, the admin is already a trusted role. A malicious admin has far more destructive capabilities (pause, mint, burn via BURNER_ROLE, etc.). This griefing vector is low-severity.

See L-01 below.

### Attack 7: Exploit BURNER_ROLE to Destroy Anyone's Balance

Already analyzed in PASS 2D Attack 7. By design but requires operational security.

### Attack 8: Privacy Deanonymization via Event Correlation

**Deep analysis:**

Every `privateTransfer` emits two events:
1. `PrivateTransfer(from, to)` -- reveals participants (line 608)
2. `PrivateLedgerUpdated(from, to, scaledAmount)` -- reveals participants AND plaintext amount (line 605-607)

The `scaledAmount` at line 607 is `transferAmount = uint256(plainAmount)` where `plainAmount` is the decrypted MPC value (line 592). This reveals the exact transfer amount on-chain.

This means COTI MPC privacy for `privateTransfer` is effectively nullified at the event layer. Anyone monitoring events can see exactly who sent what to whom. The only remaining privacy is that the *balance* is still encrypted (the event only reveals the transfer amount, not the resulting balances).

The existing NatSpec at lines 547-548 is misleading:
> "The decrypt call reveals the amount to the contract/node but not to external observers (amount is not emitted in events)."

This is factually incorrect. The amount IS emitted in the `PrivateLedgerUpdated` event.

See M-01 below.

### Additional Attack Vector: Flash Loan + Convert

**Scenario:** Attacker takes a flash loan of XOM, converts to pXOM via bridge, converts pXOM to private, transfers privately, converts back, converts back to XOM, repays flash loan.

**Analysis:** This is economically meaningless. The bridge charges a 0.5% fee on XOM-to-pXOM conversion. The attacker would lose 0.5% of the flash loan amount. The privacy conversion within PrivateOmniCoin is fee-free, but getting pXOM requires going through the bridge. No profit vector exists.

Even if an attacker somehow has pXOM (e.g., from market purchase), the conversion functions are fee-free in this contract, and all balance changes are 1:1. No amplification or extraction is possible.

**Verdict:** Not exploitable. Fee on entry prevents flash loan arbitrage.

---

## Findings

### [M-01] PrivateLedgerUpdated Event Emits Plaintext Transfer Amount -- Defeats MPC Privacy

**Severity:** Medium
**Lines:** 592-607
**Category:** Privacy / Information Leakage (ATK-H06 / ATK-H08 Conflict)

**Description:**

The ATK-H08 fix at line 592 decrypts the MPC transfer amount to update the shadow ledger:

```solidity
// ATK-H08: Update shadow ledger ...
uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
uint256 transferAmount = uint256(plainAmount);
```

This plaintext amount is then emitted in the `PrivateLedgerUpdated` event (lines 605-607):

```solidity
emit PrivateLedgerUpdated(
    msg.sender, to, transferAmount
);
```

The `PrivateLedgerUpdated` event reveals:
1. Sender address (indexed)
2. Recipient address (indexed)
3. Exact transfer amount in plaintext (6-decimal scaled)

Combined with the `PrivateTransfer` event, every private transfer now has its participants and amount fully disclosed on-chain. This reduces the privacy guarantee of `privateTransfer` to effectively zero -- the only information that remains private is each user's total encrypted balance.

The NatSpec at lines 547-548 is incorrect:
> "Note: The decrypt call reveals the amount to the contract/node but not to external observers (amount is not emitted in events)."

**Impact:** Users relying on `privateTransfer` for transaction privacy will find their transfer amounts publicly visible on-chain via event logs. This is a significant reduction in the privacy guarantee that users expect from a privacy-preserving token.

**Recommendation:** Remove the `scaledAmount` parameter from the `PrivateLedgerUpdated` event to preserve amount privacy:

```solidity
event PrivateLedgerUpdated(
    address indexed from,
    address indexed to
);

// In privateTransfer():
emit PrivateLedgerUpdated(msg.sender, to);
```

Alternatively, if the shadow ledger update is deemed critical for emergency recovery and the team accepts the privacy trade-off, update the NatSpec at lines 547-548 to accurately state:

```
///      Note: The decrypt call reveals the amount to the
///      contract/node AND to external observers via the
///      PrivateLedgerUpdated event. Transaction amounts are
///      NOT private when using privateTransfer. Only the
///      encrypted balances remain confidential.
```

A third option is to use COTI's encrypted events (when available on COTI L2) to emit the amount in encrypted form, preserving both the shadow ledger accuracy and amount privacy.

---

### [L-01] Privacy Disable Propose/Cancel Allows Unlimited Griefing with No Cooldown

**Severity:** Low
**Lines:** 653-694
**Category:** Governance / User Experience

**Description:**

`proposePrivacyDisable()` can be called unlimited times. Each call overwrites the previous `privacyDisableScheduledAt` timestamp. There is no:
- Check for an existing pending proposal (allowing overwrites)
- Cooldown period between proposals
- Counter tracking how many times a proposal has been made

A malicious or compromised admin can repeatedly propose and cancel privacy disable, causing:
1. User panic from `PrivacyDisableProposed` events
2. Unnecessary gas costs for users rushing to exit private positions
3. Confusion about the actual state of the privacy system

Additionally, re-proposing while a previous proposal is still pending resets the 7-day timer, which could be used to perpetually extend the timelock.

**Impact:** User confusion and wasted gas. No direct fund loss. The admin is already a highly trusted role with greater destructive capabilities.

**Recommendation:** Consider adding a check for existing pending proposals:

```solidity
function proposePrivacyDisable()
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    if (privacyDisableScheduledAt != 0) revert ProposalAlreadyPending();
    privacyDisableScheduledAt =
        block.timestamp + PRIVACY_DISABLE_DELAY;
    emit PrivacyDisableProposed(privacyDisableScheduledAt);
}
```

This forces the admin to explicitly cancel before re-proposing, reducing accidental overwrites.

---

### [L-02] Deployer Retains MINTER_ROLE and BURNER_ROLE After Initialization -- Operational Risk

**Severity:** Low
**Lines:** 363-366
**Category:** Access Control / Operational Security

**Description:**

`initialize()` grants all four roles to the deployer:

```solidity
_grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
_grantRole(MINTER_ROLE, msg.sender);
_grantRole(BURNER_ROLE, msg.sender);
_grantRole(BRIDGE_ROLE, msg.sender);
```

In production:
- `MINTER_ROLE` should be held exclusively by `OmniPrivacyBridge` to ensure all pXOM is 1:1 backed by locked XOM.
- `BURNER_ROLE` should be held exclusively by `OmniPrivacyBridge` to prevent unauthorized token destruction.
- The deployer retaining these roles allows unbacked minting (up to MAX_SUPPLY) and arbitrary burning.

This is standard practice for upgradeable contracts (deployer sets up, then revokes), but the contract does not enforce role revocation. A deployment script error could leave these roles active on the deployer.

**Impact:** If the deployer's key is compromised and roles are not revoked, an attacker can mint up to 15.6B unbacked pXOM or burn any user's public pXOM balance.

**Recommendation:** Document the post-deployment role management procedure in a deployment checklist. Consider adding a `revokeDeployerRoles()` convenience function or documenting the exact `revokeRole()` calls required.

Post-deployment checklist:
1. Grant `MINTER_ROLE` to OmniPrivacyBridge
2. Grant `BURNER_ROLE` to OmniPrivacyBridge
3. Revoke `MINTER_ROLE` from deployer
4. Revoke `BURNER_ROLE` from deployer
5. Revoke `BRIDGE_ROLE` from deployer (unused)
6. Transfer `DEFAULT_ADMIN_ROLE` to a TimelockController multi-sig

---

### [L-03] ossify() Has No Timelock or Confirmation -- Irreversible Action via Single Transaction

**Severity:** Low
**Lines:** 784-787
**Category:** Governance / Safety

**Description:**

`ossify()` permanently disables upgrade capability in a single transaction:

```solidity
function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _ossified = true;
    emit ContractOssified(address(this));
}
```

Unlike `proposePrivacyDisable()` which has a 7-day timelock, ossification is instant and irreversible. If the admin role is behind a multi-sig or timelock controller, this provides adequate protection. If the admin is a single EOA, accidental or malicious ossification permanently prevents bug fixes and security patches.

The NatSpec on `OmniPrivacyBridge.ossify()` warns about this:
> IMPORTANT: The admin role MUST be behind a TimelockController before calling this function in production.

But `PrivateOmniCoin.ossify()` has no such warning.

**Impact:** Accidental ossification before the contract is fully stable could prevent necessary security patches. The risk depends entirely on the admin setup.

**Recommendation:** Add a warning comment similar to OmniPrivacyBridge:

```solidity
/// @notice Permanently remove upgrade capability (one-way, irreversible)
/// @dev IMPORTANT: The admin role MUST be behind a TimelockController
///      before calling this function in production. Accidental ossification
///      permanently prevents bug fixes and security patches.
///      Can only be called by admin.
```

Optionally, consider adding a two-step ossification pattern (propose + execute after delay), consistent with the privacy disable flow.

---

### [L-04] emergencyRecoverPrivateBalance NatSpec Is Outdated Post ATK-H08

**Severity:** Low
**Lines:** 698-710
**Category:** Documentation Accuracy

**Description:**

The NatSpec for `emergencyRecoverPrivateBalance()` states:

```
/// Limitations: Only deposits made via convertToPrivate are
/// recoverable. Amounts received via privateTransfer are NOT
/// tracked in the shadow ledger and cannot be recovered this way.
```

This was accurate before the ATK-H08 fix but is now incorrect. Since the ATK-H08 fix, `privateTransfer()` DOES update the shadow ledger at lines 592-603:

```solidity
// ATK-H08: Update shadow ledger ...
uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
uint256 transferAmount = uint256(plainAmount);
if (privateDepositLedger[msg.sender] >= transferAmount) {
    privateDepositLedger[msg.sender] -= transferAmount;
} else {
    privateDepositLedger[msg.sender] = 0;
}
privateDepositLedger[to] += transferAmount;
```

Therefore, amounts received via `privateTransfer` ARE tracked in the shadow ledger and CAN be recovered via `emergencyRecoverPrivateBalance()`.

**Impact:** Users and auditors reading the NatSpec will incorrectly believe that transferred balances are not recoverable, potentially causing unnecessary concern or incorrect emergency procedures.

**Recommendation:** Update the NatSpec:

```solidity
/// ATK-H08: All deposits and private transfers are tracked
/// in the shadow ledger. Both direct deposits (via
/// convertToPrivate) and amounts received (via privateTransfer)
/// are recoverable through this function.
```

---

### [I-01] NatSpec at Lines 547-548 Incorrectly Claims Transfer Amount Is Not Emitted in Events

**Severity:** Informational
**Lines:** 547-548
**Category:** Documentation Accuracy

**Description:**

The `privateTransfer` NatSpec states:

```
///      Note: The decrypt call reveals the amount to the
///      contract/node but not to external observers (amount
///      is not emitted in events).
```

This is factually incorrect. The `PrivateLedgerUpdated` event at line 605 emits `transferAmount`, which is the decrypted plaintext amount. External observers CAN see the transfer amount by reading event logs.

**Recommendation:** Correct the NatSpec to accurately describe the privacy properties (or remove the amount from the event per M-01).

---

### [I-02] Inconsistent Event Pattern for Privacy Status Changes

**Severity:** Informational
**Lines:** 246, 270, 642, 680
**Category:** API Consistency

**Description:**

`enablePrivacy()` emits `PrivacyStatusChanged(true)` (line 642), but `executePrivacyDisable()` emits `PrivacyDisabled()` (line 680) -- a different event entirely. This means off-chain systems must monitor two different events to track privacy status:

- `PrivacyStatusChanged(bool indexed enabled)` -- only for enabling
- `PrivacyDisabled()` -- for disabling

The `PrivacyStatusChanged` event has a `bool indexed enabled` parameter that could represent both states, but it is only emitted for `true`.

**Impact:** Minor off-chain monitoring complexity. No functional impact.

**Recommendation:** Consider emitting `PrivacyStatusChanged(false)` in `executePrivacyDisable()` instead of (or in addition to) `PrivacyDisabled()`. This would allow a single event listener to track all privacy status changes.

---

### [I-03] INITIAL_SUPPLY Relationship to OmniCoin Not Documented in NatSpec

**Severity:** Informational
**Lines:** 107-109
**Category:** Documentation

**Description:**

`INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18` (1 billion pXOM) while `OmniCoin.INITIAL_SUPPLY = 16_600_000_000 * 10 ** 18` (16.6 billion XOM). The rationale for pXOM starting with 1B rather than matching XOM's 16.6B is not documented in the contract NatSpec.

The 1B pXOM genesis supply appears to be for initial liquidity, with additional pXOM minted 1:1 via the bridge. However, this design decision should be documented for future auditors and maintainers.

**Impact:** No functional impact. Documentation gap for maintainability.

**Recommendation:** Add a NatSpec comment:

```solidity
/// @notice Initial token supply (1 billion tokens with 18 decimals)
/// @dev Intentionally lower than OmniCoin's 16.6B genesis supply.
///      The 1B pXOM provides initial privacy pool liquidity.
///      Additional pXOM is minted 1:1 (minus bridge fee) when users
///      convert XOM to pXOM via OmniPrivacyBridge. MAX_SUPPLY (16.6B)
///      ensures total pXOM cannot exceed total XOM supply.
```

---

### [I-04] No Public isOssified() Getter

**Severity:** Informational
**Lines:** 177
**Category:** API Completeness

**Description:**

The `_ossified` state variable is `private` (line 177) with no public getter function. Users, governance contracts, and off-chain monitoring systems cannot determine whether the contract has been ossified without reading storage directly (slot calculation required).

The OmniPrivacyBridge contract provides `isOssified()` (line 529-531). PrivateOmniCoin does not.

**Impact:** No functional impact. Reduces transparency and monitoring capability.

**Recommendation:** Add a public getter:

```solidity
/// @notice Check if the contract has been permanently ossified
/// @return True if ossified (no further upgrades possible)
function isOssified() external view returns (bool) {
    return _ossified;
}
```

---

### [I-05] BRIDGE_ROLE Is Defined and Granted But Never Used in Contract Logic

**Severity:** Informational
**Lines:** 103-105, 366
**Category:** Dead Code

**Description:**

`BRIDGE_ROLE = keccak256("BRIDGE_ROLE")` is defined at line 104 and granted to the deployer at line 366. However, no function in the contract uses `onlyRole(BRIDGE_ROLE)`. The bridge interacts with this contract via `MINTER_ROLE` (to call `mint()`) and `BURNER_ROLE` (to call `burnFrom()`).

**Impact:** One unused role constant and one unnecessary role grant. Storage slot for the role mapping entry is consumed. No functional impact.

**Recommendation:** Consider removing `BRIDGE_ROLE` if it serves no purpose. If it is intended for future use or as a governance marker, document its intended purpose:

```solidity
/// @notice Role identifier for bridge operations
/// @dev Currently unused by contract logic. Retained as a
///      governance marker for identifying authorized bridge
///      contracts. See MINTER_ROLE and BURNER_ROLE for the
///      roles actually required by bridge operations.
```

---

### [I-06] Storage Gap Calculation May Be Incorrect Due to Slot Packing

**Severity:** Informational
**Lines:** 189-203
**Category:** Upgradeable Storage Safety

**Description:**

The gap comment states:

```
/// Current named sequential state variables:
///   - encryptedBalances        (mapping, no seq. slot)
///   - totalPrivateSupply       (1 slot)
///   - feeRecipient             (1 slot)
///   - privacyEnabled           (1 slot)
///   - privateDepositLedger     (mapping, no seq. slot)
///   - _ossified                (1 slot)
///   - privacyDisableScheduledAt (1 slot)
///
/// Sequential slots used: 5
/// Gap = 50 - 5 = 45 slots reserved
/// (mappings excluded per OZ convention)
```

Several observations:

1. **Mappings DO consume a sequential slot.** In Solidity, a mapping declaration occupies a slot (the slot number is used to compute storage locations for mapping entries via keccak256). The OZ convention of "excluding mappings" from the count is about the fact that mapping data is scattered, but the mapping pointer itself occupies a slot. The correct approach is to count mapping slots too.

2. **Slot packing:** `feeRecipient` (address, 20 bytes) and `privacyEnabled` (bool, 1 byte) are consecutive declarations and will be packed into a single 32-byte slot by the Solidity compiler, consuming only 1 slot instead of 2.

However, what matters for upgrade safety is **consistency** -- as long as every upgrade uses the same gap convention, the actual gap size does not matter. If the contract was originally deployed with this gap calculation and future upgrades follow the same convention, storage layout will remain consistent.

**Impact:** No immediate impact if the convention is followed consistently. Could cause issues if a future developer uses a different gap counting methodology and adds variables expecting a different number of available slots.

**Recommendation:** Verify the storage layout against the deployed proxy using a tool like `hardhat-storage-layout` or `forge inspect <contract> storageLayout`. Document the exact slot assignments for each state variable.

---

## Gas Optimization Notes

1. **Custom errors:** Used throughout -- gas-efficient pattern. No `require` strings (except in MpcCore.checkOverflow which is external dependency).
2. **Indexed events:** Appropriately indexed. `ConvertedToPrivate` no longer over-indexes. New `PrivateLedgerUpdated` indexes `from` and `to` (useful for filtering).
3. **nonReentrant modifier:** ~2,500 gas per call on three privacy functions. Justified given MPC precompile interaction.
4. **Constants:** `PRIVACY_FEE_BPS`, `BPS_DENOMINATOR`, `INITIAL_SUPPLY`, `PRIVACY_SCALING_FACTOR`, `MAX_SUPPLY`, `PRIVACY_DISABLE_DELAY` are all `constant` -- no SLOAD cost.
5. **Storage packing:** `feeRecipient` (20 bytes) and `privacyEnabled` (1 byte) are packed in one slot. Good.
6. **Strict inequality:** Line 508 uses `>` for the shadow ledger comparison, avoiding unnecessary subtraction-of-zero when equal. Minor optimization, correct.
7. **`delete` keyword:** Line 679 uses `delete privacyDisableScheduledAt` which is gas-efficient (refunds storage slot clearing).

---

## Test Coverage Analysis

The test suite (`Coin/test/PrivateOmniCoin.test.js`, 662 lines) provides good coverage for non-MPC functionality. Tests correctly work around the Hardhat limitation (no COTI MPC precompile) by testing revert conditions and interface compliance.

| Test Area | Status | Notes |
|-----------|--------|-------|
| Deploy via UUPS proxy | Covered | Lines 17-23 |
| Name/symbol/decimals | Covered | Lines 54-59 |
| Initial supply and distribution | Covered | Lines 61-75 |
| Role grants (MINTER, BURNER, BRIDGE) | Covered | Lines 77-89 |
| Re-initialization prevention | Covered | Lines 91-98 |
| Fee recipient management | Covered | Lines 100-104, 395-425 |
| Privacy availability on Hardhat | Covered | Lines 112-121 |
| Enable/disable privacy via timelock | Covered | Lines 124-138 |
| Timelock events (propose/disable) | Covered | Lines 140-156 |
| Non-admin propose prevention | Covered | Lines 158-164 |
| convertToPrivate zero amount revert | Covered | Lines 208-217 |
| convertToPrivate uint64 overflow revert | Covered | Lines 219-235 |
| convertToPrivate privacy disabled revert | Covered | Lines 237-247 |
| convertToPrivate paused revert | Covered | Lines 249-257 |
| Scaling factor value | Covered | Lines 259-264 |
| ATK-H05 owner-only decrypt | Covered | Lines 318-330 |
| Emergency recovery (privacy enabled revert) | Covered | Lines 485-494 |
| Emergency recovery (zero address revert) | Covered | Lines 496-505 |
| Emergency recovery (no balance revert) | Covered | Lines 507-516 |
| Emergency recovery (non-admin revert) | Covered | Lines 518-527 |
| Pausable functionality | Covered | Lines 534-579 |
| Standard ERC20 (transfer, approve, transferFrom, burn) | Covered | Lines 585-629 |
| Constants (INITIAL_SUPPLY, PRIVACY_FEE_BPS, MAX_SUPPLY) | Covered | Lines 635-661 |
| MAX_SUPPLY enforcement on mint | Covered | Lines 447-457 |
| Self-transfer check interface | Covered | Lines 380-387 |

### Missing Test Coverage (Recommended Additions)

| Missing Test | Criticality | Related Finding |
|--------------|-------------|-----------------|
| `convertToPrivate` with sub-1e12 dust verifies dust preserved | Medium | M-03 fix verification |
| `privateTransfer` to self reverts with `SelfTransfer` (with MPC) | Low | Needs COTI testnet |
| `ossify()` then upgrade reverts `ContractIsOssified` | Medium | L-03 |
| `ossify()` emits `ContractOssified` event | Low | -- |
| `proposePrivacyDisable` while proposal pending | Low | L-01 |
| `cancelPrivacyDisable` when no pending proposal | Low | -- |
| `executePrivacyDisable` before timelock expires reverts | Medium | ATK-H07 |
| Emergency recovery with MAX_SUPPLY check (edge case) | Low | L-01 fix |
| `burnFrom` skips allowance check (by design, document) | Medium | Attack 7 |
| `PrivateLedgerUpdated` event emission in privateTransfer | Low | M-01 |
| Shadow ledger correctness through convert-transfer-reconvert | High | Attack 2 (needs COTI) |

---

## Comparison Across Audit Rounds

| Metric | Round 1 | Round 3 | Round 6 | Trend |
|--------|---------|---------|---------|-------|
| Lines of Code | 501 | 764 | 968 | +204 (timelock, shadow ledger transfers, events) |
| Critical | 1 | 0 | 0 | Stable |
| High | 3 | 0 | 0 | Stable |
| Medium | 5 | 3 | 1 | Improving |
| Low | 4 | 3 | 4 | Stable (new features introduced new items) |
| Informational | 2 | 4 | 6 | More thorough review |
| Total Findings | 15 | 10 | 11 | Severity significantly lower |
| Round 3 Remediations | -- | -- | 10/10 FIXED | Complete |

The contract has matured significantly across three audit rounds. Round 1 had a Critical uint64 precision issue that made privacy fundamentally unusable. Round 3 had unchecked MPC arithmetic. Round 6 has only one Medium finding (privacy leakage via event), which is a design trade-off rather than a vulnerability.

---

## Summary of Recommendations (Priority Order)

| # | Finding | Severity | Effort | Recommendation |
|---|---------|----------|--------|----------------|
| 1 | M-01 | Medium | Low | Remove `scaledAmount` from `PrivateLedgerUpdated` event OR update NatSpec to disclose the privacy limitation |
| 2 | L-04 | Low | Trivial | Update emergency recovery NatSpec (ATK-H08 fix made it outdated) |
| 3 | L-02 | Low | Low | Document post-deployment role revocation checklist |
| 4 | L-03 | Low | Low | Add warning comment to `ossify()` about timelock requirement |
| 5 | L-01 | Low | Low | Consider requiring cancel before re-propose for privacy disable |
| 6 | I-01 | Info | Trivial | Correct NatSpec at lines 547-548 about amount emission |
| 7 | I-02 | Info | Trivial | Consider emitting `PrivacyStatusChanged(false)` for consistency |
| 8 | I-03 | Info | Trivial | Document INITIAL_SUPPLY rationale in NatSpec |
| 9 | I-04 | Info | Trivial | Add `isOssified()` public getter |
| 10 | I-05 | Info | Trivial | Document or remove unused BRIDGE_ROLE |
| 11 | I-06 | Info | Low | Verify storage layout against deployed proxy |

---

## Conclusion

PrivateOmniCoin has undergone substantial improvement across three audit rounds and is in strong shape for mainnet deployment. All Critical and High findings from previous rounds have been remediated and verified. The Round 6 findings are predominantly informational or low-severity.

**The single Medium finding (M-01)** is a privacy design trade-off introduced by the ATK-H08 fix: the shadow ledger update in `privateTransfer` requires decrypting the transfer amount, which is then emitted in a plaintext event. This effectively deanonymizes private transfer amounts. The team should decide whether the shadow ledger accuracy (enabling emergency recovery of transferred funds) outweighs the privacy cost. If privacy is the priority, remove the amount from the event. If recovery completeness is the priority, document the limitation transparently.

**Key strengths of the current implementation:**
1. Checked MPC arithmetic on all paths (checkedAdd/checkedSub)
2. Defense-in-depth MAX_SUPPLY cap on all three mint paths
3. 7-day timelock for privacy disable (ATK-H07)
4. Owner-only balance decryption (ATK-H05)
5. Shadow ledger tracking through transfers (ATK-H08)
6. Clean separation of fee logic to OmniPrivacyBridge
7. Dust preservation on conversion (M-03 fix)
8. Ossification for progressive decentralization
9. Comprehensive NatSpec documentation

**Pre-mainnet recommendations:**
1. Fix M-01 (privacy event leakage) based on team's privacy vs. recovery priority
2. Update outdated NatSpec (L-04, I-01)
3. Execute the role revocation checklist after deployment (L-02)
4. Transfer admin to TimelockController before production use
5. Verify storage layout against deployed proxy (I-06)
6. Run full test suite on COTI testnet to validate MPC operations

**Overall Risk Assessment:** Low

---

*Report generated 2026-03-10*
*Methodology: 5-pass comprehensive audit (OWASP SC Top 10 + Business Logic + Access Control + DeFi Exploit Patterns + Cyfrin Checklist + Adversarial Hacker Review)*
*Contract: PrivateOmniCoin.sol, 968 lines, Solidity 0.8.24*
*Dependencies reviewed: MpcCore.sol (COTI V2 MPC library), OmniPrivacyBridge.sol*
*Previous audit remediation: 10/10 Round 3 findings verified as FIXED*
*Static analysis: Slither and Mythril results not available for this round*
