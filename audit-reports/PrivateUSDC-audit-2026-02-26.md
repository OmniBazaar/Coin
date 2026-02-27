# Security Audit Report: PrivateUSDC

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/privacy/PrivateUSDC.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 370
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (privacy-preserving USDC wrapper via COTI V2 MPC)

## Executive Summary

PrivateUSDC is a UUPS-upgradeable privacy wrapper contract that enables USDC holders to convert public USDC balances into MPC-encrypted private balances (pUSDC) using COTI V2 garbled circuits. The contract supports bridge mint/burn for cross-chain deposits, public-to-private conversion, private-to-public conversion, and privacy-preserving transfers where amounts remain encrypted. A shadow ledger tracks deposits for emergency recovery purposes.

Unlike the sibling contracts PrivateWETH (18 decimals, 1e12 scaling) and PrivateWBTC (8 decimals, 1e2 scaling), PrivateUSDC uses a scaling factor of 1 because USDC natively uses 6 decimals, which matches MPC's uint64 precision without loss. This makes the contract structurally simpler but introduces a unique critical vulnerability: `bridgeMint()` credits `totalPublicSupply` without delivering actual tokens, creating a phantom balance that can never be redeemed. Additionally, the `privateBalanceOf()` function exposes encrypted balances to any caller, the shadow ledger is publicly readable, and there is no pausability or emergency recovery mechanism.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 4 |
| Low | 4 |
| Informational | 3 |

## Findings

### [C-01] bridgeMint Does Not Transfer Actual Tokens -- Phantom Balance

**Severity:** Critical
**Lines:** 190-199
**Impact:** Loss of funds / Bridge insolvency

**Description:**

`bridgeMint()` increments `totalPublicSupply` and emits a `BridgeMint` event, but it does **not** actually transfer or hold any USDC tokens. The function signature implies that USDC is being bridged into the contract, but no `IERC20.transferFrom()`, `IERC20.safeTransferFrom()`, or any token interaction occurs:

```solidity
function bridgeMint(
    address to,
    uint256 amount
) external onlyRole(BRIDGE_ROLE) {
    if (to == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();

    totalPublicSupply += amount;       // Increments counter...
    emit BridgeMint(to, amount);       // ...but no tokens move
}
```

This creates a phantom balance: `totalPublicSupply` reports tokens exist, but the contract holds zero USDC. When a user later calls `convertToPrivate()`, there is no check that the user's public balance actually exists in the contract -- the function simply creates an MPC-encrypted balance from thin air (line 236: `MpcCore.setPublic64(uint64(amount))`).

Conversely, `bridgeBurn()` decrements `totalPublicSupply` and emits `BridgeBurn`, but also transfers no tokens outward. The entire public supply accounting is an illusion.

**The fundamental design flaw:** This contract is a privacy wrapper but has no underlying ERC20 token management. It is neither an ERC20 itself (unlike PrivateOmniCoin which inherits ERC20Upgradeable) nor does it hold USDC via `transferFrom`. The `totalPublicSupply` variable tracks nothing backed by real tokens.

Compare with PrivateOmniCoin which:
1. Inherits ERC20Upgradeable and IS a token
2. `convertToPrivate()` calls `_burn(msg.sender, amount)` to destroy real public tokens
3. `convertToPublic()` calls `_mint(msg.sender, publicAmount)` to create real public tokens

PrivateUSDC has none of this. A user who calls `bridgeMint()` (via the bridge role) and then `convertToPrivate()` gets an encrypted private balance without any USDC being locked. When they later call `convertToPublic()`, the contract emits an event claiming they converted back, but no USDC is sent to them because no USDC was ever received.

**Impact:** The contract is functionally broken as deployed. Any integration with a real bridge would either:
1. Lock user USDC in the bridge contract with no path to recovery (bridge sends USDC, calls `bridgeMint`, but PrivateUSDC never holds or returns USDC), or
2. Allow creation of unbacked private balances that represent non-existent USDC

**Recommendation:** The contract must be redesigned to actually custody USDC:

```solidity
// Option A: Hold USDC via transferFrom
IERC20 public usdc; // Set in initialize()

function bridgeMint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
    if (to == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();
    // Actually receive USDC from the bridge
    usdc.safeTransferFrom(msg.sender, address(this), amount);
    totalPublicSupply += amount;
    // Credit user's redeemable balance
    publicBalances[to] += amount;
    emit BridgeMint(to, amount);
}

// Option B: Become an ERC20 like PrivateOmniCoin
// Inherit ERC20Upgradeable, mint pUSDC to the user on bridgeMint,
// burn pUSDC on convertToPrivate, mint on convertToPublic
```

