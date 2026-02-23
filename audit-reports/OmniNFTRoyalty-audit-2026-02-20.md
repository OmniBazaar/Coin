# Security Audit Report: OmniNFTRoyalty

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/nft/OmniNFTRoyalty.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 176
**Upgradeable:** No
**Handles Funds:** No (registry only; royalty payments handled by marketplaces)
**Deployed At:** `0x951706B3590728F648FEC362DBEAE9b0cb60b3ed` (chain 131313)

## Executive Summary

OmniNFTRoyalty is a standalone ERC-2981 royalty registry that allows collection owners to register royalty recipients and basis points for non-OmniNFT collections. When queried, it first checks if the collection natively implements ERC-2981 (via `supportsInterface`) and delegates to the on-chain implementation; otherwise it falls back to its own registry. The audit found **no critical vulnerabilities**, but identified **2 high-severity issues**: a first-come collection squatting vulnerability allowing anyone to register as the owner of any unregistered collection, and an ERC-2981 delegation path that bypasses the contract's 25% royalty cap. Both have real-world precedent in audited protocols.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 2 |
| Low | 6 |
| Informational | 3 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 48 |
| Passed | 38 |
| Failed | 4 |
| Partial | 6 |
| **Compliance Score** | **79%** |

**Top 5 Failed/Partial Checks:**

1. **SOL-Basics-AC-4** (FAIL): No ownership verification for collection registration — anyone can claim any collection
2. **SOL-AM-FrA-1** (FAIL): `setRoyalty()` is front-runnable — attacker can front-run legitimate owner's registration
3. **SOL-CR-6** (FAIL): Single-step `Ownable` instead of `Ownable2Step` — admin transfer has no confirmation
4. **SOL-Basics-Function-1** (FAIL): `transferCollectionOwnership()` missing zero-address validation on `newOwner`
5. **SOL-AM-DOSA-6** (PARTIAL): Unwrapped external call to `royaltyInfo()` — reverts propagate as DoS

---

## High Findings

### [H-01] First-Come Collection Squatting via Permissionless Registration

**Severity:** High
**Category:** SC01 Access Control / SC02 Business Logic
**VP Reference:** VP-06 (Missing Access Control), VP-34 (Front-Running)
**Location:** `setRoyalty()` (lines 82-110)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-Basics-AC-4, SOL-AM-FrA-1), Solodit

**Description:**

The `setRoyalty()` function allows **any address** to register as the owner of any collection that has not yet been registered. There is no verification that `msg.sender` actually owns or deployed the collection contract. Once registered, the `registeredOwner` can set arbitrary royalty recipients and redirect all royalty payments.

```solidity
// Line 92-96: First-come-first-served ownership
if (collectionData[collection].registeredOwner == address(0)) {
    collectionData[collection].registeredOwner = msg.sender;
    registeredCollections.push(collection);
}
```

**Exploit Scenario:**

1. A popular NFT collection (e.g., BAYC) is deployed on OmniCoin L1 or bridged.
2. An attacker monitors the mempool and front-runs the legitimate collection deployer's `setRoyalty()` call.
3. The attacker becomes the `registeredOwner` and sets `royaltyRecipient` to their own address.
4. All marketplaces querying this registry will direct royalty payments to the attacker.
5. The legitimate owner has no recourse except asking the contract admin to use `adminSetRoyalty()`.

**Real-World Precedent:** SOL-AM-FrA-1 in Cyfrin checklist; front-running is the #4 exploit category in DeFiHackLabs (12% of incidents).

**Recommendation:**

Verify collection ownership before registration. Options:
1. **Ownership check:** `require(IERC721(collection).owner() == msg.sender || Ownable(collection).owner() == msg.sender)`
2. **Factory-gated:** Only allow registration from the OmniNFTFactory contract
3. **Signature-based:** Require a signature from the collection's deployer address

---

### [H-02] ERC-2981 Delegation Bypasses 25% Royalty Cap

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `royaltyInfo()` (line 152)
**Sources:** Agent-A, Agent-B, Agent-D, Checklist (SOL-Basics-Function-1), Solodit

**Description:**

When a collection implements `IERC2981`, the contract delegates to `IERC2981(collection).royaltyInfo(tokenId, salePrice)` and returns the result **without enforcing** the `MAX_ROYALTY_BPS = 2500` (25%) cap. A malicious or misconfigured collection contract can return royalty amounts up to 100% of the sale price.

```solidity
// Line 148-156: Delegation WITHOUT cap enforcement
if (_supportsERC2981(collection)) {
    try IERC2981(collection).supportsInterface(type(IERC2981).interfaceId) returns (bool supported) {
        if (supported) {
            (address receiver, uint256 amount) = IERC2981(collection).royaltyInfo(tokenId, salePrice);
            return (receiver, amount);  // No cap check!
        }
    } catch {}
}
```

The registry-path (lines 159-165) correctly enforces the cap via the `setRoyalty()` function's `require(royaltyBps <= MAX_ROYALTY_BPS)` check, but the delegation path has no such guard.

