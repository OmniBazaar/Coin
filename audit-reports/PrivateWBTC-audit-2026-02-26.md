# Security Audit Report: PrivateWBTC

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/privacy/PrivateWBTC.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 371
**Upgradeable:** Yes (UUPS)
**Handles Funds:** No (ledger-only -- no ERC20 token transfers; bridgeMint/bridgeBurn update internal accounting only)

## Executive Summary

PrivateWBTC is a UUPS-upgradeable privacy wrapper contract intended to enable WBTC holders to convert public 8-decimal WBTC balances into MPC-encrypted private balances (pWBTC) using COTI V2 garbled circuits. The contract scales WBTC's 8-decimal precision down by a factor of 100 to fit within MPC's uint64 6-decimal precision, supports bridge mint/burn, public-to-private and private-to-public conversion, and privacy-preserving encrypted transfers. A shadow ledger tracks deposits for emergency recovery.

The contract is structurally identical to its siblings PrivateWETH and PrivateUSDC, differing only in scaling factor (`1e2` for 8-to-6 decimal conversion) and token metadata. This audit confirms that **all Critical and High findings identified in the PrivateUSDC and PrivateWETH audits apply identically to PrivateWBTC**, and identifies one additional WBTC-specific finding related to the smaller scaling factor creating a larger relative dust loss for Bitcoin's higher unit value.

The fundamental flaw is that PrivateWBTC is a privacy wrapper with no underlying asset. The contract never receives, holds, locks, or transfers any WBTC tokens. `bridgeMint()` increments a counter but moves no tokens. `convertToPrivate()` creates encrypted MPC balances from nothing. `convertToPublic()` destroys encrypted balances but delivers nothing. The entire lifecycle operates on fictional balances. Compare this with PrivateOmniCoin, the mature sibling contract that correctly inherits ERC20Upgradeable and uses `_burn()`/`_mint()` to enforce real token custody.

| Severity | Count |
|----------|-------|
| Critical | 2 |
| High     | 3 |
| Medium   | 4 |
| Low      | 4 |
| Informational | 3 |

## Findings

### [C-01] No Actual Token Custody -- bridgeMint/bridgeBurn Are Pure Accounting Without Asset Backing

**Severity:** Critical
**Lines:** 190-218

**Description:**

`bridgeMint()` (line 190) increments `totalPublicSupply` and emits `BridgeMint`, but it never calls `IERC20(wbtc).transferFrom()` or receives any WBTC tokens. Similarly, `bridgeBurn()` (line 206) decrements `totalPublicSupply` and emits `BridgeBurn` but never transfers any WBTC out:

```solidity
function bridgeMint(
    address to,
    uint256 amount
) external onlyRole(BRIDGE_ROLE) {
    if (to == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();

    totalPublicSupply += amount;     // Counter incremented
    emit BridgeMint(to, amount);     // Event emitted
    // NO token transfer -- contract receives nothing
}
```

The contract has no WBTC token address stored, no `IERC20` import, no `transferFrom`/`transfer`/`safeTransfer` calls anywhere, and no `receive()` function. The `totalPublicSupply` counter is entirely decorative -- it does not represent any actual WBTC held by the contract.

This is the foundational design flaw from which C-02 follows. Since the contract never holds real WBTC, the entire conversion pipeline (bridgeMint -> convertToPrivate -> privateTransfer -> convertToPublic -> bridgeBurn) operates on fictional balances.

Compare with PrivateOmniCoin, which:
1. Inherits `ERC20Upgradeable` and IS a token
2. `convertToPrivate()` calls `_burn(msg.sender, amount)` to destroy real public tokens
3. `convertToPublic()` calls `_mint(msg.sender, publicAmount)` to create real public tokens

PrivateWBTC has none of this.

**Impact:** The contract cannot fulfill its stated purpose of wrapping real WBTC into private pWBTC. Any system that relies on `totalPublicSupply` as proof of reserves is operating on fabricated data. Given that WBTC trades at approximately $80,000-$100,000+ per unit, the financial impact of a misintegration is severe -- a bridge that assumes this contract holds custody of deposited WBTC would lose real BTC when users attempt to withdraw.

**Recommendation:** The contract must either:

1. **Hold WBTC directly**: Store the WBTC token address, call `IERC20(wbtc).safeTransferFrom(msg.sender, address(this), amount)` in `bridgeMint()`, and `IERC20(wbtc).safeTransfer(to, amount)` in `bridgeBurn()`. Add per-user public balance tracking.

2. **Become an ERC20** like PrivateOmniCoin: Inherit `ERC20Upgradeable`, mint pWBTC to the user on `bridgeMint`, burn pWBTC on `convertToPrivate`, mint on `convertToPublic`.

```solidity
// Option 1: Hold WBTC via custody
IERC20 public wbtcToken;
mapping(address => uint256) public publicBalances;

function bridgeMint(
    address to,
    uint256 amount
) external onlyRole(BRIDGE_ROLE) {
    if (to == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();
    wbtcToken.safeTransferFrom(msg.sender, address(this), amount);
    publicBalances[to] += amount;
    totalPublicSupply += amount;
    emit BridgeMint(to, amount);
}
```

