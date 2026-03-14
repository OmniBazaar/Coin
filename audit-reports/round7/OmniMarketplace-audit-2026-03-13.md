# Security Audit Report: OmniMarketplace (Round 7)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7)
**Contract:** `Coin/contracts/marketplace/OmniMarketplace.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 836
**Upgradeable:** Yes (UUPS with 48-hour timelock)
**Handles Funds:** No (listing registry only; no token transfers)
**OpenZeppelin Version:** 5.x (upgradeable)
**Previous Audits:** Round 4 (2026-02-28) -- 5 Medium, 3 Low, 3 Informational

## Audit Scope

This Round 7 audit reviews the current state of OmniMarketplace.sol after all Round 4 remediations. The contract is an on-chain listing registry that stores IPFS content identifiers and content hashes -- all actual marketplace content resides off-chain on IPFS. The contract does NOT handle funds, tokens, or escrow. Purchase/payment flows are handled by MinimalEscrow.sol separately.

### Contracts In Scope

| Contract | Source | Lines |
|----------|--------|-------|
| OmniMarketplace.sol | `contracts/marketplace/OmniMarketplace.sol` | 836 |

### Key Dependencies (Integration Verified)

| Contract | Relationship |
|----------|-------------|
| OmniForwarder.sol | Trusted forwarder (ERC-2771 meta-transactions) |
| MinimalEscrow.sol | Separate contract; handles purchase/escrow flows |
| UnifiedFeeVault.sol | Separate contract; fee distribution |
| OpenZeppelin Upgradeable v5.x | AccessControl, UUPS, ReentrancyGuard, Pausable, EIP712, ERC2771Context |

## Executive Summary

OmniMarketplace is a UUPS-upgradeable, ERC-2771-enabled on-chain listing registry. It records listing metadata (IPFS CID, content hash, price, expiry, creator) without storing any listing content or handling any token transfers. The contract has been significantly hardened since the Round 4 audit: all five Medium findings (M-01 through M-05) have been remediated, and all three Low findings (L-01 through L-03) have been addressed. The contract now includes a proper `__gap` storage reservation, correct EIP-712 signature handling for `expiry==0`, CID deduplication clearing on delist, daily listing rate limits, an explicit `creator` parameter for the relayer pattern, bounds-validated `setDefaultExpiry()`, `whenNotPaused` on `renewListing()`, and a 48-hour upgrade timelock.

**No Critical or High severity findings were identified.** The contract's limited scope -- a read/write registry with no fund handling -- significantly reduces its attack surface. The remaining findings are Medium (2), Low (3), and Informational (5), all related to design hardening and gas optimization rather than exploitable vulnerabilities.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 5 |

---

## Round 4 Remediation Verification

All five Medium and three Low findings from the Round 4 audit (2026-02-28) have been remediated.

| ID | Finding | Status | Verification |
|----|---------|--------|--------------|
| M-01 | Missing `__gap` storage reservation | **FIXED** | `uint256[46] private __gap` at line 200 with detailed slot accounting |
| M-02 | EIP-712 signature broken with `expiry==0` | **FIXED** | `signedExpiry` preserved at line 360; default applied after signature check (line 383) |
| M-03 | CID deduplication not cleared on delist | **FIXED** | `delete cidToListingId[l.ipfsCID]` at line 539 |
| M-04 | Listing count inflation (participation gaming) | **FIXED** | Daily rate limit: `MAX_LISTINGS_PER_DAY = 50` enforced at lines 348-354 and 457-463 |
| M-05 | Relayer pattern non-functional | **FIXED** | Explicit `creator` parameter at line 331; signature verified against `creator` at line 377 |
| L-01 | `setDefaultExpiry()` no bounds/event | **FIXED** | Bounds check (zero, max) at lines 706-709; `DefaultExpiryUpdated` event at line 712 |
| L-02 | `renewListing()` callable while paused | **FIXED** | `whenNotPaused` modifier added at line 554 |
| L-03 | No timelock on `_authorizeUpgrade()` | **FIXED** | 48-hour timelock via `scheduleUpgrade()` / `_authorizeUpgrade()` at lines 733-781 |

---

## OWASP Smart Contract Top 10 Analysis

### SC01: Reentrancy

**Status: NOT VULNERABLE**

All state-modifying external functions use the `nonReentrant` modifier. The contract performs no external calls (no token transfers, no cross-contract calls), so reentrancy attack surface is effectively zero. State changes to `listings`, `listingCount`, `totalListingsCreated`, `nonces`, `cidToListingId`, and `dailyListingCount` all occur before any event emissions.

### SC02: Access Control

**Status: ADEQUATE**

- `DEFAULT_ADMIN_ROLE`: `pause()`, `unpause()`, `setDefaultExpiry()`, `scheduleUpgrade()`, `cancelUpgrade()`, `_authorizeUpgrade()`
- Creator check (msg.sender / _msgSender()): `delistListing()`, `renewListing()`, `updatePrice()`
- Permissionless: `registerListing()`, `registerListingDirect()`, all view functions

The `registerListing()` function accepts any `msg.sender` as a relayer but cryptographically verifies the `creator` via EIP-712 signature. This correctly prevents validator forgery.

### SC03: Oracle Manipulation

**Status: NOT APPLICABLE**

The contract does not consume any price feeds or oracles. The `price` field in listings is a user-supplied metadata value with no on-chain financial impact.

### SC04: Insufficient Gas Griefing

**Status: NOT VULNERABLE**

No unbounded loops exist. All operations are O(1) with fixed gas costs. The daily listing rate limit (`MAX_LISTINGS_PER_DAY = 50`) bounds per-transaction throughput.

### SC05: Denial of Service

**Status: NOT VULNERABLE**

There are no external calls that could cause DoS. The contract cannot be bricked by failing transfers. Pausing only blocks `registerListing`, `registerListingDirect`, and `renewListing` -- users can still delist and update prices during pause.

### SC06: Front-Running

**Status: LOW RISK (see M-01)**

EIP-712 signatures bind the listing parameters (CID, content hash, price, expiry, nonce) to the creator. A front-runner cannot steal a signed listing because the signature includes the creator address. However, CID front-running is possible -- see M-01 below.

### SC07: Overflow/Underflow

**Status: NOT VULNERABLE**

Solidity 0.8.24 provides built-in overflow protection. The `listingCount[caller]--` in `delistListing()` is safe because `listingCount` is only decremented when `l.active` is true, which means it was previously incremented during creation.

### SC08: Timestamp Dependence

**Status: ACCEPTABLE**

The contract uses `block.timestamp` for expiry calculations, daily rate limiting, and upgrade timelock. Validators have ~2-second timestamp flexibility on Avalanche/Subnet-EVM. This is acceptable for the contract's use cases (days/hours granularity, not seconds).

### SC09: Insecure Randomness

**Status: NOT APPLICABLE**

The contract uses no randomness.

### SC10: Flash Loan Attack

**Status: NOT APPLICABLE**

The contract holds no tokens and has no financial interactions susceptible to flash loans.

---

## Medium Findings

### [M-01] CID Front-Running Allows Listing Squatting on Zero-Gas Chain

**Severity:** Medium
**Category:** Business Logic / Front-Running
**Location:** `registerListingDirect()` (lines 440-506), `cidToListingId` mapping (line 161)

**Description:**

The Round 4 M-04 fix (daily rate limit of 50 listings) mitigates mass spam but does not fully prevent targeted CID squatting. On a zero-gas-fee chain, an attacker monitoring the IPFS network or validator mempool can:

1. Observe a legitimate user preparing a listing with a specific IPFS CID
2. Call `registerListingDirect(victimCID, keccak256("junk"), 1, 0)` with the same CID before the victim's transaction
3. The victim's transaction reverts with `DuplicateListing(ipfsCID)`
4. The attacker can then optionally delist to free the CID, or hold it hostage

The daily limit of 50 reduces volume but does not prevent targeted attacks against specific users. The attack costs zero gas on the OmniCoin chain.

While M-03 from Round 4 fixed the permanent CID lock (CID is cleared on delist), the squatting window still exists for as long as the attacker's listing is active.

**Impact:** A determined attacker can repeatedly block a specific user's listings by front-running their CID registrations. The attacker burns one of their 50 daily slots per attack.

**Mitigation Status:** Partially mitigated by daily rate limit (M-04 fix). The `registerListing()` path with EIP-712 signatures is not vulnerable because the CID is bound to the creator's signature, but `registerListingDirect()` has no such binding.

**Recommendation:**

Consider one or more of the following:
1. **Require OmniRegistration:** Only registered users (via OmniRegistration contract) can create listings, adding an identity cost to squatting
2. **Commit-reveal for CIDs:** Two-phase listing creation where the CID is committed (hashed) first, then revealed
3. **Content hash binding:** Require the content hash to include the creator address, making CID+contentHash pair unique per creator
4. **Off-chain resolution:** Validators can detect and flag CID squatting attempts and refuse to relay them

---

### [M-02] `registerListing()` Does Not Use `_msgSender()` for ERC-2771 Consistency

**Severity:** Medium
**Category:** ERC-2771 / Meta-Transaction Inconsistency
**Location:** `registerListing()` (line 330)

**Description:**

The contract inherits `ERC2771ContextUpgradeable` and overrides `_msgSender()` to support meta-transactions via OmniForwarder. However, `registerListing()` does not use `_msgSender()` anywhere in its body -- it relies entirely on the explicit `creator` parameter and EIP-712 signature verification. This is technically correct for the relayer pattern (the relayer is `msg.sender`, the creator is verified via signature), but creates an inconsistency:

When called through the trusted forwarder, `msg.sender` is the forwarder contract. The function does not call `_msgSender()` at all, so the ERC-2771 context suffix is never consumed. For `registerListing()` specifically, this is benign because the creator identity comes from the signature, not from `msg.sender` or `_msgSender()`.

However, the function emits no information about the relayer/submitter identity. If a validator submits a listing through the forwarder on behalf of a creator, there is no on-chain record of which validator performed the relay.

**Impact:** Low practical impact -- the signature-based verification is sound. The finding is about consistency and traceability rather than a security vulnerability.

**Recommendation:**

Document in NatSpec that `registerListing()` intentionally does not use `_msgSender()` because creator identity is derived from the EIP-712 signature, not from the transaction sender. Optionally, add a `relayer` field to the `ListingRegistered` event:

```solidity
event ListingRegistered(
    uint256 indexed listingId,
    address indexed creator,
    bytes32 ipfsCID,
    bytes32 contentHash,
    uint256 price,
    uint256 expiry,
    address relayer  // msg.sender or _msgSender() for traceability
);
```

---

## Low Findings

### [L-01] `delistListing()` and `updatePrice()` Not Gated by `whenNotPaused`

**Severity:** Low
**Category:** Pause Consistency
**Location:** `delistListing()` (line 523), `updatePrice()` (line 591)

**Description:**

After the Round 4 L-02 fix, `renewListing()` now has `whenNotPaused`. However, `delistListing()` and `updatePrice()` still lack the modifier. The NatSpec on `delistListing()` (line 515) explicitly states "Intentionally callable while paused so users can delist during emergencies," and `updatePrice()` (line 587) has a similar comment.

This is a deliberate design choice and makes sense from a user-protection perspective: during an emergency, users should be able to remove their listings and adjust prices. However, `updatePrice()` on an expired listing during pause is a no-op, and allowing price updates during a security pause could theoretically interact with off-chain systems that read prices.

**Status:** Acknowledged by design. The NatSpec documentation explicitly marks this as intentional.

---

### [L-02] Storage Gap Calculation Counts Mappings in Comment but Not in Slot Count

**Severity:** Low
**Category:** Upgrade Safety / Documentation
**Location:** `__gap` comment (lines 187-199)

**Description:**

The storage gap comment at lines 187-199 lists the sequential state variables and mappings correctly. The calculation states "Gap = 50 - 4 = 46 reserved slots" with 4 sequential slots used (`nextListingId`, `defaultExpiry`, `pendingImplementation`, `upgradeScheduledAt`). The comment also lists 6 mappings (but says "5" in the text at line 194), noting they do not consume sequential slots per OZ convention.

There is a minor discrepancy: the comment says "Mappings (5)" but then lists 6 items: `listings`, `listingCount`, `totalListingsCreated`, `nonces`, `cidToListingId`, `dailyListingCount`. This is a documentation error only; the gap calculation of 46 is correct because mappings do not consume sequential slots.

**Recommendation:**

Update line 194 to say "Mappings (6)" instead of "Mappings (5)":
```solidity
 * Mappings (6): listings, listingCount, totalListingsCreated,
 *   nonces, cidToListingId, dailyListingCount