---

### [H-01] convertToPrivate Has No Token Custody -- Creates Unbacked Encrypted Balances

**Severity:** High
**Lines:** 229-249
**Dependency:** C-01

**Description:**

`convertToPrivate()` creates an MPC-encrypted balance (line 242: `MpcCore.add(gtCurrent, gtAmount)`) without burning, transferring, or locking any real tokens from the caller. The function requires `amount > 0` and `amount <= type(uint64).max`, but there is no check that `msg.sender` actually holds this amount or that the contract is authorized to take tokens from them.

This is in direct contrast to PrivateOmniCoin, where `convertToPrivate()` calls `_burn(msg.sender, amount)` (line 323) to destroy the caller's public ERC20 balance before crediting the encrypted balance.

Without token custody, any address can call `convertToPrivate(1000000)` (1 USDC at 6 decimals) and receive a private balance of 1 USDC without owning or spending any USDC. This allows unlimited creation of fake pUSDC balances.

**Impact:** Any user can fabricate unlimited private USDC balances. If the contract is ever connected to a redemption path, these fabricated balances drain real funds.

**Recommendation:** Add token custody. Either:
1. Require USDC `transferFrom` before crediting private balance, or
2. Require public ERC20 balance (if contract becomes an ERC20) via `_burn(msg.sender, amount)`

---

### [H-02] convertToPublic Does Not Deliver Tokens -- Conversion to Public Is a No-Op

**Severity:** High
**Lines:** 255-283

**Description:**

`convertToPublic()` subtracts from the caller's encrypted balance (line 268-269), decrypts the amount, updates the shadow ledger, and emits `ConvertedToPublic` -- but does not transfer, mint, or credit any USDC to the caller. The user's private balance decreases, but they receive nothing in return.

Compare with PrivateOmniCoin where `convertToPublic()` calls `_mint(msg.sender, publicAmount)` at line 409 to deliver real ERC20 tokens.

```solidity
// PrivateUSDC -- user gets nothing
emit ConvertedToPublic(msg.sender, uint256(plainAmount));
// No _mint(), no transfer(), no safeTransfer() -- just an event

// PrivateOmniCoin -- user gets tokens
_mint(msg.sender, publicAmount);
emit ConvertedToPublic(msg.sender, publicAmount);
```

**Impact:** Users who convert to private and then back to public permanently lose their funds. The private balance is destroyed, but no public balance is created.

**Recommendation:** Add token delivery, either via `_mint()` (if ERC20) or `usdc.safeTransfer()` (if custodial).

---

### [H-03] No Pause Mechanism -- Cannot Stop Operations During Emergency

**Severity:** High
**Lines:** 41-46

**Description:**

PrivateUSDC does not inherit `PausableUpgradeable` and has no `pause()`/`unpause()` functions or `whenNotPaused` modifiers on any function. Compare with the sibling contract PrivateDEXSettlement which inherits PausableUpgradeable and applies `whenNotPaused` to settlement functions, and PrivateOmniCoin which also has full pausability.

If a vulnerability is discovered, the COTI MPC network goes down, or an exploit is in progress, there is no way to halt the contract's operations. The `bridgeMint`, `bridgeBurn`, `convertToPrivate`, `convertToPublic`, and `privateTransfer` functions are all unstoppable once deployed.

**Impact:** Inability to respond to security incidents. An active exploit cannot be halted by the admin.

**Recommendation:** Add `PausableUpgradeable` to the inheritance chain and apply `whenNotPaused` to all state-changing functions:

```solidity
contract PrivateUSDC is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,        // Add this
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    function convertToPrivate(uint256 amount)
        external nonReentrant whenNotPaused { ... }  // Add whenNotPaused
```

---

### [M-01] privateBalanceOf Exposes Encrypted Balances to All Callers

**Severity:** Medium
**Lines:** 335-339

**Description:**

`privateBalanceOf()` returns the encrypted balance (`ctUint64`) for any address to any caller. While the ciphertext cannot be directly decrypted by unauthorized parties (MPC prevents this), exposing ciphertext enables:

