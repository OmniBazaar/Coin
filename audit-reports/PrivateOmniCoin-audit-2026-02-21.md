# Security Audit Report: PrivateOmniCoin

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/PrivateOmniCoin.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 501
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (ERC20 token with privacy-preserving balances via COTI V2 MPC)

## Executive Summary

PrivateOmniCoin is a UUPS-upgradeable ERC20 token (pXOM) that extends standard token functionality with COTI V2 MPC-encrypted private balances. Users can convert public pXOM to encrypted private balances (`convertToPrivate`), transfer privately (`privateTransfer`), and convert back (`convertToPublic`). A 0.3% fee is charged on public-to-private conversions.

The audit found **1 Critical vulnerability**: all private balances are stored as `ctUint64` (COTI's encrypted uint64), which limits the maximum private balance to `type(uint64).max` = 18,446,744,073,709,551,615 wei = **~18.4 XOM** at 18 decimals. This makes the privacy feature practically unusable for any meaningful amount. Both audit agents independently confirmed this as the top-priority finding. Additionally, **3 High-severity issues** were found: double-fee when combined with OmniPrivacyBridge (0.6% total), fee minting creates unbacked pXOM undermining bridge collateralization, and MPC unavailability permanently locks private funds with no recovery mechanism.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 5 |
| Low | 4 |
| Informational | 2 |

## Findings

### [C-01] uint64 Precision Limit — Maximum Private Balance ~18.4 XOM

**Severity:** Critical
**Lines:** 73, 77, 213, 228, 234, 265, 270
**Agents:** Both

**Description:**

All MPC operations use COTI V2's `ctUint64`/`gtUint64` types, which are encrypted 64-bit unsigned integers. With OmniCoin's 18 decimals, the maximum representable value is:

```
type(uint64).max = 18,446,744,073,709,551,615 wei
                 = 18.446744... XOM
```

Line 213 checks `if (amount > type(uint64).max) revert AmountTooLarge()`, confirming the contract is aware of the limit but treats it as acceptable. However, 18.4 XOM is far below any practical use case — a single welcome bonus (625-10,000 XOM) exceeds this limit. The `MpcCore.add()` at line 234 uses unchecked addition on encrypted values; if the running balance somehow exceeds uint64, the MPC will silently wrap around to zero.

**Impact:** The privacy feature is fundamentally unusable for the OmniBazaar ecosystem. No user can privately hold more than ~18.4 XOM. This is a design-level incompatibility between COTI V2's uint64 MPC types and OmniCoin's 18-decimal token.

**Recommendation:** This requires architectural changes at the COTI integration level:
1. **Short-term:** Reduce pXOM decimals to 6 (max ~18.4 trillion units = 18.4M tokens), or use a scaling factor to convert between 18-decimal public amounts and 6-decimal private amounts
2. **Long-term:** Wait for COTI V2 to support uint128 or uint256 encrypted types
3. **Document clearly** that privacy is limited to small amounts until the uint64 limitation is resolved

```solidity
// Option 1: Scaling approach
uint256 constant PRIVACY_SCALING_FACTOR = 1e12; // 18 - 6 = 12 zeros
uint64 scaledAmount = uint64(amount / PRIVACY_SCALING_FACTOR);
// Max representable: ~18.4M XOM (much more practical)
```

---

### [H-01] Double Fee — 0.6% Total for Full XOM-to-Private Path

**Severity:** High
**Lines:** 216, 224
**Agent:** Agent B

**Description:**

When a user converts XOM to encrypted pXOM, they must traverse two contracts:
1. **OmniPrivacyBridge.convertXOMtoPXOM()**: Charges 0.3% fee (locks XOM, mints public pXOM)
2. **PrivateOmniCoin.convertToPrivate()**: Charges another 0.3% fee (burns public pXOM, credits private balance)

The combined path charges 0.6% — double the documented 0.3% privacy fee. This is because both contracts independently charge PRIVACY_FEE_BPS = 30 (0.3%). The OmniBazaar specification states a single 0.3% privacy conversion fee.

**Impact:** Users pay double the documented fee for end-to-end privacy. For large conversions (if uint64 is resolved), this becomes economically significant. Users who discover they're paying double fees will lose trust in the platform.

**Recommendation:** Remove the fee from one of the two contracts. Since OmniPrivacyBridge is the entry point:
```solidity
// In PrivateOmniCoin.convertToPrivate():
// Remove fee calculation — bridge already charged 0.3%
uint256 amountAfterFee = amount; // No additional fee
```
Or add a `BRIDGE_ROLE` bypass: if caller is the bridge, skip the fee.

---

### [H-02] Fee Minting Creates Unbacked pXOM — Bridge Undercollateralization

**Severity:** High
**Lines:** 220, 224
**Agent:** Agent B

**Description:**

In `convertToPrivate()`, the contract first burns the user's pXOM (line 220: `_burn(msg.sender, amount)`), then mints the fee to the fee recipient (line 224: `_mint(feeRecipient, fee)`). This creates new pXOM tokens that are NOT backed by locked XOM in the OmniPrivacyBridge.

Example:
1. User converts 100 pXOM to private. Contract burns 100 pXOM, mints 0.3 pXOM to feeRecipient
2. Bridge has XOM locked for the original 100 pXOM minus the bridge's own fee
3. Net pXOM supply decreased by 99.7, but the 0.3 fee pXOM is unbacked
4. Over time, accumulated fees create a growing gap between locked XOM and circulating pXOM
5. Eventually, `convertPXOMtoXOM()` will fail with `InsufficientLockedFunds` for the last users

**Impact:** Progressive undercollateralization of the bridge. The last users to convert back to XOM will find insufficient locked funds.

**Recommendation:** Instead of minting the fee as new pXOM, keep it within the burned amount and track it separately:
```solidity
// Don't mint fee — just burn less (keep fee in bridge as locked XOM)
_burn(msg.sender, amount);
// Credit only amountAfterFee to private balance
// The fee stays as locked XOM in the bridge, maintaining collateralization
```

---

### [H-03] MPC Unavailability Permanently Locks Private Funds

**Severity:** High
**Lines:** 252-280, 292-315, 488-500
**Agent:** Agent A

**Description:**

All private balance operations (`convertToPublic`, `privateTransfer`, `decryptedPrivateBalanceOf`) require MPC precompile calls (`MpcCore.onBoard`, `MpcCore.decrypt`, `MpcCore.sub`, etc.). If the MPC network becomes unavailable — due to COTI network issues, maintenance, or migration — all funds stored in private balances are permanently locked. There is no emergency recovery mechanism.

The `setPrivacyEnabled(false)` admin function only prevents NEW privacy operations — it does not provide a way to recover existing private balances. Once privacy is disabled, users with encrypted balances have no path to retrieve their funds.

Additionally, `_detectPrivacyAvailability()` checks chain IDs 13068200, 7082400, 7082, and 1353 — but NOT OmniCoin L1 chain 131313. Privacy features will be disabled on OmniCoin's own chain.

**Impact:** Any funds converted to private balances are at risk of permanent loss if MPC becomes unavailable. No emergency recovery path exists.

**Recommendation:**
1. Add an emergency recovery function that bypasses MPC:
```solidity
mapping(address => uint256) public emergencyPrivateBalances;

function emergencyRecoverPrivateBalance() external onlyRole(DEFAULT_ADMIN_ROLE) {
    // Must be called while MPC is still available to snapshot balances
    // Or maintain a shadow ledger of private deposits
}
```
2. Track private deposits in a separate plaintext mapping for emergency recovery
3. Add chain 131313 to `_detectPrivacyAvailability()` if OmniCoin L1 supports MPC

---

### [M-01] Self-Transfer in privateTransfer May Corrupt MPC State

**Severity:** Medium
**Lines:** 292-315
**Agent:** Agent B

**Description:**

`privateTransfer()` does not check `msg.sender != to`. When `from == to`:
1. Line 297: Loads sender balance into `gtSenderBalance`
2. Line 306: Subtracts amount → stores to `encryptedBalances[msg.sender]`
3. Line 310: Loads recipient balance from `encryptedBalances[to]` — but this is the SAME slot, now holding the post-subtraction value
4. Line 311: Adds amount to the post-subtraction value

The result is correct (balance unchanged), but it performs unnecessary MPC operations that cost gas and could trigger MPC state inconsistencies if the MPC precompile has ordering assumptions.

**Recommendation:** Add `if (to == msg.sender) revert ZeroAddress();` or simply `return` early.

---

### [M-02] convertToPublic Has No Zero-Amount Check

**Severity:** Medium
**Lines:** 252-280
**Agent:** Agent A

**Description:**

Unlike `convertToPrivate()` which checks `if (amount == 0) revert ZeroAmount()`, the `convertToPublic()` function accepts any `gtUint64` including an encrypted zero. An encrypted zero would pass the balance check (0 >= 0), subtract nothing, decrypt to 0, and mint 0 tokens — a no-op that wastes gas and emits a misleading `ConvertedToPublic(user, 0)` event.

**Recommendation:** After decrypting the amount, check for zero:
```solidity
uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
if (plainAmount == 0) revert ZeroAmount();
```

---

### [M-03] Uncapped Mint Allows Admin to Create Unlimited pXOM

**Severity:** Medium
**Lines:** 348-350
**Agent:** Agent B

**Description:**

The `mint()` function (line 348) has no supply cap, unlike OmniCoin which uses MintController to enforce emission schedules. Any MINTER_ROLE holder can mint unlimited pXOM. While the bridge is the intended minter, a compromised MINTER_ROLE can inflate the pXOM supply arbitrarily.

OmniCoin has strict emission controls (16.6B total supply, decreasing block rewards), but pXOM has none. The `INITIAL_SUPPLY` of 1B pXOM (line 59) is minted in `initialize()`, but nothing prevents further minting.

**Impact:** MINTER_ROLE compromise leads to unlimited pXOM inflation. If pXOM is tradeable, this destroys its value.

**Recommendation:** Add a supply cap:
```solidity
uint256 public constant MAX_SUPPLY = 16_600_000_000 * 10**18;
function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
    if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
    _mint(to, amount);
}
```

---

### [M-04] Chain ID 131313 Missing from Privacy Detection

**Severity:** Medium
**Lines:** 488-500
**Agents:** Both

**Description:**

`_detectPrivacyAvailability()` checks chain IDs 13068200, 7082400, 7082, and 1353 — all COTI networks. But OmniCoin L1 runs on chain 131313 (Avalanche subnet). If OmniCoin L1 integrates COTI MPC precompiles, privacy will still be disabled because 131313 is not in the detection list.

The admin can manually call `setPrivacyEnabled(true)`, but the initialize function will set `privacyEnabled = false` on deployment, which could cause confusion.

**Recommendation:** Add chain 131313:
```solidity
return (
    block.chainid == 13068200 ||  // COTI Devnet
    block.chainid == 7082400 ||   // COTI Testnet
    block.chainid == 7082 ||      // COTI Testnet (alternative)
    block.chainid == 1353 ||      // COTI Mainnet
    block.chainid == 131313       // OmniCoin L1
);
```

---

### [M-05] No Reentrancy Protection on Privacy Functions

**Severity:** Medium
**Lines:** 210, 252, 292
**Agent:** Agent B

**Description:**

`convertToPrivate()`, `convertToPublic()`, and `privateTransfer()` have no `nonReentrant` modifier. While ERC20 transfers within the same contract are generally safe, the MPC precompile calls (`MpcCore.onBoard`, `MpcCore.offBoard`, `MpcCore.add`, etc.) are external calls to the MPC precompile at address `0x64`. If the MPC precompile has any callback mechanism, reentrancy could corrupt encrypted balances.

The contract inherits ReentrancyGuard (indirectly via ERC20PausableUpgradeable chain), but none of the privacy functions use the `nonReentrant` modifier.

**Recommendation:** Add `nonReentrant` modifier to all three privacy functions. Import and inherit `ReentrancyGuardUpgradeable`:
```solidity
function convertToPrivate(uint256 amount) external nonReentrant whenNotPaused { ... }
function convertToPublic(gtUint64 encryptedAmount) external nonReentrant whenNotPaused { ... }
function privateTransfer(address to, gtUint64 encryptedAmount) external nonReentrant whenNotPaused { ... }
```

---

### [L-01] burnFrom Bypasses Allowance Check

**Severity:** Low
**Lines:** 417-419
**Agents:** Both

**Description:**

`burnFrom()` uses `onlyRole(BURNER_ROLE)` instead of checking allowance. This is intentional (documented in OmniCoin design) — the BURNER_ROLE is granted to the bridge contract for lockup/burn operations. However, it differs from standard ERC20 behavior where `burnFrom` requires prior `approve()`.

**Impact:** A compromised BURNER_ROLE can burn any user's public pXOM without their approval. This is by design but represents centralization risk.

**Recommendation:** Document clearly in NatSpec that this is intentional. Consider adding an event when tokens are burned from another address.

---

### [L-02] Fee Precision Loss for Small Amounts

**Severity:** Low
**Lines:** 216
**Agent:** Agent A

**Description:**

Fee calculation `(amount * PRIVACY_FEE_BPS) / BPS_DENOMINATOR` where BPS is 30 and denominator is 10000. For amounts < 334 wei, `(amount * 30) / 10000 = 0` — zero fee. Users can convert tiny amounts fee-free. Given the uint64 limit (~18.4 XOM), this is only relevant for dust amounts.

**Recommendation:** Low priority given uint64 limits. If fixed, add minimum amount check.

---

### [L-03] INITIAL_SUPPLY Creates Unbacked pXOM at Deployment

**Severity:** Low
**Lines:** 59, 186
**Agent:** Agent B

**Description:**

`initialize()` mints 1B pXOM to the deployer (line 186). These tokens are not backed by locked XOM in the bridge. If the deployer sells or distributes these tokens, the bridge's XOM reserves will be insufficient for full redemption.

**Impact:** 1B unbacked pXOM at genesis. Users converting pXOM→XOM may face `InsufficientLockedFunds`.

**Recommendation:** Either remove the initial supply mint, or ensure the bridge is funded with equivalent XOM at deployment.

---

### [L-04] Asymmetric Fee Design — Fee Only on Conversion In

**Severity:** Low
**Lines:** 210, 252
**Agent:** Agent A

**Description:**

Privacy fee (0.3%) is only charged on `convertToPrivate()`, not on `convertToPublic()`. This creates an asymmetry where converting to privacy costs money but exiting is free. While this matches the OmniBazaar specification, it incentivizes users to keep funds private once converted (no cost to leave private mode), which may have unintended monetary policy effects.

**Recommendation:** No action required — matches specification. Document the design rationale.

---

### [I-01] Storage Gap Counting

**Severity:** Informational
**Lines:** 92
**Agent:** Agent B

**Description:**

The comment says "4 variables" but the contract inherits from 5 OpenZeppelin upgradeable contracts, each with their own storage. The gap of 46 is reasonable for PrivateOmniCoin's own 4 state variables, but the comment could be clearer about what's being counted.

**Recommendation:** Update comment for clarity.

---

### [I-02] Event Indexing on publicAmount

**Severity:** Informational
**Lines:** 102, 107
**Agent:** Agent A

**Description:**

`ConvertedToPrivate` indexes `publicAmount` and `fee` (both uint256). Filtering by exact amount is impractical and wastes gas per event emission. Move `fee` to data portion.

**Recommendation:** Only index `user`:
```solidity
event ConvertedToPrivate(address indexed user, uint256 publicAmount, uint256 fee);
```

---

## Static Analysis Results

**Solhint:** 0 errors, 3 warnings
- 1 function ordering (style)
- 1 not-rely-on-time (accepted — conversion timing)
- 1 gas-strict-inequalities

**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 35 raw findings -> 15 unique)
- Pass 6: Report generation

## Conclusion

PrivateOmniCoin has **one Critical vulnerability that makes the privacy feature fundamentally unusable**:

1. **uint64 precision limit (C-01)** restricts private balances to ~18.4 XOM — far below any practical use case. This is an inherent limitation of COTI V2's MPC types and requires architectural changes to resolve.

2. **Double fee (H-01)** charges users 0.6% instead of the documented 0.3% for end-to-end privacy conversion.

3. **Unbacked fee minting (H-02)** progressively undercollateralizes the bridge, risking insolvency for late withdrawers.

4. **No MPC recovery (H-03)** means private funds are permanently locked if MPC becomes unavailable.

The contract requires significant architectural work before the privacy feature can serve its intended purpose. The uint64 limitation is the most fundamental issue — all other findings are secondary until this is resolved.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