---

### [C-02] convertToPrivate Creates Encrypted Balance Without Deducting Any On-Chain Asset

**Severity:** Critical
**Lines:** 230-253

**Description:**

`convertToPrivate()` scales an amount, encrypts it via MPC, and adds it to the caller's `encryptedBalances` -- but never deducts anything from the caller's public balance, nor does it transfer any tokens from the caller to the contract:

```solidity
function convertToPrivate(uint256 amount) external nonReentrant {
    if (amount == 0) revert ZeroAmount();

    uint256 scaledAmount = amount / SCALING_FACTOR;
    if (scaledAmount == 0) revert ZeroAmount();
    if (scaledAmount > type(uint64).max) revert AmountTooLarge();

    // Encrypt and add to balance -- no source deduction!
    gtUint64 gtAmount = MpcCore.setPublic64(uint64(scaledAmount));
    gtUint64 gtCurrent = MpcCore.onBoard(encryptedBalances[msg.sender]);
    gtUint64 gtNew = MpcCore.add(gtCurrent, gtAmount);
    encryptedBalances[msg.sender] = MpcCore.offBoard(gtNew);

    privateDepositLedger[msg.sender] += scaledAmount;
    emit ConvertedToPrivate(msg.sender, amount);
}
```

There is no `publicBalances[msg.sender] -= amount` check, no `totalPublicSupply -= amount` deduction, no `_burn(msg.sender, amount)`, and no `IERC20.transferFrom()`. Anyone can call `convertToPrivate(100000000)` (1 WBTC at 8 decimals) and receive a private pWBTC balance worth ~$90,000 without owning or spending any WBTC.

Combined with C-01 (no actual WBTC in the contract), this means:
1. User calls `convertToPrivate(100000000)` -- 1 WBTC, costs nothing, no tokens move
2. User now has encrypted balance of 1,000,000 (scaled) pWBTC
3. User calls `privateTransfer()` to move to another address
4. Recipient calls `convertToPublic()` -- emits event claiming 1 WBTC was "converted"
5. If any bridge trusts these events, it releases real WBTC that was never deposited

**Impact:** Unlimited private token creation. Any address can fabricate unlimited pWBTC balances. The encrypted balances have zero economic backing. At WBTC's market price, even small-scale exploitation would result in massive financial losses if integrated with a redemption path.

**Recommendation:** Maintain a per-user public balance (funded by `bridgeMint`) and deduct from it during conversion:

```solidity
function convertToPrivate(uint256 amount) external nonReentrant {
    if (amount == 0) revert ZeroAmount();
    if (amount > publicBalances[msg.sender])
        revert InsufficientPublicBalance();

    publicBalances[msg.sender] -= amount;
    totalPublicSupply -= amount;

    uint256 scaledAmount = amount / SCALING_FACTOR;
    if (scaledAmount == 0) revert ZeroAmount();
    if (scaledAmount > type(uint64).max) revert AmountTooLarge();

    // ... MPC operations ...
}
```

---

### [H-01] convertToPublic Does Not Deliver Tokens -- Conversion to Public Is a One-Way Burn

**Severity:** High
**Lines:** 259-287

**Description:**

`convertToPublic()` decrypts and subtracts from the caller's encrypted MPC balance, updates the shadow ledger, and emits `ConvertedToPublic` -- but does not transfer, mint, or credit any WBTC to the caller. The user's private balance is reduced, but they receive nothing in return:

```solidity
function convertToPublic(gtUint64 encryptedAmount) external nonReentrant {
    // ... balance check and MPC subtraction ...

    uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
    if (plainAmount == 0) revert ZeroAmount();

    // Scale back to 8 decimals
    uint256 publicAmount = uint256(plainAmount) * SCALING_FACTOR;

    // Update shadow ledger...
    // publicAmount is computed but NEVER assigned to any balance
    // No publicBalances[msg.sender] += publicAmount
    // No totalPublicSupply += publicAmount
    // No IERC20 transfer
    // No _mint()

    emit ConvertedToPublic(msg.sender, publicAmount);
    // Event claims WBTC was converted, but user receives nothing
}
```

Compare with PrivateOmniCoin line 409: `_mint(msg.sender, publicAmount)` -- the mature contract actually delivers tokens to the user. PrivateWBTC computes the amount but only uses it in the event emission.

**Impact:** Users who convert from private to public permanently lose their balance. The private MPC balance is destroyed, but no public balance is created. Given WBTC's high unit value, even a single accidental conversion of 1 WBTC results in ~$90,000 of irrecoverable loss.

**Recommendation:** Credit the user's public balance and make it withdrawable:

```solidity
publicBalances[msg.sender] += publicAmount;
totalPublicSupply += publicAmount;
emit ConvertedToPublic(msg.sender, publicAmount);
```

Or, if the contract becomes an ERC20: `_mint(msg.sender, publicAmount)`.

---