1. **Balance existence fingerprinting:** An attacker can determine whether an address has ever used the privacy feature by checking if their `ctUint64` is the zero ciphertext vs. a non-zero ciphertext.
2. **Balance change tracking:** By monitoring `privateBalanceOf()` before and after blocks, an observer can detect when a user's encrypted balance changes, correlating timing with on-chain events to deanonymize transfers.
3. **Ciphertext reuse attacks:** Depending on the MPC scheme, exposing ciphertext may enable chosen-ciphertext attacks if the same `ctUint64` is used across multiple operations.

Compare with PrivateOmniCoin's `decryptedPrivateBalanceOf()` which restricts decryption to the account owner or admin: `if (msg.sender != account && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert Unauthorized()`. PrivateUSDC has no such restriction on the encrypted balance view.

**Impact:** Partial privacy erosion. While amounts remain hidden, balance activity patterns are observable.

**Recommendation:** Consider restricting `privateBalanceOf()` to the account owner:

```solidity
function privateBalanceOf(
    address account
) external view returns (ctUint64) {
    if (msg.sender != account) revert Unauthorized();
    return encryptedBalances[account];
}
```

---

### [M-02] Shadow Ledger Is Public -- Defeats Privacy Purpose

**Severity:** Medium
**Lines:** 82-83

**Description:**

The `privateDepositLedger` mapping is declared as `public`, which means Solidity auto-generates a getter that allows anyone to call `privateDepositLedger(address)` and learn the exact plaintext amount a user has deposited into private mode:

```solidity
mapping(address => uint256) public privateDepositLedger;
```

This completely undermines privacy for deposits. If Alice converts 50,000 USDC to private, anyone can call `privateDepositLedger(alice)` and see `50000000000` (50,000 with 6 decimals). While `privateTransfer()` does not update the shadow ledger (which is correct for privacy), the deposit amounts are still fully visible.

The PrivateWETH and PrivateWBTC sibling contracts have the exact same issue -- all three declare `privateDepositLedger` as `public`.

**Impact:** Any observer can learn the exact deposit history for any address. For a contract designed specifically for privacy, this is a significant information leak.

**Recommendation:** Change visibility to `private` and add a restricted accessor:

```solidity
mapping(address => uint256) private privateDepositLedger;

function getPrivateDepositLedger(
    address account
) external view returns (uint256) {
    if (
        msg.sender != account &&
        !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)
    ) revert Unauthorized();
    return privateDepositLedger[account];
}
```

Note: Even with `private` visibility, the data is still readable from raw storage slots by anyone with blockchain access. True privacy would require encrypting the shadow ledger itself, but changing visibility at least removes the convenient public getter.

---

### [M-03] No Emergency Recovery Mechanism for MPC Unavailability

**Severity:** Medium
**Lines:** 76, 229-324

**Description:**

All private balance operations (`convertToPublic`, `privateTransfer`) require MPC precompile calls (`MpcCore.onBoard`, `MpcCore.decrypt`, `MpcCore.sub`, `MpcCore.ge`). If the COTI MPC network becomes unavailable -- due to maintenance, network partition, migration, or deprecation -- all funds stored in encrypted balances are permanently locked with no recovery path.

PrivateOmniCoin addresses this with `emergencyRecoverPrivateBalance()` (line 515-533), an admin function that:
1. Requires `privacyEnabled == false` (admin must disable privacy first)
2. Reads the shadow ledger for the user's deposit amount
3. Mints public tokens back to the user
4. Clears the shadow ledger entry

PrivateUSDC has the shadow ledger (line 82-83) but no emergency recovery function. The data exists to perform recovery, but no code path uses it.

**Impact:** Permanent loss of all private pUSDC balances if MPC becomes unavailable. Given that MPC is an external dependency outside OmniBazaar's control, this risk is not theoretical.

**Recommendation:** Add an emergency recovery function following the PrivateOmniCoin pattern:

```solidity
bool public privacyEnabled;

error PrivacyMustBeDisabled();
error NoBalanceToRecover();

function setPrivacyEnabled(bool enabled)
    external onlyRole(DEFAULT_ADMIN_ROLE) {
    privacyEnabled = enabled;
}

function emergencyRecoverPrivateBalance(address user)
    external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (privacyEnabled) revert PrivacyMustBeDisabled();
    if (user == address(0)) revert ZeroAddress();
    uint256 balance = privateDepositLedger[user];
    if (balance == 0) revert NoBalanceToRecover();
    privateDepositLedger[user] = 0;
    // Deliver tokens (via mint or transfer depending on design)
    emit EmergencyRecovery(user, balance);
}
```