**Real-World Precedent:** Sudoswap audit by Cyfrin (June 2023) — identified the exact same pattern where ERC-2981 delegation returned uncapped royalty amounts, allowing collections to extract excessive fees from marketplace buyers.

**Recommendation:**

Apply the cap to delegated results:

```solidity
(address receiver, uint256 amount) = IERC2981(collection).royaltyInfo(tokenId, salePrice);
uint256 maxAmount = (salePrice * MAX_ROYALTY_BPS) / 10000;
if (amount > maxAmount) {
    amount = maxAmount;
}
return (receiver, amount);
```

---

## Medium Findings

### [M-01] Unwrapped External Call to royaltyInfo() Enables DoS

**Severity:** Medium
**Category:** SC06 Unchecked External Calls / SC09 Denial of Service
**VP Reference:** VP-30 (DoS via Revert)
**Location:** `royaltyInfo()` (line 152)
**Sources:** Agent-B, Agent-C, Agent-D, Checklist (SOL-AM-DOSA-6)

**Description:**

The `supportsInterface()` call on line 148 is correctly wrapped in a `try/catch` block, but the subsequent `royaltyInfo()` call on line 152 is **not**. If a collection contract implements `supportsInterface()` to return `true` for `IERC2981` but reverts on `royaltyInfo()`, the entire call to the registry's `royaltyInfo()` will revert, preventing the fallback to the registry data.

**Exploit Scenario:**

1. A malicious collection contract returns `true` for `supportsInterface(IERC2981)`.
2. Its `royaltyInfo()` always reverts (e.g., `revert("nope")`).
3. Any marketplace calling the registry's `royaltyInfo()` for this collection gets a revert.
4. This blocks price display, listing creation, or sale execution on marketplaces that require royalty info.

**Real-World Precedent:** SOL-AM-DOSA-6 in Cyfrin checklist; Solodit contains multiple findings about unwrapped external calls causing DoS in NFT royalty registries.

**Recommendation:**

Wrap the `royaltyInfo()` delegation in a `try/catch`:

```solidity
try IERC2981(collection).royaltyInfo(tokenId, salePrice) returns (address receiver, uint256 amount) {
    uint256 maxAmount = (salePrice * MAX_ROYALTY_BPS) / 10000;
    return (receiver, amount > maxAmount ? maxAmount : amount);
} catch {
    // Fall through to registry data
}
```

---

### [M-02] transferCollectionOwnership Allows Transfer to address(0)

**Severity:** Medium
**Category:** SC05 Input Validation
**VP Reference:** VP-22 (Missing Zero-Address Check)
**Location:** `transferCollectionOwnership()` (lines 117-125)
**Sources:** Agent-A, Agent-C, Agent-D, Checklist (SOL-Basics-Function-1)

**Description:**

The `transferCollectionOwnership()` function does not validate that `newOwner != address(0)`. Transferring ownership to the zero address effectively burns the collection registration, but the `registeredCollections` array still contains the collection address, and the royalty data remains in `collectionData`. This creates a state where:
1. The collection cannot be re-registered by a new owner (only the admin can fix it).
2. The royalty data becomes orphaned — modifiable only via `adminSetRoyalty()`.

```solidity
function transferCollectionOwnership(address collection, address newOwner) external {
    require(collectionData[collection].registeredOwner == msg.sender, "Not collection owner");
    collectionData[collection].registeredOwner = newOwner;  // No zero-address check
    // ...
}
```

**Real-World Precedent:** CodeHawks and Shieldify audits contain multiple findings for missing zero-address checks in ownership transfer functions.

**Recommendation:**

Add a zero-address check:

```solidity
require(newOwner != address(0), "Invalid new owner");
```

---

## Low Findings

### [L-01] Missing Zero-Address Check on Collection Parameter

**Severity:** Low
**VP Reference:** VP-22
**Location:** `setRoyalty()` (line 82)

`setRoyalty()` does not validate that the `collection` address is non-zero. While registering `address(0)` has no practical exploit path, it creates an inconsistent state entry.

**Recommendation:** Add `require(collection != address(0), "Invalid collection")`.

---

### [L-02] Unbounded registeredCollections Array

**Severity:** Low
**VP Reference:** VP-29
**Location:** Line 65

The `registeredCollections` array grows without bound as collections are registered. While there is no on-chain iteration over this array, the `getRegisteredCollections()` view function returns the entire array, which could cause RPC timeouts for off-chain callers at scale.

**Recommendation:** Add pagination to `getRegisteredCollections()` or implement an `EnumerableSet`.

---

### [L-03] No Deregistration Mechanism

**Severity:** Low
**VP Reference:** VP-41
**Location:** Contract-wide

There is no way to remove a collection from the registry once registered. The `registeredCollections` array and `collectionData` mapping have no deletion functions, even for the admin. Abandoned or malicious entries persist forever.

**Recommendation:** Add an `adminRemoveCollection()` function that deletes the mapping entry and removes the collection from the array.

---

### [L-04] Read-Only Reentrancy Risk for Callers

**Severity:** Low
**VP Reference:** VP-04
**Location:** `royaltyInfo()` (lines 148-152)