### [H-02] Shadow Ledger Desynchronization After Private Transfers -- Emergency Recovery Unreliable

**Severity:** High
**Lines:** 250, 280-284

**Description:**

The shadow ledger `privateDepositLedger` tracks deposits for emergency recovery, but `convertToPublic()` uses a floor-at-zero clamping pattern:

```solidity
// convertToPublic lines 280-284:
if (uint256(plainAmount) > privateDepositLedger[msg.sender]) {
    privateDepositLedger[msg.sender] = 0;   // Silent truncation
} else {
    privateDepositLedger[msg.sender] -= uint256(plainAmount);
}
```

This clamping is necessary because `privateTransfer()` (line 298) does not update the shadow ledger for either party. After any private transfer, the ledger becomes desynchronized:

1. Alice calls `convertToPrivate(1e8)` (1 WBTC) -- shadow ledger = 1,000,000 (scaled)
2. Bob sends Alice 500,000 via `privateTransfer()` -- Alice's MPC balance = 1,500,000, shadow still = 1,000,000
3. Alice calls `convertToPublic(1,500,000)` -- plainAmount (1.5M) > shadow (1M), so shadow is clamped to 0
4. In emergency recovery, Alice would recover 0 instead of her actual deposited balance
5. Bob's shadow ledger still shows his original deposit, enabling potential double-recovery

The ledger's stated purpose is emergency recovery when MPC becomes unavailable, but after any `privateTransfer()` operation, it becomes unreliable for this purpose.

**Impact:** Emergency recovery produces incorrect results after any private transfer. Deposit-heavy users over-recover while transfer-receiving users under-recover. Given that this is the only recovery mechanism and MPC availability is an external dependency, the impact during an actual MPC outage would be significant.

**Recommendation:** Either:
1. Update the shadow ledger during `privateTransfer()` (requires decrypting the amount, which leaks privacy), or
2. Remove the shadow ledger entirely and document that recovery requires MPC key reconstruction, or
3. Clearly document that the shadow ledger tracks only direct deposits, not transfers, and cannot be used for full balance recovery. Add NatSpec warnings on `emergencyRecoverPrivateBalance()` (if added) stating "Only deposit-originated balances are recoverable."

---

### [H-03] No Pause Mechanism -- Contract Cannot Be Emergency-Stopped

**Severity:** High
**Lines:** 41-46 (inheritance list)

**Description:**

PrivateWBTC does not inherit `PausableUpgradeable` and has no `pause()`/`unpause()` functions or `whenNotPaused` modifiers on any function. Compare with:

- **PrivateDEXSettlement**: Inherits `PausableUpgradeable`, has both `pause()`/`unpause()` and an `emergencyStop` flag
- **PrivateOmniCoin**: Inherits `ERC20PausableUpgradeable`, applies `whenNotPaused` to `convertToPrivate`, `convertToPublic`, and `privateTransfer`

If a vulnerability is discovered, the COTI MPC network goes down, or an exploit is in progress, there is no way to halt operations. All five state-changing functions (`bridgeMint`, `bridgeBurn`, `convertToPrivate`, `convertToPublic`, `privateTransfer`) are unstoppable once deployed. The only admin action available is `ossify()`, which permanently disables upgrades -- the opposite of what is needed in an emergency.

**Impact:** Inability to respond to security incidents. An active exploit cannot be halted. Given the Critical findings (C-01, C-02) that allow unlimited token fabrication, the lack of a pause mechanism means there is no way to stop exploitation even after discovery.

**Recommendation:** Add `PausableUpgradeable`:

```solidity
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract PrivateWBTC is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,            // Add this
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    function initialize(address admin) external initializer {
        // ...existing init calls...
        __Pausable_init();          // Add this
        // ...
    }

    function convertToPrivate(uint256 amount)
        external nonReentrant whenNotPaused { ... }  // Add whenNotPaused

    function convertToPublic(gtUint64 encryptedAmount)
        external nonReentrant whenNotPaused { ... }

    function privateTransfer(address to, gtUint64 encryptedAmount)
        external nonReentrant whenNotPaused { ... }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }
}
```

---

### [M-01] bridgeMint Does Not Track Per-User Balances -- `to` Parameter Is Cosmetic

**Severity:** Medium
**Lines:** 190-199

**Description:**

`bridgeMint()` accepts a `to` parameter but only updates the global `totalPublicSupply`. There is no per-user accounting for the public (non-private) balance. The `to` parameter is used only in the event emission:

```solidity
function bridgeMint(
    address to,
    uint256 amount
) external onlyRole(BRIDGE_ROLE) {
    if (to == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();

    totalPublicSupply += amount;     // Global counter only
    emit BridgeMint(to, amount);     // 'to' only used in event
}
```

This means:
1. Bridge mints 1 WBTC (1e8) to Alice: `bridgeMint(alice, 1e8)`
2. Bob calls `convertToPrivate(1e8)` and succeeds -- there is no check that Bob has any public balance
3. Alice's "minted" amount does not gate her conversion. Bob's conversion is not gated either.
4. The `to` parameter provides a false sense of per-user tracking