---

### [M-04] bridgeMint Does Not Track Per-User Balances

**Severity:** Medium
**Lines:** 190-199

**Description:**

`bridgeMint()` accepts a `to` parameter but only updates the global `totalPublicSupply`. There is no per-user accounting for the public (non-private) balance. After a bridge mint, there is no way for the `to` address to prove they own these public tokens or for `convertToPrivate()` to verify the caller has sufficient public balance.

The `to` parameter is used only in the event emission. The function could be called with any address and the result would be identical -- just a global counter increment.

This means:
1. Bridge mints 1000 USDC to Alice (`bridgeMint(alice, 1000e6)`)
2. Bob calls `convertToPrivate(500e6)` and succeeds, even though he was never minted anything
3. There is no per-user public balance that gates conversion

**Impact:** Anyone can convert any amount to private, regardless of whether they were the bridge mint recipient. The `to` parameter provides a false sense of per-user tracking.

**Recommendation:** Add a per-user public balance mapping:

```solidity
mapping(address => uint256) public publicBalances;

function bridgeMint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
    // ...validation...
    publicBalances[to] += amount;
    totalPublicSupply += amount;
    emit BridgeMint(to, amount);
}

function convertToPrivate(uint256 amount) external nonReentrant {
    if (amount > publicBalances[msg.sender])
        revert InsufficientPublicBalance();
    publicBalances[msg.sender] -= amount;
    // ...rest of MPC logic...
}
```

---

### [L-01] Event Amount Parameters Indexed -- Wastes Gas and Hinders Filtering

**Severity:** Low
**Lines:** 97, 102, 107-110, 115-118

**Description:**

The `BridgeMint`, `BridgeBurn`, `ConvertedToPrivate`, and `ConvertedToPublic` events all index the `amount`/`publicAmount` parameter:

```solidity
event BridgeMint(address indexed to, uint256 indexed amount);
event BridgeBurn(address indexed from, uint256 indexed amount);
event ConvertedToPrivate(address indexed user, uint256 indexed amount);
event ConvertedToPublic(address indexed user, uint256 indexed amount);
```

Indexing `uint256` amounts is almost never useful because:
1. Filtering by exact amount is impractical (there are 2^256 possible values)
2. Indexed `uint256` values are stored as topic hashes, making range queries impossible
3. Each indexed parameter costs an additional ~375 gas per event emission
4. The values become harder to read in raw log output (stored as topics, not data)

**Recommendation:** Only index the `address` parameters. Move amounts to the data section:

```solidity
event BridgeMint(address indexed to, uint256 amount);
event ConvertedToPrivate(address indexed user, uint256 amount);
```

---

### [L-02] SCALING_FACTOR Constant Is Misleading -- Always 1

**Severity:** Low
**Lines:** 60

**Description:**

```solidity
uint256 public constant SCALING_FACTOR = 1;
```

The constant exists for consistency with PrivateWETH (`SCALING_FACTOR = 1e12`) and PrivateWBTC (`SCALING_FACTOR = 1e2`), but a scaling factor of 1 means no scaling occurs. `convertToPrivate()` never uses this constant -- it directly casts `uint64(amount)` without dividing by `SCALING_FACTOR`. The constant occupies storage awareness and code space without serving any purpose.

If a future developer relies on this constant for scaling calculations (as the sibling contracts do), they would get identity scaling that does nothing, which could mask bugs.

**Recommendation:** Either remove the constant entirely (since no scaling is needed), or add a comment explicitly stating it exists for cross-contract API consistency:

```solidity
/// @notice Scaling factor: USDC 6 decimals to MPC 6 decimals
/// @dev Value is 1 (identity) because USDC natively uses 6 decimals.
///      Exists for API parity with PrivateWETH/PrivateWBTC.
///      Not used in any calculation.
uint256 public constant SCALING_FACTOR = 1;
```

---

### [L-03] No privacyEnabled Guard -- MPC Calls Will Revert Opaquely on Non-COTI Chains

**Severity:** Low
**Lines:** 229-324

**Description:**

PrivateOmniCoin gates all privacy operations with `if (!privacyEnabled) revert PrivacyNotAvailable()` and has `_detectPrivacyAvailability()` to auto-detect COTI chains. PrivateUSDC has no such guard. On non-COTI chains (e.g., Hardhat, Ethereum, Avalanche C-Chain), MPC precompile calls (`MpcCore.setPublic64`, `MpcCore.onBoard`, etc.) will revert with opaque errors because the MPC precompile at address `0x64` does not exist.