```

---

### [L-03] `cancelUpgrade()` Emits Event Even When No Upgrade Is Pending

**Severity:** Low
**Category:** Event Integrity
**Location:** `cancelUpgrade()` (lines 748-756)

**Description:**

The `cancelUpgrade()` function does not check whether a pending upgrade actually exists before executing. If called when `pendingImplementation == address(0)` and `upgradeScheduledAt == 0`, it will:

1. Set `cancelled = address(0)`
2. Delete already-zero values (no-op)
3. Emit `UpgradeCancelled(address(0))`

This emits a misleading event suggesting an upgrade was cancelled when none was pending. While not exploitable, it pollutes the event log and could confuse off-chain monitoring systems.

**Recommendation:**

Add a guard:
```solidity
function cancelUpgrade()
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    if (pendingImplementation == address(0)) {
        revert UnauthorizedUpgrade(); // or a new NoPendingUpgrade() error
    }
    address cancelled = pendingImplementation;
    delete pendingImplementation;
    delete upgradeScheduledAt;
    emit UpgradeCancelled(cancelled);
}
```

---

## Informational Findings

### [I-01] Struct Packing Optimization for `Listing`

**Severity:** Informational (Gas)
**Category:** Gas Optimization
**Location:** `Listing` struct (lines 110-118)
**Solhint Reference:** `gas-struct-packing` warning at line 110

**Description:**

The `Listing` struct uses 7 storage slots:
```
slot 1: creator    (address, 20 bytes)  + 12 bytes wasted
slot 2: ipfsCID    (bytes32, 32 bytes)
slot 3: contentHash (bytes32, 32 bytes)
slot 4: price      (uint256, 32 bytes)
slot 5: expiry     (uint256, 32 bytes)
slot 6: createdAt  (uint256, 32 bytes)
slot 7: active     (bool, 1 byte)       + 31 bytes wasted
```

The `active` bool wastes 31 bytes of storage. Packing `active` with `creator` in slot 1 would save 1 storage slot per listing (from 7 to 6 slots):

```solidity
struct Listing {
    address creator;  // 20 bytes
    bool active;      // 1 byte  (packed with creator in slot 1)
    bytes32 ipfsCID;
    bytes32 contentHash;
    uint256 price;
    uint256 expiry;
    uint256 createdAt;
}
```

On a zero-gas chain this is purely cosmetic, but it reduces state bloat by ~14% per listing.

---

### [I-02] Duplicated Registration Logic Between `registerListing()` and `registerListingDirect()`

**Severity:** Informational
**Category:** Code Quality / Maintainability
**Location:** `registerListing()` (lines 330-426), `registerListingDirect()` (lines 440-506)

**Description:**

Both functions share approximately 25 lines of identical logic: input validation (CID, content hash, price, duplicate check), daily rate limit enforcement, expiry defaulting and capping, listing creation, and event emission. This was noted in Round 4 (I-01) and has not been refactored.

Extracting a shared internal `_createListing(address creator, bytes32 ipfsCID, bytes32 contentHash, uint256 price, uint256 expiry)` function would:
- Reduce contract bytecode size
- Eliminate the risk of divergent behavior between the two paths
- Simplify future maintenance

The two functions would only differ in the front matter: `registerListing()` performs signature verification, while `registerListingDirect()` uses `_msgSender()`.

---

### [I-03] `use-forbidden-name` Warnings from Solhint (`l` Variable)

**Severity:** Informational
**Category:** Code Style / Readability
**Location:** Lines 528, 557, 599, 626, 641
**Solhint Reference:** `use-forbidden-name` warning

**Description:**

The variable `l` (lowercase L) is used as a short name for `Listing storage l = listings[listingId]`. Solhint flags this because `l` (lowercase L), `I` (uppercase I), and `O` (uppercase O) are visually ambiguous in many fonts and can be confused with `1` (one) and `0` (zero).

**Recommendation:**

Rename to `listing`:
```solidity
Listing storage listing = listings[listingId];
```

---

### [I-04] Solhint Gas Warnings: Pre-Increment and Strict Inequalities

**Severity:** Informational (Gas)
**Category:** Gas Optimization
**Location:** Lines 350, 398, 401, 415, 416, 459, 479, 481, 495, 496, 536, 645, 689
**Solhint References:** `gas-increment-by-one`, `gas-strict-inequalities`

**Description:**

Solhint identifies several gas optimization opportunities:

1. **Post-increment to pre-increment** (lines 398, 415, 416, 479, 495, 496, 536): `dailyListingCount[creator][today]++` and similar could use `++variable` to save ~5 gas per operation. On a zero-gas chain this is cosmetic.

2. **Non-strict inequalities** (lines 350, 459, 645, 689): `>=` comparisons in the daily limit check and `<=` in `isListingValid()`. Strict inequalities (`>` / `<`) save ~3 gas each. However, changing the semantics of these comparisons would alter the boundary behavior and is not recommended unless the exact threshold values are adjusted accordingly.

3. **Indexed event parameters** (lines 213, 233, 242, 251, 259): Several event parameters could be `indexed` for more efficient log filtering. However, only 3 parameters per event can be indexed, and the most important ones (listingId, creator) already are.

**Status:** Cosmetic on a zero-gas chain. No action required.

---

### [I-05] `function ordering` Warning from Solhint

**Severity:** Informational
**Category:** Code Style
**Location:** Line 703
**Solhint Reference:** `ordering` warning

**Description:**

Solhint flags that `setDefaultExpiry()` (an external function) appears after `dailyListingsRemaining()` (an external view function). Per Solidity style guide, external functions should appear before external view functions.

The current ordering groups functions by logical purpose (view functions together, admin functions together), which is arguably more readable than strict Solidity ordering. This is a stylistic choice.

---

## Access Control Map

| Role | Functions | Risk Level | Notes |
|------|-----------|------------|-------|
| DEFAULT_ADMIN_ROLE | `pause`, `unpause`, `setDefaultExpiry`, `scheduleUpgrade`, `cancelUpgrade`, `_authorizeUpgrade` | 3/10 | 48h timelock on upgrades; no fund access |
| Creator (signature or _msgSender) | `delistListing`, `renewListing`, `updatePrice` | 1/10 | Can only modify own listings |
| Relayer (any msg.sender) | `registerListing` (with valid creator signature) | 1/10 | Cannot forge listings |
| Any caller | `registerListingDirect`, all view functions | 1/10 | Rate-limited to 50/day |

---

## Centralization Risk Assessment

**Single-key maximum damage:** 3/10

- Admin can upgrade implementation after 48h timelock. The timelock prevents instant upgrades but a compromised admin key could schedule a malicious upgrade and execute it 48 hours later if not detected.
- Admin can pause new listing creation (but users can still delist).
- Admin can change `defaultExpiry` to any value within bounds (1 second to 365 days).
- The contract holds NO funds, so an admin compromise cannot directly steal tokens.

**Mitigations in place:**
- 48-hour upgrade timelock with `UpgradeScheduled` event for off-chain detection
- `cancelUpgrade()` function for emergency abort
- `_disableInitializers()` in constructor prevents implementation initialization

**Recommendation:** Transfer `DEFAULT_ADMIN_ROLE` to a multi-sig (e.g., Gnosis Safe) or the OmniGovernance timelock controller before mainnet launch.

---

## Upgrade Safety Analysis

| Check | Status | Notes |
|-------|--------|-------|
| `_disableInitializers()` in constructor | PASS | Line 281 |
| `initializer` modifier on `initialize()` | PASS | Line 289 |
| `__gap` storage reservation | PASS | 46 slots at line 200 |
| Correct initializer chain | PASS | All 5 base contracts initialized |
| No constructor state | PASS | Only `trustedForwarder_` (immutable, in bytecode) |
| Timelock on `_authorizeUpgrade()` | PASS | 48h via `scheduleUpgrade()` |
| Implementation address validation | PASS | Checked against `pendingImplementation` |
| Pending state cleared after upgrade | PASS | Lines 779-780 |

**Upgrade Slot Accounting:**

```
Sequential slots (4):
  slot N+0: nextListingId       (uint256)
  slot N+1: defaultExpiry       (uint256)
  slot N+2: pendingImplementation (address, 20 bytes)
  slot N+3: upgradeScheduledAt  (uint256)