Similarly, `bridgeBurn()` accepts a `from` parameter (line 206) that is only used in validation (`ZeroAddress`) and event emission. No per-user balance is debited.

**Impact:** Bridge mint operations are not associated with specific users. Any address can convert any amount to private, regardless of whether tokens were minted for them. This enables front-running of bridge mints.

**Recommendation:** Add per-user public balance tracking:

```solidity
mapping(address => uint256) public publicBalances;

function bridgeMint(address to, uint256 amount)
    external onlyRole(BRIDGE_ROLE) {
    if (to == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();
    publicBalances[to] += amount;
    totalPublicSupply += amount;
    emit BridgeMint(to, amount);
}

function convertToPrivate(uint256 amount) external nonReentrant {
    if (amount > publicBalances[msg.sender])
        revert InsufficientPublicBalance();
    publicBalances[msg.sender] -= amount;
    totalPublicSupply -= amount;
    // ... MPC logic ...
}
```

---

### [M-02] Unchecked MPC Arithmetic -- MpcCore.add() Can Silently Overflow uint64

**Severity:** Medium
**Lines:** 246, 319-322

**Description:**

The contract uses `MpcCore.add()` in two locations without overflow checking:

1. `convertToPrivate()` line 246: `MpcCore.add(gtCurrent, gtAmount)` -- adding deposit to existing balance
2. `privateTransfer()` line 319-320: `MpcCore.add(gtRecipient, encryptedAmount)` -- adding to recipient balance

COTI V2's `MpcInterface.sol` provides both unchecked `Add()` and checked `CheckedAdd()` variants:

```solidity
// From MpcInterface.sol
function Add(bytes3, uint256, uint256) returns (uint256);
function CheckedAdd(bytes3, uint256, uint256) returns (uint256 overflowBit, uint256);
```

The unchecked `Add()` silently wraps on overflow. While the `type(uint64).max` check in `convertToPrivate()` (line 238) prevents single-deposit overflow, accumulated transfers via `privateTransfer()` have no such guard. A user receiving many private transfers could overflow their uint64 balance (max ~18,446,744,073,709,551,615 in 6-decimal scaled units, equivalent to ~18,446 BTC).

While 18,446 BTC is a large amount, it is not impossible on a live exchange. At current BTC prices, this represents roughly $1.5-1.8 billion in value -- within the range of large institutional positions or exchange aggregation accounts.

**Impact:** A user receiving many private transfers could silently overflow their encrypted balance, wrapping to a small value and losing funds. The attacker does not profit (the overflow destroys value), but the victim loses their balance.

**Recommendation:** Use `MpcCore.checkedAdd()` and handle the overflow bit:

```solidity
(gtBool overflow, gtUint64 gtNew) = MpcCore.checkedAdd(gtCurrent, gtAmount);
if (MpcCore.decrypt(overflow)) revert AmountTooLarge();
```

---

### [M-03] privateBalanceOf Exposes Encrypted Ciphertext to Any Caller

**Severity:** Medium
**Lines:** 336-339

**Description:**

`privateBalanceOf()` returns the encrypted balance (`ctUint64`) for any address to any caller, without access control:

```solidity
function privateBalanceOf(
    address account
) external view returns (ctUint64) {
    return encryptedBalances[account];
}
```

While the ciphertext cannot be directly decrypted by unauthorized parties (MPC prevents this), exposing ciphertext enables:

1. **Balance existence fingerprinting:** An attacker can determine whether an address has ever used the privacy feature by checking if their `ctUint64` is the zero ciphertext vs. a non-zero ciphertext.
2. **Balance change tracking:** By monitoring `privateBalanceOf()` before and after blocks, an observer can detect when a user's encrypted balance changes, correlating timing with on-chain events to deanonymize transfers.
3. **Ciphertext replay analysis:** If COTI MPC uses deterministic encryption for the same input (unlikely but implementation-dependent), equal ciphertexts would reveal equal balances.

Compare with PrivateOmniCoin's `decryptedPrivateBalanceOf()` which restricts decryption to the account owner or admin:

```solidity
if (msg.sender != account && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender))
    revert Unauthorized();
```

PrivateWBTC has no restriction on the encrypted balance view.

**Impact:** Partial privacy erosion. While encrypted amounts remain hidden, balance activity patterns are observable. For a contract designed specifically for privacy, this is a significant information leak. BTC's high visibility and the small pool of high-value BTC holders makes correlation attacks more practical than for lower-value tokens.

**Recommendation:** Restrict `privateBalanceOf()` to the account owner or authorized parties:

```solidity
error Unauthorized();

function privateBalanceOf(
    address account
) external view returns (ctUint64) {
    if (msg.sender != account &&
        !hasRole(DEFAULT_ADMIN_ROLE, msg.sender))
        revert Unauthorized();
    return encryptedBalances[account];
}
```

---

### [M-04] No Emergency Recovery Mechanism for MPC Unavailability

**Severity:** Medium
**Lines:** 76, 230-325

**Description:**