The `royaltyInfo()` function makes external calls to collection contracts. If a caller reads this function's return value during a callback from another contract, the returned data could be stale or manipulated. This is a concern for protocols that compose with this registry.

**Recommendation:** Document the external call behavior. Callers should be aware that `royaltyInfo()` makes external calls and should not rely on its return value within reentrancy-sensitive contexts.

---

### [L-05] Gas Griefing via Malicious Collection Contracts

**Severity:** Low
**VP Reference:** VP-32
**Location:** `royaltyInfo()` (lines 148-152)

A malicious collection contract's `supportsInterface()` or `royaltyInfo()` could consume excessive gas (e.g., via large memory allocation) without reverting. This would cause the caller's transaction to run out of gas even though the registry itself is functioning correctly.

**Recommendation:** Consider adding a gas limit to the external calls:

```solidity
try IERC2981(collection).royaltyInfo{gas: 50000}(tokenId, salePrice) ...
```

---

### [L-06] Single-Step Ownable Pattern

**Severity:** Low
**VP Reference:** N/A (Architectural)
**Location:** Lines 4, 19, 70

The contract uses OpenZeppelin's `Ownable` with single-step ownership transfer. If the owner accidentally transfers to a wrong address, ownership is permanently lost, and `adminSetRoyalty()` becomes inaccessible.

**Recommendation:** Use `Ownable2Step` which requires the new owner to accept the transfer.

---

## Informational Findings

### [I-01] transferCollectionOwnership on Unregistered Collection

**Severity:** Informational
**Location:** `transferCollectionOwnership()` (lines 117-125)

Calling `transferCollectionOwnership()` on an unregistered collection (where `registeredOwner == address(0)`) will always revert with "Not collection owner" because `msg.sender` can never equal `address(0)`. This is correct behavior but could benefit from a more descriptive error message like "Collection not registered".

---

### [I-02] Zero-BPS Registration Creates Inconsistent State

**Severity:** Informational
**Location:** `setRoyalty()` (line 82)

A collection owner can register with `royaltyBps = 0`, which means the collection appears registered but `royaltyInfo()` returns `(recipient, 0)`. This is technically valid but may confuse marketplace integrators who check `registeredOwner != address(0)` to determine if royalties apply.

---

### [I-03] Fee Stacking Concern (Royalty + Marketplace Fees)

**Severity:** Informational
**Location:** Contract-wide

The 25% royalty cap (`MAX_ROYALTY_BPS = 2500`) does not account for OmniBazaar's marketplace transaction fees (1% default + up to 3% priority). Combined, a seller could face up to 29% in total deductions. This is a marketplace design consideration, not a contract vulnerability.

---

## Known Exploit Cross-Reference

| Exploit Pattern | Source | Relevance |
|----------------|--------|-----------|
| Front-running NFT registrations | DeFiHackLabs (12% of incidents) | Direct — `setRoyalty()` is front-runnable |
| Sudoswap ERC-2981 cap bypass | Cyfrin audit (June 2023) | Exact match — delegation returns uncapped values |
| DoS via reverting external calls | SOL-AM-DOSA-6 (Cyfrin) | Direct — `royaltyInfo()` delegation not wrapped |
| Missing zero-address checks | CodeHawks, Shieldify audits | Direct — `transferCollectionOwnership()` |

## Solodit Similar Findings

- **Sudoswap (Cyfrin, 2023):** ERC-2981 royalty cap bypass via delegation — rated HIGH. Exact same pattern as H-02.
- **CodeHawks multiple contests:** Missing zero-address validation in ownership transfer functions — rated MEDIUM.
- **Shieldify/Multipli L-02:** Single-step Ownable recommendation to upgrade to Ownable2Step — rated LOW.
- **SOL-AM-FrA-1 (Cyfrin checklist):** Front-running vulnerability in permissionless registration — rated HIGH.

## Static Analysis Summary

### Slither
Skipped — full-project scan exceeds timeout threshold. Slither analyzes all contracts in the Hardhat project simultaneously; individual contract targeting not supported.

### Aderyn
Skipped — Aderyn v0.6.8 incompatible with solc v0.8.33 (project compiler version). Returns compilation errors on all contracts.

### Solhint
**0 errors, 5 warnings:**
- 3x `ordering`: Import and function ordering suggestions
- 2x `missing-natspec`: Missing NatSpec on some internal helper parameters

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Contract Owner (Ownable) | `adminSetRoyalty()` | 6/10 |
| Collection registeredOwner | `setRoyalty()`, `transferCollectionOwnership()` | 4/10 |
| Any address | `setRoyalty()` (first-come), `royaltyInfo()` (view), `getRegisteredCollections()` (view) | 3/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** The contract owner can override any collection's royalty settings via `adminSetRoyalty()`, redirecting royalty payments to any address. This is a necessary escape hatch for the squatting issue (H-01) but represents centralization risk.

**Centralization Risk Rating:** 6/10

**Recommendation:** Implement `Ownable2Step` and consider a timelock on `adminSetRoyalty()` to give collection owners time to react to unauthorized changes. Long-term, fix H-01 (ownership verification) to reduce reliance on the admin override.

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