Users calling `convertToPrivate()` on a non-COTI chain would see an unhelpful revert (likely "call to non-contract address" or similar EVM error) instead of a clear `PrivacyNotAvailable` error.

**Impact:** Poor developer/user experience on non-COTI deployments. No security impact beyond confusion.

**Recommendation:** Add a `privacyEnabled` state variable and guard:

```solidity
bool public privacyEnabled;

function convertToPrivate(uint256 amount) external nonReentrant {
    if (!privacyEnabled) revert PrivacyNotAvailable();
    // ...
}
```

---

### [L-04] bridgeBurn Does Not Verify Caller's Relationship to `from` Address

**Severity:** Low
**Lines:** 206-218

**Description:**

`bridgeBurn()` accepts a `from` parameter and emits `BridgeBurn(from, amount)`, but the `from` address is only used in:
1. The `ZeroAddress` check (line 210)
2. The event emission (line 217)

The function does not verify that `from` has a sufficient balance, nor does it debit any balance from `from`. It only decrements the global `totalPublicSupply`. Any bridge role holder can call `bridgeBurn(anyAddress, amount)` and the result is the same regardless of what `from` address is provided. The `from` parameter is cosmetic.

Combined with the fact that `bridgeMint` similarly does not credit `to` with any balance, the burn function has no meaningful relationship to the `from` address.

**Impact:** Misleading API. The emitted event suggests `from` had tokens burned, but no per-user state is modified.

**Recommendation:** Either add per-user balance tracking (as recommended in M-04) or document that `from` is an informational parameter only. If per-user balances are added:

```solidity
function bridgeBurn(address from, uint256 amount) external onlyRole(BRIDGE_ROLE) {
    // ...validation...
    if (amount > publicBalances[from]) revert InsufficientPublicBalance();
    publicBalances[from] -= amount;
    totalPublicSupply -= amount;
    emit BridgeBurn(from, amount);
}
```

---

### [I-01] Missing Privacy Conversion Fee Documentation

**Severity:** Informational
**Lines:** 35

**Description:**

The contract header NatSpec states: "Public to private conversion (no fee here; bridge charges 0.5%)". The 0.5% fee reference is correct for OmniPrivacyBridge's `PRIVACY_FEE_BPS = 50`. However, the earlier contract PrivateOmniCoin's audit (PrivateOmniCoin-audit-2026-02-21.md, H-01) documented a "double fee" issue where both the bridge and the privacy contract charged 0.3% each. The PrivateOmniCoin contract has since been fixed to charge zero fee, with the bridge handling the full 0.5%.

For PrivateUSDC, it is unclear whether:
1. The bridge for USDC (a separate contract from OmniPrivacyBridge which handles XOM/pXOM) also charges 0.5%, or
2. No bridge exists yet for USDC, and the fee documentation is speculative

The contract itself charges no fee, which is correct.

**Recommendation:** Clarify in NatSpec which bridge contract handles USDC deposits and what fee it charges. If no USDC bridge exists yet, state that explicitly.

---

### [I-02] Storage Gap Sizing -- 46 Slots May Be Insufficient

**Severity:** Informational
**Lines:** 88

**Description:**

The storage gap reserves 46 slots: `uint256[46] private __gap`. The contract has 4 declared state variables:
1. `encryptedBalances` (mapping -- 1 slot for the slot pointer)
2. `totalPublicSupply` (uint256 -- 1 slot)
3. `privateDepositLedger` (mapping -- 1 slot)
4. `_ossified` (bool -- 1 slot)

Total: 4 slots + 46 gap = 50 slots. This follows the OpenZeppelin convention of reserving 50 total slots per contract.

However, findings M-03 and M-04 recommend adding `privacyEnabled` (bool, 1 slot) and `publicBalances` (mapping, 1 slot), which would consume 2 gap slots, leaving 44. This is acceptable but should be tracked.

**Recommendation:** When adding new state variables in upgrades, decrease `__gap` correspondingly. Document the expected total (50) in a comment.

---

### [I-03] Redundant using Statements for gtBool

**Severity:** Informational
**Lines:** 49

**Description:**

```solidity
using MpcCore for gtBool;
```