All private balance operations (`convertToPublic`, `privateTransfer`) require COTI MPC precompile calls (`MpcCore.onBoard`, `MpcCore.decrypt`, `MpcCore.sub`, `MpcCore.ge`). If the COTI MPC network becomes unavailable -- due to maintenance, network partition, migration, or deprecation -- all funds stored in encrypted balances are permanently locked with no recovery path.

PrivateOmniCoin addresses this with:
1. `privacyEnabled` state variable (line 131) gating all MPC operations
2. `setPrivacyEnabled(bool)` admin function (line 496)
3. `emergencyRecoverPrivateBalance(address)` (lines 515-533) that reads the shadow ledger and mints public tokens back to the user when privacy is disabled

PrivateWBTC has the shadow ledger (line 82-83) but:
- No `privacyEnabled` guard
- No `setPrivacyEnabled()` function
- No `emergencyRecoverPrivateBalance()` function

The data for recovery exists, but no code path uses it.

**Impact:** Permanent loss of all private pWBTC balances if MPC becomes unavailable. Given that MPC is an external dependency outside OmniBazaar's control, and given WBTC's high unit value (~$90,000+), even a small number of locked balances represents substantial financial loss.

**Recommendation:** Add emergency recovery following the PrivateOmniCoin pattern:

```solidity
bool public privacyEnabled;

error PrivacyNotAvailable();
error PrivacyMustBeDisabled();
error NoBalanceToRecover();

event EmergencyPrivateRecovery(address indexed user, uint256 indexed publicAmount);

function setPrivacyEnabled(bool enabled)
    external onlyRole(DEFAULT_ADMIN_ROLE) {
    privacyEnabled = enabled;
}

function emergencyRecoverPrivateBalance(address user)
    external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (privacyEnabled) revert PrivacyMustBeDisabled();
    if (user == address(0)) revert ZeroAddress();
    uint256 scaledBalance = privateDepositLedger[user];
    if (scaledBalance == 0) revert NoBalanceToRecover();
    privateDepositLedger[user] = 0;
    uint256 publicAmount = scaledBalance * SCALING_FACTOR;
    // Credit public balance or transfer tokens
    publicBalances[user] += publicAmount;
    totalPublicSupply += publicAmount;
    emit EmergencyPrivateRecovery(user, publicAmount);
}
```

---

### [L-01] Shadow Ledger Is Public -- Defeats Privacy Purpose

**Severity:** Low
**Lines:** 82-83

**Description:**

The `privateDepositLedger` mapping is declared as `public`, meaning Solidity auto-generates a getter:

```solidity
mapping(address => uint256) public privateDepositLedger;
```

Anyone can call `privateDepositLedger(address)` and learn the exact plaintext amount a user has deposited into private mode. If Alice converts 1 WBTC (100,000,000 in 8-decimal units) to private, the shadow ledger stores `1000000` (scaled to 6 decimals). Anyone calling `privateDepositLedger(alice)` sees this value and can trivially reverse the scaling to determine Alice deposited 1 WBTC.

For a contract whose sole purpose is privacy, exposing exact deposit history in plaintext is a fundamental information leak. The siblings PrivateWETH and PrivateUSDC have the same issue.

Note: Even with `private` visibility, the data is readable from raw storage slots via `eth_getStorageAt`. Changing visibility removes the convenient public getter but does not provide true privacy. True privacy would require encrypting the shadow ledger itself.

**Impact:** Any observer can learn the exact deposit history for any address. Combined with M-03 (ciphertext change tracking), an observer can correlate deposit amounts with balance changes to fully deanonymize a user's private activity.

**Recommendation:** Change visibility to `private` and add a restricted accessor:

```solidity
mapping(address => uint256) private privateDepositLedger;

function getPrivateDepositLedger(
    address account
) external view returns (uint256) {
    if (msg.sender != account &&
        !hasRole(DEFAULT_ADMIN_ROLE, msg.sender))
        revert Unauthorized();
    return privateDepositLedger[account];
}
```

---

### [L-02] WBTC-Specific Scaling Dust Loss Is Economically Significant at High BTC Prices

**Severity:** Low
**Lines:** 60, 236, 277

**Description:**

PrivateWBTC uses `SCALING_FACTOR = 1e2` (100) to scale from 8-decimal WBTC to 6-decimal MPC precision. A round-trip conversion loses up to `SCALING_FACTOR - 1 = 99` of the smallest WBTC unit (satoshi) per conversion:

```solidity
// convertToPrivate:
uint256 scaledAmount = amount / SCALING_FACTOR;  // Floor division
// convertToPublic:
uint256 publicAmount = uint256(plainAmount) * SCALING_FACTOR;  // Scale back
```

Example worst-case:
- User converts `199` satoshi (0.00000199 WBTC)
- Scaled: `199 / 100 = 1` (6-decimal units)
- Converted back: `1 * 100 = 100` satoshi
- Lost: `99` satoshi = 0.00000099 WBTC

