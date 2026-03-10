# Security Audit Report: OmniMarketplace (Round 6)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Pre-Mainnet Round 6)
**Contract:** `Coin/contracts/marketplace/OmniMarketplace.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 836
**Upgradeable:** Yes (UUPS with 48-hour timelock)
**Handles Funds:** No (listing registry only)
**Prior Audit:** Round 4 (2026-02-28) -- 5 Medium, 3 Low, 3 Informational

---

## Executive Summary

OmniMarketplace is a UUPS-upgradeable on-chain listing registry that stores only content hashes on-chain while actual listing content resides on IPFS. It supports two registration paths: EIP-712 signed registration (via relayer) and direct registration (msg.sender proves identity). The contract uses `AccessControlUpgradeable`, `PausableUpgradeable`, `ReentrancyGuardUpgradeable`, `EIP712Upgradeable`, and `ERC2771ContextUpgradeable`.

**Compared to the Round 4 audit (2026-02-28), ALL five Medium findings have been fixed:**
- M-01 (Missing `__gap`): Fixed. 46-slot storage gap added at line 204.
- M-02 (EIP-712 expiry==0): Fixed. `signedExpiry` preserves original value for signature verification (line 360).
- M-03 (CID lock on delist): Fixed. `cidToListingId` cleared via `delete` on delist (line 539).
- M-04 (Listing count inflation): Fixed. `MAX_LISTINGS_PER_DAY = 50` rate limit added (line 140, enforced at lines 349-354 and 458-463).
- M-05 (Relayer pattern broken): Fixed. Explicit `creator` parameter added (line 323), signature verified against `creator` not `msg.sender` (line 377).

**All three Low findings have been fixed:**
- L-01 (setDefaultExpiry no bounds): Fixed. Zero check and MAX_EXPIRY_DURATION cap added (lines 706-709), with `DefaultExpiryUpdated` event (line 712).
- L-02 (renewListing during pause): Fixed. `whenNotPaused` added to `renewListing()` (line 554).
- L-03 (No upgrade timelock): Fixed. 48-hour timelock via `scheduleUpgrade()` / `_authorizeUpgrade()` (lines 733-781).

No new Critical or High findings. Two new Low findings and two Informational items identified during this round.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 2 |
| Informational | 2 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

No Critical, High, or Medium findings were identified for this contract. Low and Informational findings accepted as-is.

---

## Round 4 Findings -- Remediation Status

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| M-01 | Missing `__gap` storage reservation | Medium | **FIXED** -- `uint256[46] private __gap` at line 204 |
| M-02 | EIP-712 unusable with `expiry==0` | Medium | **FIXED** -- `signedExpiry` preserves original for signature (line 360) |
| M-03 | CID deduplication not cleared on delist | Medium | **FIXED** -- `delete cidToListingId[l.ipfsCID]` at line 539 |
| M-04 | Listing count inflation (score gaming) | Medium | **FIXED** -- `MAX_LISTINGS_PER_DAY = 50` rate limit enforced |
| M-05 | Relayer/meta-tx pattern non-functional | Medium | **FIXED** -- explicit `creator` param, verified against signer |
| L-01 | `setDefaultExpiry()` no bounds or event | Low | **FIXED** -- bounds check + event emitted |
| L-02 | `renewListing()` callable while paused | Low | **FIXED** -- `whenNotPaused` added |
| L-03 | No timelock on `_authorizeUpgrade()` | Low | **FIXED** -- 48h timelock via schedule/authorize pattern |
| I-01 | Duplicated registration logic | Info | **ACKNOWLEDGED** -- not refactored, but low risk |
| I-02 | Operations on expired listings | Info | **ACKNOWLEDGED** -- intentional design |
| I-03 | Constructor disables initializers (positive) | Info | **CONFIRMED** -- still correct |

---

## New Findings (Round 6)

### [L-01] `triggerDefaultResolution` in OmniArbitration Can Reference Marketplace Listing but No On-Chain Linkage Exists

**Severity:** Low
**Category:** Cross-Contract Design
**Location:** OmniMarketplace (contract-wide) + OmniArbitration
**Impact:** Design consideration, no direct exploit

**Description:**
Per the OmniBazaar architecture, marketplace disputes flow through the arbitration system. However, OmniMarketplace has no reference to OmniArbitration, and OmniArbitration references escrows (not listings). The marketplace listing price recorded on-chain may differ from the actual transaction price used in escrow, since sellers can call `updatePrice()` at any time. There is no on-chain mechanism binding a listing ID to an escrow ID.

This is more of an architectural note than a vulnerability. The off-chain validator layer is expected to maintain this binding. However, if a dispute arises, there is no on-chain proof that a specific listing corresponds to a specific escrow.

**Recommendation:**
Consider emitting a `ListingSold(uint256 indexed listingId, uint256 escrowId)` event (triggered by the validator) to create an immutable on-chain audit trail linking listings to escrows. This would be purely informational and would not change the contract's security posture.

---

### [L-02] `delistListing()` and `updatePrice()` Intentionally Lack `whenNotPaused` but Rationale Should Be Documented

**Severity:** Low
**Category:** Access Control / Documentation
**Location:** `delistListing()` (line 523), `updatePrice()` (line 591)

**Description:**
Both functions are deliberately callable while the contract is paused (allowing users to manage their listings during emergencies). This is a reasonable design decision. However, the NatSpec for `delistListing()` (line 516-517) documents the rationale but `updatePrice()` does not. Consistency in documentation ensures future developers understand the intent.

**Recommendation:**
Add a comment to `updatePrice()` NatSpec explaining why it lacks `whenNotPaused`:
```solidity
/// @dev Intentionally callable while paused so users can update
///      prices during emergencies.
```

**Current status:** The NatSpec at line 586-587 already documents this. This finding is withdrawn on re-reading -- the documentation is already present.

**Revised status:** NOT A FINDING (documentation already present at lines 586-587).

---

### [I-01] Storage Gap Arithmetic Should Be Verified

**Severity:** Informational
**Category:** Upgrade Safety
**Location:** Lines 185-204

**Description:**
The `__gap` comment states "50 - 4 = 46 reserved slots" and lists 4 sequential state variables. The mappings (6 total: `listings`, `listingCount`, `totalListingsCreated`, `nonces`, `cidToListingId`, `dailyListingCount`) are correctly excluded per OpenZeppelin convention. The 4 sequential variables are:
1. `nextListingId` (1 slot)
2. `defaultExpiry` (1 slot)
3. `pendingImplementation` (1 slot)
4. `upgradeScheduledAt` (1 slot)

This count of 4 is correct. The gap of 46 is mathematically sound (50 - 4 = 46).

**Status:** VERIFIED CORRECT.

---

### [I-02] `dailyListingCount` Mapping Uses `block.timestamp / 1 days` Which Can Shift at Day Boundary

**Severity:** Informational
**Category:** Business Logic
**Location:** Lines 348, 398, 457, 479, 687

**Description:**
The daily rate limit uses `block.timestamp / 1 days` to compute "today." This means the daily counter resets at midnight UTC. A user could create 50 listings at 23:59 UTC and 50 more at 00:01 UTC (100 in ~2 minutes). This is a known limitation of any block.timestamp-based rate limiting and is acceptable for anti-gaming purposes. The absolute cap of 50 listings per UTC day is still enforced.

**Impact:** Minimal. The rate limit's purpose is to prevent mass automated creation (thousands/day), not to enforce a strict 24-hour rolling window. 100 per boundary crossing is still within acceptable bounds for participation score gaming prevention.

---

## Security Analysis Summary

### Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| `DEFAULT_ADMIN_ROLE` | `pause`, `unpause`, `scheduleUpgrade`, `cancelUpgrade`, `_authorizeUpgrade` | 3/10 |
| `MARKETPLACE_ADMIN_ROLE` | `setDefaultExpiry` | 1/10 |
| Creator (`_msgSender()` check) | `delistListing`, `renewListing`, `updatePrice` | 1/10 |
| Any caller | `registerListing`, `registerListingDirect`, view functions | 1/10 |

### Centralization Risk Assessment

**Single-key maximum damage: 3/10** (improved from 4/10 in Round 4)

The 48-hour upgrade timelock significantly reduces centralization risk. An admin must schedule an upgrade and wait 48 hours, giving monitoring systems and the community time to detect malicious upgrades. The contract holds no funds, so even a malicious upgrade cannot directly steal tokens.

**Remaining risk:** Admin can pause new listing creation (DoS), change default expiry to 365 days (annoying but not harmful), or schedule a malicious upgrade (detectable within 48-hour window).

### EIP-712 Signature Security

The signature flow is now correctly implemented:
1. Creator signs `(ipfsCID, contentHash, price, expiry, nonce)` with their key
2. Relayer submits `registerListing(creator, ipfsCID, contentHash, price, expiry, signature)`
3. Contract uses `signedExpiry` (the original value) for signature verification
4. After verification, applies default expiry substitution if `expiry == 0`
5. Nonce incremented for `creator` (not `msg.sender`)

This correctly supports both direct calls and relayer-mediated calls.

### Upgrade Safety

- Storage gap: 46 slots reserved (correct arithmetic)
- Constructor: `_disableInitializers()` prevents implementation contract initialization
- Timelock: 48-hour delay between `scheduleUpgrade()` and `_authorizeUpgrade()`
- Cancel: `cancelUpgrade()` allows aborting pending upgrades
- Events: `UpgradeScheduled` and `UpgradeCancelled` emitted for off-chain monitoring

### Anti-Gaming Measures

- `MAX_LISTINGS_PER_DAY = 50` per creator
- EIP-712 nonce-based replay protection
- CID deduplication (cleared on delist, allowing re-listing)
- `totalListingsCreated` monotonically increases (used by off-chain participation scoring)

---

## Conclusion

OmniMarketplace has been significantly hardened since the Round 4 audit. All 5 Medium and 3 Low findings have been addressed with proper fixes. The contract is well-structured for its purpose as a lightweight listing registry. The zero-fund-handling design means its attack surface is minimal.

**Mainnet readiness: YES** -- No blocking findings remain. The contract is suitable for deployment as part of the OmniBazaar marketplace infrastructure.

**Recommended pre-deployment steps:**
1. Transfer `DEFAULT_ADMIN_ROLE` to a multi-sig or governance timelock
2. Verify the `trustedForwarder_` constructor argument is set to a legitimate ERC-2771 forwarder (or `address(0)` if meta-transactions are not needed at launch)
3. Ensure the WebApp/Validator correctly handles the `creator` parameter in `registerListing()` when relaying transactions

---

*Generated by Claude Code Audit Agent -- Pre-Mainnet Round 6*
*Compared against Round 4 audit (2026-02-28): ALL findings resolved*