Mapping slots (6, do not count):
  listings, listingCount, totalListingsCreated,
  nonces, cidToListingId, dailyListingCount

__gap: uint256[46]  (50 - 4 = 46)
Total budget: 50 slots (standard OZ convention)
```

---

## EIP-712 Signature Analysis

| Check | Status | Notes |
|-------|--------|-------|
| Domain separator initialized | PASS | `__EIP712_init("OmniMarketplace", "1")` at line 294 |
| Typehash matches struct | PASS | `LISTING_TYPEHASH` at lines 125-128 matches `registerListing()` parameters |
| Nonce included in hash | PASS | Replay protection via `nonces[creator]` at line 357 |
| Nonce incremented after use | PASS | Line 380 |
| Signature verified before state changes | PASS | Signature check at lines 363-377, state changes at lines 397-416 |
| `expiry==0` handled correctly | PASS | `signedExpiry` preserved at line 360 for signature verification |
| Creator parameter verified | PASS | `signer != creator` check at line 377 |

**Signature Replay Vectors:**
- Cross-chain replay: Protected by EIP-712 domain separator (includes chainId)
- Same-chain replay: Protected by auto-incrementing nonce
- Cross-contract replay: Protected by EIP-712 domain separator (includes contract address)
- `expiry==0` replay: Not applicable; signature uses the original `0` value, applied default is post-signature

---

## ERC-2771 Integration Analysis

| Check | Status | Notes |
|-------|--------|-------|
| `_msgSender()` override | PASS | Lines 795-802 |
| `_msgData()` override | PASS | Lines 812-819 |
| `_contextSuffixLength()` override | PASS | Lines 828-835 |
| Diamond resolution correct | PASS | Both Context and ERC2771Context properly resolved |
| Trusted forwarder immutable | PASS | Set in constructor, stored in bytecode |
| `_disableInitializers()` in constructor | PASS | Line 281 |

**ERC-2771 Usage in Functions:**

| Function | Uses `_msgSender()` | Correct? |
|----------|---------------------|----------|
| `registerListing()` | No (uses `creator` param + signature) | Yes -- intentional |
| `registerListingDirect()` | Yes (line 446) | Yes |
| `delistListing()` | Yes (line 526) | Yes |
| `renewListing()` | Yes (line 555) | Yes |
| `updatePrice()` | Yes (line 595) | Yes |

---

## Daily Rate Limit Analysis

The `MAX_LISTINGS_PER_DAY = 50` rate limit uses `block.timestamp / 1 days` to compute the current day. This creates UTC-aligned 86400-second windows.

**Edge case:** A user could create 50 listings at 23:59:59 UTC and 50 more at 00:00:00 UTC (1 second later), effectively creating 100 listings in 2 seconds. This is by design -- the limit is per-calendar-day, not a sliding window. The 50-per-day limit is anti-gaming, not anti-spam. The total `totalListingsCreated` is still bounded to 50/day over time.

**Sybil consideration:** On a zero-gas chain, an attacker can create multiple accounts to bypass the per-creator limit. However, participation score inflation requires a single account's `totalListingsCreated` to reach thresholds, so Sybil accounts do not help with scoring attacks.

---

## Integration with MinimalEscrow

OmniMarketplace and MinimalEscrow are architecturally independent contracts. There is no on-chain link between a marketplace listing and an escrow. The purchase flow is:

1. Buyer discovers listing via OmniMarketplace (on-chain registry + IPFS content)
2. Buyer creates escrow via MinimalEscrow with seller address and amount
3. Sale completion via escrow release triggers marketplace fee via UnifiedFeeVault

The listing's `price` field is informational only -- MinimalEscrow does not validate that the escrowed amount matches the listing price. This is intentional: price negotiation happens off-chain, and the escrow amount is what the buyer and seller agree on.

**No integration vulnerabilities identified.** The separation of concerns is clean and appropriate.

---

## Solhint Results Summary

```
0 errors, 33 warnings
```

| Warning Category | Count | Action |
|------------------|-------|--------|
| `gas-struct-packing` | 1 | I-01: Acknowledged, low priority |
| `gas-small-strings` | 2 | Inherent to LISTING_TYPEHASH; cannot fix |
| `gas-indexed-events` | 8 | I-04: Cosmetic on zero-gas chain |
| `code-complexity` | 2 | Acceptable for `registerListing()` (10) and `registerListingDirect()` (8) |
| `gas-strict-inequalities` | 4 | I-04: Semantic change not recommended |
| `gas-increment-by-one` | 8 | I-04: Cosmetic on zero-gas chain |
| `use-forbidden-name` | 4 | I-03: Rename `l` to `listing` |
| `not-rely-on-time` | Suppressed | Correctly suppressed; time-based logic is required |
| `ordering` | 1 | I-05: Stylistic preference |

---

## Known Exploit Cross-Reference

| Exploit / Finding | Date | Relevance | Status |
|-------------------|------|-----------|--------|
| CodeHawks -- Hawk High #377: Missing `__gap` | 2025 | UUPS storage gap | FIXED (M-01 remediated) |
| CodeHawks -- StakeLink #439: Missing `__gap` | 2024 | UUPS storage gap | FIXED (M-01 remediated) |
| Cantina -- Ludex Labs: Unrestricted registration | 2025 | Listing inflation | MITIGATED (daily rate limit) |
| EIP-712 signature domain replay attacks | Common | Cross-chain/contract replay | NOT VULNERABLE (domain separator) |
| UUPS uninitialized implementation (OZ v4.1-4.3) | 2021-2022 | `_disableInitializers()` | NOT VULNERABLE (properly called) |

---

## Summary of Findings

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| M-01 | Medium | CID front-running allows listing squatting on zero-gas chain | Open |
| M-02 | Medium | `registerListing()` does not use `_msgSender()` for ERC-2771 consistency | Open |
| L-01 | Low | `delistListing()` and `updatePrice()` not gated by `whenNotPaused` (by design) | Acknowledged |
| L-02 | Low | Storage gap comment says "Mappings (5)" but lists 6 | Open |
| L-03 | Low | `cancelUpgrade()` emits event when no upgrade is pending | Open |
| I-01 | Informational | Struct packing optimization for `Listing` | Open |
| I-02 | Informational | Duplicated registration logic | Open |
| I-03 | Informational | `use-forbidden-name` warnings (`l` variable) | Open |
| I-04 | Informational | Solhint gas warnings (pre-increment, strict inequalities) | Acknowledged |
| I-05 | Informational | Function ordering warning | Acknowledged |

---

## Overall Assessment

OmniMarketplace has been substantially hardened since the Round 4 audit. All previous findings have been addressed, and the contract demonstrates sound security practices:

- **Proper upgrade safety** with `__gap`, `_disableInitializers()`, 48-hour timelock
- **Sound EIP-712 implementation** with correct nonce management and `expiry==0` handling
- **Anti-gaming measures** with daily rate limits
- **Clean ERC-2771 integration** with proper diamond resolution
- **No fund handling** -- the contract's limited scope minimizes attack surface

The two remaining Medium findings are design-level concerns rather than exploitable vulnerabilities. M-01 (CID squatting) is partially mitigated by the daily rate limit and could be further addressed by requiring user registration. M-02 (ERC-2771 consistency) is a traceability concern, not a security bug.

**Recommendation for mainnet deployment:** Address L-02 (comment fix) and L-03 (`cancelUpgrade` guard) before deployment. Transfer `DEFAULT_ADMIN_ROLE` to a multi-sig. Consider OmniRegistration integration for M-01 mitigation.

---

*Generated by Claude Code Audit Agent -- Round 7 Manual Review*
*Contract: OmniMarketplace.sol (836 lines, UUPS upgradeable, no fund handling)*
*Previous audit: Round 4 (2026-02-28) -- all 5 Medium, 3 Low findings remediated*