At $90,000/BTC, 99 satoshi is approximately $0.089 -- negligible for a single conversion. However:
- The minimum convertible amount is 100 satoshi (0.000001 BTC = ~$0.09). Amounts below this scale to 0 and revert.
- Amounts between 100 and 199 satoshi lose up to 49.5% of their value.
- Users making many small conversions accumulate dust losses.
- The dust is permanently unrecoverable (it does not go to any fee pool or recovery mechanism).

Compare scaling factors across the privacy wrapper family:

| Contract | Scaling Factor | Max Dust Loss | Max Dust $ Value |
|----------|---------------|---------------|-----------------|
| PrivateUSDC | 1 (none) | 0 | $0.00 |
| PrivateWBTC | 1e2 | 99 satoshi | ~$0.089 |
| PrivateWETH | 1e12 | ~1e12 wei | ~$0.002 |
| PrivateOmniCoin | 1e12 | ~1e12 wei | negligible |

While the NatSpec (line 28) states "Rounding dust (up to 0.01 satoshi) is acceptable," this is incorrect. The maximum dust loss is 99 satoshi (0.99 of the smallest displayable WBTC unit), not 0.01 satoshi. The NatSpec comment appears to confuse satoshi (the smallest BTC unit) with the contract's scaled precision.

**Impact:** Minor economic loss per conversion, but misleading documentation could cause users to underestimate the dust loss. For high-frequency micro-conversions, losses accumulate.

**Recommendation:**

1. Fix the NatSpec to accurately state maximum dust loss:
```solidity
/// @dev WBTC uses 8 decimals; scaled down by 1e2 to fit MPC
///      6-decimal precision. Scaling factor = 100.
///      Maximum rounding dust per conversion: 99 satoshi (~$0.09 at $90K BTC).
///      Minimum convertible amount: 100 satoshi (0.000001 BTC).
```

2. Consider tracking and refunding dust:
```solidity
mapping(address => uint256) public dustBalance;

function convertToPrivate(uint256 amount) external nonReentrant {
    // ...
    uint256 scaledAmount = amount / SCALING_FACTOR;
    uint256 dust = amount - (scaledAmount * SCALING_FACTOR);
    if (dust > 0) {
        dustBalance[msg.sender] += dust;
    }
    // ...
}
```

---

### [L-03] Event Amount Parameters Are Indexed -- Wastes Gas and Hinders Filtering

**Severity:** Low
**Lines:** 97, 102, 107-110, 115-118

**Description:**

All four events index the `amount`/`publicAmount` parameter:

```solidity
event BridgeMint(address indexed to, uint256 indexed amount);
event BridgeBurn(address indexed from, uint256 indexed amount);
event ConvertedToPrivate(address indexed user, uint256 indexed publicAmount);
event ConvertedToPublic(address indexed user, uint256 indexed publicAmount);
```

Indexing `uint256` amounts is an anti-pattern because:
1. Filtering by exact amount is impractical (there are 2^256 possible values)
2. Each indexed parameter costs ~375 additional gas per event emission
3. Range queries on indexed `uint256` are impossible in EVM logs
4. Addresses should be indexed; amounts generally should not

Additionally, for a privacy-focused contract, indexing amounts as topics makes them more prominent in blockchain explorers and log analysis tools, marginally reducing the privacy of public-facing operations.

**Recommendation:** Remove `indexed` from amount parameters:

```solidity
event BridgeMint(address indexed to, uint256 amount);
event BridgeBurn(address indexed from, uint256 amount);
event ConvertedToPrivate(address indexed user, uint256 publicAmount);
event ConvertedToPublic(address indexed user, uint256 publicAmount);
```

---

### [L-04] Admin Receives Both DEFAULT_ADMIN_ROLE and BRIDGE_ROLE at Initialization

**Severity:** Low
**Lines:** 177-178

**Description:**

The `initialize()` function grants the same `admin` address both `DEFAULT_ADMIN_ROLE` and `BRIDGE_ROLE`:

```solidity
_grantRole(DEFAULT_ADMIN_ROLE, admin);
_grantRole(BRIDGE_ROLE, admin);
```

This means a single compromised key can:
1. Mint unlimited `totalPublicSupply` via `bridgeMint()`
2. Burn all `totalPublicSupply` via `bridgeBurn()`
3. Grant `BRIDGE_ROLE` to any additional address
4. Ossify the contract to prevent remediation

The intended design is for `BRIDGE_ROLE` to be held by the bridge contract (OmniBridge), not by a human admin. Granting it to the admin creates a window of excessive privilege between deployment and role transfer.

**Impact:** Single point of failure during the period between deployment and role transfer to the bridge contract. Given C-01 (no real token custody), this is less impactful than it would be in a contract that actually holds assets, but it represents poor separation of concerns.

**Recommendation:** Do not grant `BRIDGE_ROLE` in `initialize()`. Have the admin grant it to the bridge contract explicitly after deployment:

```solidity
function initialize(address admin) external initializer {
    // ...
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    // BRIDGE_ROLE not granted -- admin grants to bridge contract later
}
```

---

### [I-01] No Test Suite Exists for PrivateWBTC

**Severity:** Informational

**Description:**

