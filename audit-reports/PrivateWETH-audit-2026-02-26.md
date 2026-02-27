# Security Audit Report: PrivateWETH

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/privacy/PrivateWETH.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 372
**Upgradeable:** Yes (UUPS)
**Handles Funds:** No (ledger-only -- no ERC20 token transfers, bridgeMint/bridgeBurn update internal accounting only)

## Executive Summary

PrivateWETH is a UUPS-upgradeable privacy-preserving WETH wrapper built on COTI V2 MPC garbled circuits. It provides bridge mint/burn for cross-chain WETH deposits, public-to-private conversion (scaling 18-decimal WETH down to 6-decimal MPC precision), private-to-public conversion, and privacy-preserving encrypted transfers. The contract uses OpenZeppelin's AccessControlUpgradeable, ReentrancyGuardUpgradeable, and UUPSUpgradeable.

The contract is structurally identical to its sibling contracts PrivateWBTC and PrivateUSDC, differing only in scaling factor (1e12 for 18-to-6 decimal conversion) and token metadata. This shared architecture means many findings apply across the entire privacy wrapper family.

The audit found **2 Critical vulnerabilities**: (1) `bridgeMint` is a pure accounting function that emits an event and increments `totalPublicSupply` but never actually receives or holds any WETH tokens -- the "minted" balance exists only as a counter with no enforced backing, and no mechanism ensures the user's WETH is actually locked before private conversion occurs; (2) `convertToPrivate` creates encrypted MPC balance without deducting from any on-chain token balance -- users receive private pWETH without surrendering anything, enabling infinite minting of private tokens. Both of these stem from the contract being a pure ledger with no token interaction, yet being designed as if it holds and manages real assets.

| Severity | Count |
|----------|-------|
| Critical | 2 |
| High     | 3 |
| Medium   | 4 |
| Low      | 3 |
| Informational | 3 |

## Findings

### [C-01] No Actual Token Custody -- bridgeMint/bridgeBurn Are Pure Accounting Without Asset Backing

**Severity:** Critical
**Lines:** 190-218
**Agents:** Both

**Description:**

`bridgeMint()` (line 190) increments `totalPublicSupply` and emits `BridgeMint`, but it never calls `IERC20(weth).transferFrom()` or receives any WETH tokens. Similarly, `bridgeBurn()` (line 206) decrements `totalPublicSupply` and emits `BridgeBurn` but never transfers any WETH out.

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

The contract has no `receive()` function, no WETH token address stored, no `IERC20` import, and no `transferFrom`/`transfer` calls anywhere. The `totalPublicSupply` counter is entirely decorative -- it does not represent any actual asset held by the contract.

This is the foundational design flaw from which C-02 follows: since the contract never holds real WETH, the entire conversion pipeline (bridgeMint -> convertToPrivate -> privateTransfer -> convertToPublic -> bridgeBurn) is operating on fictional balances.

**Impact:** The contract cannot fulfill its stated purpose of wrapping real WETH into private pWETH. Any system that relies on `totalPublicSupply` as proof of reserves is operating on fabricated data. If integrated with a bridge that assumes this contract holds custody of deposited WETH, users will lose funds when attempting to withdraw.

**Recommendation:** The contract must either:
1. **Hold WETH directly**: Store the WETH token address, call `IERC20(weth).transferFrom(msg.sender, address(this), amount)` in `bridgeMint()`, and `IERC20(weth).transfer(to, amount)` in `bridgeBurn()`.
2. **Operate as a sub-module** of an external bridge that handles custody: In this case, the bridge contract must enforce custody, and PrivateWETH's documentation must make clear it is NOT a standalone privacy wrapper but a dependent ledger component. The current NatSpec does not indicate this dependency.

```solidity
// Option 1: Add WETH custody
IERC20 public wethToken;

function bridgeMint(
    address to,
    uint256 amount
) external onlyRole(BRIDGE_ROLE) {
    if (to == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();

    wethToken.safeTransferFrom(msg.sender, address(this), amount);
    totalPublicSupply += amount;
    // Record per-user public balance for convertToPrivate
    publicBalances[to] += amount;
    emit BridgeMint(to, amount);
}
```