The `gtBool` type is used only as a return value from `MpcCore.ge()` and as an argument to `MpcCore.decrypt()`. Both of these are called as static `MpcCore.ge()` and `MpcCore.decrypt()` rather than as methods on `gtBool` instances (e.g., `hasSufficient.decrypt()` is not used). The `using` statement for `gtBool` is therefore unused.

**Recommendation:** Remove the unused `using` directive for minor gas savings in deployment:

```solidity
using MpcCore for gtUint64;
using MpcCore for ctUint64;
// Remove: using MpcCore for gtBool;
```

---

## Comparison with Sibling Contracts

PrivateUSDC was reviewed alongside its sibling contracts PrivateWETH and PrivateWBTC. All three share the same structural issues (C-01, H-01, H-02, H-03, M-01 through M-04). The only significant differences are:

| Property | PrivateUSDC | PrivateWETH | PrivateWBTC |
|----------|-------------|-------------|-------------|
| Native decimals | 6 | 18 | 8 |
| Scaling factor | 1 (none) | 1e12 | 1e2 |
| Max private balance | ~18.4T USDC | ~18,446 ETH | ~18,446 BTC |
| Scaling dust loss | None | Up to 0.000001 ETH | Up to 0.01 sat |

PrivateUSDC benefits from USDC's native 6-decimal precision matching MPC's uint64 range, avoiding the scaling precision loss that affects PrivateWETH and PrivateWBTC. The maximum private balance of ~18.4 trillion USDC is effectively unlimited for practical purposes.

In contrast, PrivateOmniCoin (the most mature privacy contract in this family) has addressed all of these issues: it inherits ERC20, has `_burn`/`_mint` custody, includes `emergencyRecoverPrivateBalance()`, has `privacyEnabled` guards, and applies `whenNotPaused` to all privacy functions.

**Recommendation:** PrivateUSDC, PrivateWETH, and PrivateWBTC should be refactored to match the PrivateOmniCoin pattern -- either by inheriting from a shared base contract or by individually adding the missing functionality.

---

## Static Analysis Results

**Solhint:** 0 errors, 0 warnings (clean)

---

## Methodology

- Pass 1: Static analysis (solhint -- clean result)
- Pass 2A: Line-by-line manual code review against OWASP Smart Contract Top 10
- Pass 2B: Comparative analysis against PrivateOmniCoin (mature sibling), PrivateWETH, PrivateWBTC, PrivateDEXSettlement, and OmniPrivacyBridge
- Pass 3: Business logic & economic flow analysis (bridge mint/burn lifecycle, conversion round-trip, privacy guarantees)
- Pass 4: Access control and role analysis (BRIDGE_ROLE, DEFAULT_ADMIN_ROLE)
- Pass 5: Triage, deduplication, and severity classification
- Pass 6: Report generation

---

## Conclusion

PrivateUSDC has **one Critical vulnerability that makes the contract non-functional**:

1. **No token custody (C-01):** `bridgeMint()` and `convertToPrivate()` create encrypted balances without receiving, holding, or managing any actual USDC tokens. The contract is a privacy wrapper around nothing. This is not a minor oversight -- it requires fundamental redesign to either hold USDC via `transferFrom` or become an ERC20 token itself (like PrivateOmniCoin).

2. **No token delivery (H-01, H-02):** Both conversion directions are broken. `convertToPrivate` takes nothing from the user, and `convertToPublic` gives nothing back. The only real state change is the MPC encrypted balance manipulation.

3. **No emergency controls (H-03):** No pause mechanism, no privacy toggle, and no emergency recovery. If anything goes wrong, there is no way to stop operations or recover funds.

4. **Privacy leaks (M-01, M-02):** The public shadow ledger and unrestricted encrypted balance access undermine the privacy guarantees the contract is designed to provide.

**The contract should not be deployed in its current state.** It requires a fundamental rearchitecture to add token custody, matching the pattern established by PrivateOmniCoin. The sibling contracts PrivateWETH and PrivateWBTC share all of these issues and should be addressed simultaneously.

**Recommended priority for remediation:**
1. **C-01 + H-01 + H-02:** Add token custody (ERC20 inheritance or USDC custody via transferFrom)
2. **H-03:** Add PausableUpgradeable and whenNotPaused modifiers
3. **M-03:** Add emergency recovery using the shadow ledger
4. **M-04:** Add per-user public balance tracking
5. **M-01 + M-02:** Restrict encrypted balance and shadow ledger access
6. **L-01 through L-04:** Address in a polish pass

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