A search of the entire `Coin/` directory for "PrivateWBTC" returns only the contract file itself and references in sibling audit reports. No unit tests, integration tests, or deployment scripts reference this contract.

Given the Critical-severity findings (C-01, C-02), basic tests would have caught these immediately. A simple test asserting that `convertToPrivate()` reduces a source balance (or that calling it without prior `bridgeMint()` for the same address reverts) would have revealed the missing balance deduction.

**Recommendation:** Create a comprehensive test suite covering:
- Bridge mint/burn with actual token custody verification
- `convertToPrivate` requires sufficient public balance
- `convertToPublic` credits a public balance or delivers tokens
- Private transfer between two accounts
- Round-trip conversion dust loss verification
- Overflow scenarios on MPC arithmetic
- UUPS upgrade authorization and ossification
- Role management and separation of bridge/admin roles
- Emergency pause and recovery scenarios

---

### [I-02] Contract Is Structurally Identical to PrivateUSDC and PrivateWETH -- Should Use Shared Base Contract

**Severity:** Informational

**Description:**

PrivateWBTC, PrivateWETH, and PrivateUSDC share 95%+ identical code. The only differences are:

| Property | PrivateWBTC | PrivateWETH | PrivateUSDC |
|----------|-------------|-------------|-------------|
| Native decimals | 8 | 18 | 6 |
| Scaling factor | 1e2 | 1e12 | 1 (none) |
| Token name/symbol | Private WBTC / pWBTC | Private WETH / pWETH | Private USDC / pUSDC |
| Max private balance | ~18,446 BTC | ~18,446 ETH | ~18.4T USDC |
| Max dust loss | 99 satoshi | ~1e12 wei | 0 |

The Critical findings C-01 and C-02 apply identically to all three contracts, confirming that code duplication propagates vulnerabilities. A fix applied to one contract must be manually replicated to the other two, creating risk of divergence.

**Recommendation:** Extract a shared base contract:

```solidity
abstract contract PrivateTokenWrapperBase is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // All shared logic (bridge, conversion, transfer, recovery)
    function _scalingFactor() internal pure virtual returns (uint256);
    function _tokenDecimals() internal pure virtual returns (uint8);
    // ...
}

contract PrivateWBTC is PrivateTokenWrapperBase {
    function _scalingFactor() internal pure override returns (uint256) {
        return 1e2;
    }
    function _tokenDecimals() internal pure override returns (uint8) {
        return 8;
    }
}
```

---

### [I-03] No privacyEnabled Guard -- MPC Calls Revert Opaquely on Non-COTI Chains

**Severity:** Informational
**Lines:** 230-325

**Description:**

PrivateOmniCoin gates all privacy operations with `if (!privacyEnabled) revert PrivacyNotAvailable()` and has `_detectPrivacyAvailability()` to auto-detect COTI chains by chain ID. PrivateWBTC has no such guard.

On non-COTI chains (e.g., Hardhat local node, Ethereum mainnet, Avalanche C-Chain), MPC precompile calls (`MpcCore.setPublic64`, `MpcCore.onBoard`, etc.) will revert with opaque errors because the MPC precompile at address `0x64` does not exist. Users calling `convertToPrivate()` on a non-COTI chain would see an unhelpful revert (likely "call to non-contract address" or similar EVM error) instead of a clear `PrivacyNotAvailable` error.

**Impact:** Poor developer/user experience on non-COTI deployments. No security impact beyond confusion. Also prevents the contract from being meaningfully tested on Hardhat.

**Recommendation:** Add a `privacyEnabled` state variable with auto-detection:

```solidity
bool public privacyEnabled;

function convertToPrivate(uint256 amount) external nonReentrant {
    if (!privacyEnabled) revert PrivacyNotAvailable();
    // ...
}

function _detectPrivacyAvailability() private view returns (bool) {
    return (
        block.chainid == 13068200 || // COTI Devnet
        block.chainid == 7082400 ||  // COTI Testnet
        block.chainid == 7082 ||     // COTI Testnet (alt)
        block.chainid == 1353 ||     // COTI Mainnet
        block.chainid == 131313      // OmniCoin L1
    );
}
```

---

## Comparison with Sibling Contracts

PrivateWBTC was reviewed alongside PrivateUSDC and PrivateWETH, and compared against the mature PrivateOmniCoin contract. All three privacy wrappers share the same structural deficiencies:

| Feature | PrivateOmniCoin | PrivateWBTC | PrivateWETH | PrivateUSDC |
|---------|----------------|-------------|-------------|-------------|
| Token custody | ERC20 `_burn`/`_mint` | None | None | None |
| Per-user public balance | ERC20 `balanceOf` | None | None | None |
| Pausability | `ERC20PausableUpgradeable` | None | None | None |
| Privacy toggle | `privacyEnabled` + auto-detect | None | None | None |
| Emergency recovery | `emergencyRecoverPrivateBalance()` | None | None | None |
| `whenNotPaused` modifiers | All privacy functions | None | None | None |
| Supply cap | `MAX_SUPPLY` (16.6B XOM) | None | None | None |
| Total private supply tracking | `totalPrivateSupply` (encrypted) | None | None | None |
| Shadow ledger visibility | `public` (same issue) | `public` | `public` | `public` |
| Balance query access control | Owner/admin restricted | Unrestricted | Unrestricted | Unrestricted |