---

### [C-02] convertToPrivate Creates Encrypted Balance Without Deducting Any On-Chain Asset

**Severity:** Critical
**Lines:** 230-254
**Agents:** Both

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

There is no `publicBalances[msg.sender] -= scaledAmount` check, no `totalPublicSupply -= amount` deduction, and no token transfer. Anyone can call `convertToPrivate()` with any amount and receive that amount in encrypted MPC balance, effectively minting private tokens from nothing.

Combined with C-01 (no actual WETH in the contract), this means:
1. User calls `convertToPrivate(1000 ether)` -- costs nothing, no tokens move
2. User now has encrypted balance of 1,000,000 (scaled) pWETH
3. User calls `privateTransfer()` to move to another address
4. Recipient calls `convertToPublic()` -- emits event claiming 1000 WETH was "converted"
5. If any bridge trusts these events, it releases real WETH that was never deposited

**Impact:** Unlimited private token creation. The entire privacy guarantee is meaningless because the encrypted balances have no economic backing. Any integration that treats pWETH as redeemable for real WETH will result in loss of funds.

**Recommendation:** Maintain a per-user public balance (funded by `bridgeMint`) and deduct from it during conversion:

```solidity
mapping(address => uint256) public publicBalances;

function convertToPrivate(uint256 amount) external nonReentrant {
    if (amount == 0) revert ZeroAmount();
    if (amount > publicBalances[msg.sender])
        revert InsufficientPublicBalance();

    publicBalances[msg.sender] -= amount;

    uint256 scaledAmount = amount / SCALING_FACTOR;
    if (scaledAmount == 0) revert ZeroAmount();
    if (scaledAmount > type(uint64).max) revert AmountTooLarge();

    // ... MPC operations ...
}
```

---

### [H-01] convertToPublic Does Not Credit Any On-Chain Balance -- Tokens Cannot Be Redeemed

**Severity:** High
**Lines:** 260-288
**Agents:** Both

**Description:**

The mirror issue of C-02: `convertToPublic()` decrypts and subtracts from the MPC balance, updates the shadow ledger, and emits a `ConvertedToPublic` event -- but never credits any public balance to the user, never increases `totalPublicSupply`, and never transfers any tokens:

```solidity
function convertToPublic(gtUint64 encryptedAmount) external nonReentrant {
    // ... balance check and subtraction ...
    uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
    if (plainAmount == 0) revert ZeroAmount();

    uint256 publicAmount = uint256(plainAmount) * SCALING_FACTOR;

    // Shadow ledger update...
    // publicAmount is computed but NEVER assigned to any balance
    // No publicBalances[msg.sender] += publicAmount
    // No totalPublicSupply += publicAmount
    // No token transfer

    emit ConvertedToPublic(msg.sender, publicAmount);
}
```

The `publicAmount` variable is computed but only used in the event emission. The user's MPC balance is reduced, but they receive nothing in return. The converted WETH value simply vanishes.

**Impact:** Users who convert from private to public lose their tokens permanently. The function is economically destructive -- it destroys private balance without creating any corresponding public balance. If this contract were deployed and users converted to public, their WETH would be irrecoverably lost.

**Recommendation:** Credit the user's public balance and make it withdrawable:

```solidity
publicBalances[msg.sender] += publicAmount;
emit ConvertedToPublic(msg.sender, publicAmount);
```

---

### [H-02] Shadow Ledger Desynchronization -- privateDepositLedger Can Go Negative via Underflow Clamping

**Severity:** High
**Lines:** 251, 280-285
**Agents:** Both

**Description:**

The shadow ledger `privateDepositLedger` tracks deposits for emergency recovery, but the `convertToPublic()` function uses a floor-at-zero clamping pattern instead of enforcing balance invariants:

```solidity
// convertToPublic lines 280-285:
if (uint256(plainAmount) > privateDepositLedger[msg.sender]) {
    privateDepositLedger[msg.sender] = 0;   // Silent truncation
} else {
    privateDepositLedger[msg.sender] -= uint256(plainAmount);
}
```

This clamping is necessary because the shadow ledger can already be desynchronized:
1. Alice calls `convertToPrivate(100 ether)` -- shadow ledger = 100,000,000 (scaled)
2. Bob sends Alice 50,000,000 via `privateTransfer()` -- Alice's MPC balance = 150,000,000, shadow still = 100,000,000
3. Alice calls `convertToPublic(150,000,000)` -- plainAmount (150M) > shadow (100M), so shadow is clamped to 0

The shadow ledger now shows 0, but Alice legitimately had 50M of Bob's transferred balance. If the shadow ledger is ever used for emergency recovery (its stated purpose), Alice would recover 0 instead of her actual balance. Conversely, Bob's shadow ledger still shows his original deposit, so he could potentially double-recover.

The `privateTransfer()` function (line 299) does not update the shadow ledger for either party, making the ledger unreliable after any transfer.

**Impact:** The shadow ledger's stated purpose (emergency recovery) is undermined by any `privateTransfer()` operation. In an emergency recovery scenario, deposit-heavy users would over-recover and transfer-receiving users would under-recover.

**Recommendation:** Either:
1. Update the shadow ledger in `privateTransfer()` (but this leaks transfer amounts, breaking privacy), or
2. Remove the shadow ledger entirely and document that emergency recovery requires MPC key reconstruction, or
3. Clearly document that the shadow ledger tracks only direct deposits, not transfers, and cannot be used for full balance recovery

---

### [H-03] Rounding Dust Loss on Conversion Round-Trip -- Up to 999,999,999,999 Wei Lost Per Conversion

**Severity:** High
**Lines:** 236, 278
**Agents:** Both

**Description:**

The 18-to-6 decimal scaling uses integer division in `convertToPrivate()`:

```solidity
uint256 scaledAmount = amount / SCALING_FACTOR;  // SCALING_FACTOR = 1e12
```

And the reverse scaling in `convertToPublic()`:

```solidity
uint256 publicAmount = uint256(plainAmount) * SCALING_FACTOR;
```

A round-trip conversion loses up to `SCALING_FACTOR - 1 = 999,999,999,999` wei per conversion. For example:
- User converts `1.999999999999 ETH` (1,999,999,999,999 wei)
- Scaled: `1,999,999,999,999 / 1e12 = 1` (6-decimal units)
- Converted back: `1 * 1e12 = 1,000,000,000,000` wei = `1.0 ETH`
- Lost: `0.999999999999 ETH` (~$2,000+ at current ETH prices)

While the NatSpec says "Rounding dust (up to ~0.000001 ETH) is acceptable," this is incorrect. The maximum loss is `~0.000000999999 ETH` per conversion (about $0.002 at $2000/ETH), which occurs when the amount ends in `999,999,999,999` sub-units. However, the NatSpec claim and the code comment are misleading:

The real risk is when users convert small amounts. Converting `0.5e12 - 1` wei (just under 0.0000005 ETH) results in `scaledAmount = 0`, triggering a revert. Converting amounts between `1e12` and `2e12 - 1` all produce `scaledAmount = 1`, meaning amounts from 0.000001 ETH to 0.000001999999 ETH all round to 0.000001 ETH -- a potential 50% loss on the smallest convertible amounts.

**Impact:** Users lose up to `SCALING_FACTOR - 1` wei per conversion. The loss is economically insignificant for large conversions but can approach 50% for micro-conversions near the minimum threshold. The dust is permanently unrecoverable.

**Recommendation:** Track and refund dust:

```solidity
uint256 dust = amount - (scaledAmount * SCALING_FACTOR);
// Refund dust to user or track it separately
dustBalance[msg.sender] += dust;
```

Or document the minimum practical conversion amount prominently.

---

### [M-01] Unchecked MPC Arithmetic -- MpcCore.add() Can Silently Overflow uint64

**Severity:** Medium
**Lines:** 247, 321
**Agents:** Both

**Description:**

The contract uses `MpcCore.add()` in two locations:

1. `convertToPrivate()` line 247: `MpcCore.add(gtCurrent, gtAmount)` -- Adding to an existing balance
2. `privateTransfer()` line 321: `MpcCore.add(gtRecipient, encryptedAmount)` -- Adding to recipient balance

COTI V2's `MpcInterface.sol` (line 14) shows that both unchecked `Add()` and checked `CheckedAdd()` variants exist:
```solidity
function Add(bytes3, uint256, uint256) returns (uint256);
function CheckedAdd(bytes3, uint256, uint256) returns (uint256 overflowBit, uint256);
```

The unchecked variant silently wraps on overflow. With `uint64` max of `~18.446e18`, a user who receives enough transfers could overflow their balance. While the `type(uint64).max` check in `convertToPrivate()` (line 238) prevents single-deposit overflow, accumulated transfers via `privateTransfer()` have no such guard.

Similarly, `MpcCore.sub()` is used without checking for underflow (lines 271, 314), though the prior `MpcCore.ge()` checks mitigate this in normal operation.

**Impact:** A user receiving many private transfers could silently overflow their encrypted balance, wrapping to a small value and losing funds. The attacker doesn't profit (the overflow destroys value), but the victim loses their balance.

**Recommendation:** Use `MpcCore.checkedAdd()` and handle the overflow bit:

```solidity
(gtBool overflow, gtUint64 gtNew) = MpcCore.checkedAdd(gtCurrent, gtAmount);
if (MpcCore.decrypt(overflow)) revert AmountTooLarge();
```

---

### [M-02] No Pausability -- Contract Cannot Be Emergency-Stopped

**Severity:** Medium
**Lines:** 42-46 (inheritance list)
**Agents:** Both

**Description:**

PrivateWETH does not inherit `PausableUpgradeable` and has no `pause()`/`unpause()` functions. If a vulnerability is discovered after deployment (or if the COTI MPC network experiences issues), there is no way to halt operations. The only emergency mechanism is the `ossify()` function, which permanently disables upgrades -- the opposite of what's needed in an emergency.

By contrast, the sibling contract `PrivateDEXSettlement.sol` inherits `PausableUpgradeable` and has both `pause()`/`unpause()` functions and an additional `emergencyStop` flag.

**Impact:** No ability to halt operations during a security incident. If an exploit is in progress, the admin has no mechanism to stop it short of submitting a UUPS upgrade -- which requires time to develop, test, and deploy.

**Recommendation:** Add `PausableUpgradeable`:

```solidity
import { PausableUpgradeable } from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// Add to inheritance list
// Add __Pausable_init() to initialize()
// Add whenNotPaused modifier to convertToPrivate, convertToPublic, privateTransfer
// Add pause() and unpause() functions gated by DEFAULT_ADMIN_ROLE
```

---

### [M-03] bridgeMint Does Not Associate Minted Amount with Recipient -- No Per-User Public Balance Tracking

**Severity:** Medium
**Lines:** 190-199
**Agents:** Both

**Description:**

`bridgeMint(address to, uint256 amount)` accepts a `to` parameter but only increments the global `totalPublicSupply`. There is no per-user public balance mapping. The `to` address appears only in the event emission:

```solidity
function bridgeMint(address to, uint256 amount)
    external onlyRole(BRIDGE_ROLE) {
    // ...
    totalPublicSupply += amount;     // Global counter only
    emit BridgeMint(to, amount);     // 'to' only used in event
}
```

This means:
1. Bridge mints 100 WETH for Alice
2. Bob calls `convertToPrivate(100 ether)` -- succeeds because there is no check that Bob has any public balance
3. Alice's "minted" amount is consumed by Bob

Without per-user balance tracking, the `to` parameter in `bridgeMint` is meaningless. Any address can convert any amount to private, regardless of whether tokens were minted for them.