PrivateWBTC has no features that PrivateOmniCoin does not also have, and it is missing every safety feature that PrivateOmniCoin includes. The three privacy wrappers appear to have been created from a minimal template without incorporating the security mechanisms that were developed for the more mature PrivateOmniCoin.

---

## Static Analysis Results

**Solhint:** 0 errors, 0 warnings (clean)

The contract follows proper ordering conventions (with inline `solhint-disable-line` comments where needed), uses custom errors instead of require strings, and has complete NatSpec documentation.

**Slither/Aderyn:** Not run (COTI MPC precompile dependencies not available in standard analysis environments)

---

## Methodology

- Pass 1: Static analysis (solhint -- clean result)
- Pass 2A: Line-by-line manual code review against OWASP Smart Contract Top 10 -- Access Control (SC01), Arithmetic (SC02), Reentrancy (SC04), Denial of Service (SC06), Oracle/Bridge (SC07)
- Pass 2B: Business logic and economic flow analysis -- Token custody model, bridge mint/burn lifecycle, conversion round-trip integrity, scaling precision, cross-contract integration
- Pass 3: Comparative analysis against PrivateOmniCoin (mature reference), PrivateWETH (audited sibling), PrivateUSDC (audited sibling), PrivateDEXSettlement, and OmniPrivacyBridge
- Pass 4: MPC-specific analysis -- Checked vs. unchecked arithmetic, ciphertext exposure, privacy leakage vectors, COTI V2 precompile compatibility
- Pass 5: WBTC-specific analysis -- 8-decimal scaling precision, BTC price impact on dust loss, maximum balance limits relative to BTC market cap
- Pass 6: Triage, deduplication, severity classification, and report generation

---

## Conclusion

PrivateWBTC has **two Critical vulnerabilities that render the contract non-functional for its stated purpose**:

1. **No token custody (C-01)** -- The contract never receives, holds, or transfers any WBTC tokens. `bridgeMint()` and `bridgeBurn()` are pure counter operations with no asset backing. The contract is a ledger without a treasury.

2. **Free private minting (C-02)** -- `convertToPrivate()` creates encrypted MPC balances without deducting from any source. Any address can create unlimited private pWBTC without depositing anything. At WBTC's market price of ~$90,000+ per unit, even small-scale exploitation would cause massive financial losses if integrated with a redemption path.

3. **No token delivery (H-01)** -- `convertToPublic()` destroys private MPC balance without creating or delivering any public balance. Users who convert from private to public lose their funds permanently.

4. **Unreliable emergency recovery (H-02)** -- The shadow ledger, the only recovery mechanism, desynchronizes after any `privateTransfer()` operation, making its stated purpose unachievable.

5. **No emergency controls (H-03)** -- No pause mechanism, no privacy toggle, and no emergency recovery function. If anything goes wrong, there is no way to stop operations or recover funds.

**The contract must not be deployed in its current state.** It requires fundamental redesign to add token custody, matching the pattern established by PrivateOmniCoin. The sibling contracts PrivateWETH and PrivateUSDC share identical deficiencies.

**Recommended remediation priority:**
1. **C-01 + C-02 + H-01:** Add token custody (ERC20 inheritance with `_burn`/`_mint`, or WBTC custody via `safeTransferFrom`/`safeTransfer`). Add per-user public balance tracking.
2. **H-03:** Add `PausableUpgradeable` and `whenNotPaused` modifiers to all state-changing functions.
3. **M-04:** Add `privacyEnabled` guard, `setPrivacyEnabled()`, and `emergencyRecoverPrivateBalance()` following the PrivateOmniCoin pattern.
4. **M-02:** Use `MpcCore.checkedAdd()` instead of `MpcCore.add()` to prevent silent uint64 overflow.
5. **M-01:** Add per-user public balance tracking to make `bridgeMint`'s `to` parameter meaningful.
6. **M-03 + L-01:** Restrict `privateBalanceOf()` and `privateDepositLedger` access to account owners.
7. **I-02:** Extract shared base contract to eliminate code duplication across the three privacy wrappers and prevent future vulnerability propagation.
8. **I-01:** Create comprehensive test suite before any deployment.
9. **L-02 through L-04:** Address in a polish pass.

**Positive Observations:**
- Clean solhint output (0 errors, 0 warnings)
- Proper use of `_disableInitializers()` in constructor
- Correct UUPS upgrade pattern with ossification
- `ReentrancyGuardUpgradeable` applied to all state-changing user functions
- Zero-address validation on all address parameters
- Self-transfer prevention in `privateTransfer()`
- Good NatSpec documentation coverage (aside from the dust loss inaccuracy in L-02)
- Appropriate storage gap (46 slots + 4 state variables = 50 total) for upgradeability

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