**Impact:** Bridge mint operations are not associated with specific users. Any user can front-run and consume another user's bridged WETH by calling `convertToPrivate()` first.

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
```

---

### [M-04] No Transfer Event Standard Compliance -- Incompatible with Explorers and Indexers

**Severity:** Medium
**Lines:** 120-126, 299-326
**Agents:** Both

**Description:**

`PrivateTransfer` event emits only `from` and `to` addresses with no amount (intentionally, for privacy). However, the contract has no ERC20 `Transfer` events, no ERC20 interface implementation, and no standard token interface. Block explorers, portfolio trackers, and indexers that look for ERC20-compatible events will not detect any token activity.

Furthermore, there are no events for the amount-revealing operations either. The `ConvertedToPrivate` and `ConvertedToPublic` events include the public amount, but they are the only way to observe token flow. The `privateTransfer` is intentionally opaque, but this makes it impossible for even the contract owner to audit total circulating private supply.

The contract declares `TOKEN_NAME`, `TOKEN_SYMBOL`, and `TOKEN_DECIMALS` constants, suggesting it is intended to be token-like, but it implements none of the ERC20 interface functions (`balanceOf`, `transfer`, `approve`, `allowance`, `totalSupply`).

**Impact:** The contract is invisible to standard blockchain tooling. No explorer or indexer will display pWETH balances or transfers. This hinders adoption and makes debugging difficult.

**Recommendation:** Consider implementing a minimal ERC20-compatible read interface for the public side of the token (public balances only), while keeping private operations opaque. At minimum, implement `name()`, `symbol()`, `decimals()`, and `totalSupply()` view functions.

---

### [L-01] Event Over-Indexing -- amount Parameters Are `indexed` on uint256

**Severity:** Low
**Lines:** 97, 102, 109, 117
**Agents:** Both

**Description:**

All four events (`BridgeMint`, `BridgeBurn`, `ConvertedToPrivate`, `ConvertedToPublic`) declare `amount`/`publicAmount` as `indexed`. Indexing uint256 values causes them to be stored as keccak256 topic hashes rather than recoverable values:

```solidity
event BridgeMint(address indexed to, uint256 indexed amount);
```

When a `uint256` is `indexed`, it is hashed into a 32-byte topic. While in Solidity 0.8.x value types are stored directly in the topic (not hashed), indexing amounts is still an anti-pattern because:
- Filtering by exact amount is rarely useful
- It wastes gas (3 topics vs. 2 topics + data field)
- Addresses should be indexed; amounts generally should not

**Impact:** Marginally increased gas cost for event emission. No functional impact.

**Recommendation:** Remove `indexed` from amount parameters:

```solidity
event BridgeMint(address indexed to, uint256 amount);
event BridgeBurn(address indexed from, uint256 amount);
event ConvertedToPrivate(address indexed user, uint256 publicAmount);
event ConvertedToPublic(address indexed user, uint256 publicAmount);
```

---

### [L-02] Storage Gap Size Is 46 -- May Be Insufficient Given Sibling Contract Divergence Risk

**Severity:** Low
**Lines:** 88
**Agents:** Both

**Description:**

The storage gap is `uint256[46] private __gap` which, combined with the 4 state variables above it, totals 50 storage slots. This is the standard OpenZeppelin recommendation and is shared across all three sibling contracts (PrivateWETH, PrivateWBTC, PrivateUSDC).

However, if future upgrades add different state variables to different sibling contracts, the gap consumption must be independently tracked per contract. A common mistake with cloned contract families is assuming they can share upgrade patterns -- if PrivateUSDC adds 3 new variables (gap becomes 43) but PrivateWETH adds 5 (gap becomes 41), the storage layouts diverge, and shared upgrade scripts may apply incorrect gap adjustments.

**Impact:** No immediate issue. Potential for storage collision in future upgrades if sibling contracts are upgraded independently without tracking per-contract gap consumption.

**Recommendation:** Document the initial gap size and decrement policy. Consider adding a comment:

```solidity
/// @dev Storage gap: 46 slots. Initial total = 50.
/// When adding new state variables, decrease __gap by the same count.
/// Track gap changes independently from sibling contracts (PrivateUSDC, PrivateWBTC).
uint256[46] private __gap;
```

---

### [L-03] Admin Receives Both DEFAULT_ADMIN_ROLE and BRIDGE_ROLE at Initialization -- Excessive Privilege Concentration

**Severity:** Low
**Lines:** 177-178
**Agents:** Both

**Description:**

The `initialize()` function grants the same `admin` address both `DEFAULT_ADMIN_ROLE` (which can manage all roles) and `BRIDGE_ROLE` (which can mint/burn):

```solidity
_grantRole(DEFAULT_ADMIN_ROLE, admin);
_grantRole(BRIDGE_ROLE, admin);
```

This means a single compromised key can:
1. Mint unlimited `totalPublicSupply` via `bridgeMint()`
2. Burn all `totalPublicSupply` via `bridgeBurn()`
3. Grant `BRIDGE_ROLE` to any address
4. Ossify the contract to prevent remediation

The intended design is for `BRIDGE_ROLE` to be held by the bridge contract (OmniBridge), not by a human admin. Granting it to the admin at initialization creates a window where the admin has minting powers before the role is transferred to the bridge.

**Impact:** Single point of failure during the period between deployment and role transfer to the bridge contract. If the admin key is compromised before `BRIDGE_ROLE` is transferred, unlimited minting is possible.

**Recommendation:** Consider not granting `BRIDGE_ROLE` in `initialize()`. Instead, have the admin grant it explicitly to the bridge contract address after deployment:

```solidity
function initialize(address admin) external initializer {
    // ...
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    // BRIDGE_ROLE not granted here -- admin grants it to bridge contract later
}
```

---

### [I-01] No Test Suite Exists for PrivateWETH

**Severity:** Informational
**Agents:** Both

**Description:**

A grep of the entire `Coin/` directory for "PrivateWETH" returns only the contract file itself. No unit tests, integration tests, or deployment scripts reference this contract. The contract has never been tested.

Given the Critical-severity findings (C-01, C-02) that reveal fundamental design issues, tests would have caught these immediately: a simple test asserting that `convertToPrivate()` fails without prior `bridgeMint()` would reveal the missing balance deduction.

**Impact:** No confidence in contract correctness. All findings in this report are based on code review only.

**Recommendation:** Create a comprehensive test suite covering:
- Bridge mint/burn accounting
- Convert-to-private with and without sufficient public balance
- Convert-to-public with and without sufficient private balance
- Private transfer between two accounts
- Round-trip conversion (checking for dust loss)
- Overflow scenarios on MPC arithmetic
- UUPS upgrade authorization and ossification
- Role management

---

### [I-02] Contract Is Structurally Identical to PrivateWBTC and PrivateUSDC -- Should Use Shared Base Contract

**Severity:** Informational
**Agent:** Both

**Description:**

PrivateWETH, PrivateWBTC, and PrivateUSDC share 95%+ identical code. The only differences are:
- `SCALING_FACTOR`: 1e12 (WETH), 1e2 (WBTC), 1 (USDC)
- `TOKEN_NAME/SYMBOL/DECIMALS`: Metadata constants
- NatSpec comments referencing the specific token

This violates the DRY (Don't Repeat Yourself) principle. A bug fix in one contract must be manually replicated across all three. The Critical findings C-01 and C-02 in this report apply identically to all three contracts -- confirming that code duplication propagates vulnerabilities.

**Impact:** Maintenance burden. Bug fixes must be applied N times. Risk of divergence where one contract is patched but siblings are not.

**Recommendation:** Extract a shared base contract:

```solidity
abstract contract PrivateTokenWrapper is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // All shared logic here
    function _scalingFactor() internal pure virtual returns (uint256);
    function _tokenName() internal pure virtual returns (string memory);
    // ...
}

contract PrivateWETH is PrivateTokenWrapper {
    function _scalingFactor() internal pure override returns (uint256) {
        return 1e12;
    }
    // ...
}
```

---

### [I-03] privateBalanceOf Exposes Encrypted Ciphertext to Any Caller -- Potential Side-Channel Risk

**Severity:** Informational
**Lines:** 337-341
**Agent:** Both

**Description:**

`privateBalanceOf()` is a public view function that returns the raw `ctUint64` ciphertext for any account:

```solidity
function privateBalanceOf(address account) external view returns (ctUint64) {
    return encryptedBalances[account];
}
```

While the ciphertext cannot be directly decrypted without the MPC key, exposing it publicly enables:
1. **Balance change detection**: An observer who polls `privateBalanceOf(alice)` can detect when the value changes, revealing that Alice made a transaction -- even though the amount is hidden.
2. **Ciphertext fingerprinting**: If COTI MPC produces deterministic ciphertexts for the same plaintext (which is unlikely but depends on the MPC implementation), equal ciphertexts would reveal equal balances.
3. **Statistical analysis**: Ciphertext size or structure patterns may leak information about the plaintext range.

**Impact:** Reduced privacy. Transaction timing can be detected even though amounts are hidden. This is inherent to the design (balance queries are necessary), but the contract makes no effort to limit access.

**Recommendation:** Consider restricting `privateBalanceOf` to the account owner or authorized parties:

```solidity
function privateBalanceOf(address account) external view returns (ctUint64) {
    if (msg.sender != account && !hasRole(BRIDGE_ROLE, msg.sender))
        revert Unauthorized();
    return encryptedBalances[account];
}
```

Or document this as an accepted privacy trade-off.

---

## Static Analysis Results

**Solhint:** 0 errors, 0 warnings (clean)

No solhint issues. The contract follows proper ordering conventions (with inline solhint-disable-line comments where needed), uses custom errors instead of require strings, and has complete NatSpec documentation.

**Slither/Aderyn:** Not run (COTI MPC precompile dependencies not available in standard analysis environments)

## Methodology

- Pass 1: Static analysis (solhint, manual code review)
- Pass 2A: OWASP Smart Contract Top 10 analysis -- Access Control (SC01), Arithmetic (SC02), Reentrancy (SC04), Denial of Service (SC06), Oracle/Bridge (SC07)
- Pass 2B: Business Logic & Economic Analysis -- Token custody model, conversion round-trip integrity, fee architecture, cross-contract integration
- Pass 3: Comparative analysis against sibling contracts (PrivateUSDC, PrivateWBTC, PrivateDEXSettlement, OmniPrivacyBridge)
- Pass 4: MPC-specific analysis -- Checked vs. unchecked arithmetic, ciphertext exposure, privacy leakage vectors
- Pass 5: Triage & deduplication
- Pass 6: Report generation

## Conclusion

PrivateWETH has **two Critical vulnerabilities that render the contract non-functional for its stated purpose**:

1. **No token custody (C-01)** -- The contract never receives, holds, or transfers any WETH tokens. `bridgeMint` and `bridgeBurn` are pure counter operations with no asset backing. The contract is a ledger without a treasury.

2. **Free private minting (C-02)** -- `convertToPrivate()` creates encrypted MPC balances without deducting from any source. Any address can create unlimited private pWETH without depositing anything.

These two findings together mean the contract is a privacy wrapper with nothing to wrap. The entire conversion pipeline operates on fictional balances. These same Critical findings apply equally to the sibling contracts **PrivateWBTC** and **PrivateUSDC**, which share identical architecture.

3. **No public redemption (H-01)** -- `convertToPublic()` destroys private balance without crediting any public balance. Tokens converted out of privacy are lost.

4. **Shadow ledger unreliable (H-02)** -- The emergency recovery ledger desynchronizes after any `privateTransfer()`, making its stated recovery purpose unachievable.

5. **No pause mechanism (M-02)** -- Unlike PrivateDEXSettlement, this contract has no emergency stop capability.

**Deployment Recommendation:** DO NOT DEPLOY. The contract requires fundamental redesign to implement actual token custody (or documented integration with an external custody contract), per-user public balance tracking, and checked MPC arithmetic. The sibling contracts PrivateWBTC and PrivateUSDC require the same fixes.

**Positive Observations:**
- Clean solhint output (0 errors, 0 warnings)
- Proper use of `_disableInitializers()` in constructor
- Correct UUPS upgrade pattern with ossification
- ReentrancyGuard applied to all state-changing functions
- Zero-address validation on all address parameters
- Good NatSpec documentation coverage
- Appropriate storage gap for upgradeability

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
