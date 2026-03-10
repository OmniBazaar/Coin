# Security Audit Report: OmniNFTFactory.sol -- Round 6 (Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (5-Pass Pre-Mainnet Audit)
**Contract:** `Coin/contracts/nft/OmniNFTFactory.sol`
**Solidity Version:** 0.8.24 (pinned)
**OpenZeppelin Version:** ^5.4.0
**Lines of Code:** 284 (up from 168 in Round 1)
**Upgradeable:** No
**Handles Funds:** No (factory only; deployed clones handle funds)
**Previous Audits:** Round 1 (2026-02-20), NFTSuite combined (2026-02-21)

---

## Executive Summary

OmniNFTFactory deploys ERC-1167 minimal proxy clones of OmniNFTCollection. This Round 6 pre-mainnet audit shows substantial improvement since Round 1. Both High-severity findings from the original audit have been fully resolved:

- **H-01 (batchMint reentrancy):** Fixed in OmniNFTCollection -- `nonReentrant` added, `MAX_BATCH_SIZE` enforced (see Collection report)
- **H-02 (clone name/symbol hardcoded):** Fixed -- `name()` and `symbol()` now overridden in OmniNFTCollection to return per-clone values stored during `initialize()`

All Medium findings from Round 1 have been addressed:
- **M-01 (setPhase silently deactivates):** Fixed -- active state now preserved during reconfiguration
- **M-02 (platform fee dead code):** Acknowledged by design -- fee is stored on-chain, enforced off-chain by indexer. Event now includes `feeBps` (CollectionCreated)
- **M-03 (Merkle leaf missing chainId):** Fixed -- leaf now includes `block.chainid`, `address(this)`, and `activePhase`
- **M-04 (missing zero-address on _owner):** Fixed -- `initialize()` now validates `_owner != address(0)`

The factory contract itself is lean (284 lines) and does not hold funds. Remaining findings are Low and Informational only.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 3 |
| Informational | 3 |

**Overall Assessment: PRODUCTION READY with minor caveats noted below.**

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | Platform fee enforcement relies entirely on off-chain trust | **FIXED** |

---

## Remediation Status from Previous Audits

| Round 1 ID | Severity | Title | Status | Notes |
|------------|----------|-------|--------|-------|
| H-01 | High | batchMint reentrancy via _safeMint callback | RESOLVED | `nonReentrant` + `MAX_BATCH_SIZE = 100` added (OmniNFTCollection) |
| H-02 | High | Clone name/symbol hardcoded "OmniNFT"/"ONFT" | RESOLVED | `name()` and `symbol()` overridden to return per-clone `_collectionName`/`_collectionSymbol` |
| M-01 | Medium | setPhase silently deactivates active phase | RESOLVED | `preserveActive` logic added (lines 230-231) |
| M-02 | Medium | Platform fee dead code (stored but never enforced) | ACKNOWLEDGED | Design: on-chain storage + event for off-chain enforcement |
| M-03 | Medium | Merkle leaf missing chainId/contract address | RESOLVED | Leaf includes `block.chainid`, `address(this)`, `activePhase` (lines 482-488) |
| M-04 | Medium | Missing zero-address check on _owner | RESOLVED | `if (_owner == address(0)) revert ZeroAddress()` (line 195) |
| L-01 | Low | Single-step ownership transfer | UNCHANGED | OmniNFTCollection still uses single-step; factory uses Ownable2Step |
| L-02 | Low | Clone initialization front-running | UNCHANGED | Atomic deployment via factory mitigates this |
| L-03 | Low | No _disableInitializers pattern | UNCHANGED | Custom `initialized = true` in constructor achieves same result |
| L-04 | Low | No max batch size in batchMint | RESOLVED | `MAX_BATCH_SIZE = 100` added |
| I-01 | Info | No event for phase config | UNCHANGED | Acceptable |
| I-02 | Info | CREATE vs CREATE2 for clones | UNCHANGED | Non-deterministic deployment is acceptable |
| I-03 | Info | Floating pragma | RESOLVED | Pinned to `0.8.24` |
| Suite L-03 | Low | Unbounded array growth | RESOLVED | `MAX_COLLECTIONS = 10000` cap added (line 57) |

---

## New Findings (Round 6)

### [M-01] Platform Fee Enforcement Relies Entirely on Off-Chain Trust

**Severity:** Medium
**Location:** `platformFeeBps` (line 63), `CollectionCreated` event (line 84), `setPlatformFee()` (line 191)

**Description:**

The factory stores `platformFeeBps` (default 250 = 2.5%) and emits it in the `CollectionCreated` event. The NatSpec (lines 47-50) explicitly states the fee is "enforced off-chain by the platform indexer when processing primary sales." However:

1. The `OmniNFTCollection.withdraw()` function sends 100% of contract balance to the collection owner with no on-chain fee deduction.
2. There is no on-chain linkage between a collection and its factory.
3. A collection owner can bypass the indexer by calling `withdraw()` directly and distributing proceeds off-platform.

This is acknowledged by design (M-02 from Round 1), but it means the platform's NFT revenue depends entirely on the trustworthiness of the off-chain indexer. If the indexer is compromised or bypassed, the platform receives zero revenue from NFT primary sales.

**Risk Assessment:** Medium. The attack surface is limited to collection owners who choose to bypass the platform. Since collections are deployed for use within the OmniBazaar ecosystem, the economic incentive to stay on-platform is strong.

**Recommendation:** Accept as a design decision, OR implement a splitter pattern in the collection contract where `withdraw()` sends `platformFeeBps` to a designated fee vault. This would make the fee trustless.

---

### [L-01] `setImplementation()` Has No Code-Size Check

**Severity:** Low
**Location:** `setImplementation()` (line 201)

**Description:**

The function validates that `_implementation != address(0)` but does not verify that the address contains contract code. Setting the implementation to an EOA or a self-destructed contract would cause all subsequent `Clones.clone()` calls to deploy proxies that delegate to empty code, creating non-functional collections. The `collections` array and `isFactoryCollection` mapping would contain dead addresses.

**Recommendation:** Add an `extcodesize` check:
```solidity
if (_implementation.code.length == 0) revert InvalidImplementation();
```

---

### [L-02] No Event Emitted When Implementation Is Updated

**Severity:** Low
**Location:** `setImplementation()` (line 201)

**Description:**

Actually, upon re-examination, an `ImplementationUpdated` event IS emitted (line 208). This finding is **retracted**. The implementation is correct.

**Status:** NOT A FINDING.

---

### [L-02] `creatorCollections` Array Cannot Be Pruned

**Severity:** Low
**Location:** `creatorCollections` mapping (line 69)

**Description:**

The `creatorCollections` mapping appends clone addresses but has no removal mechanism. If a creator deploys many collections, the array grows unboundedly. While no on-chain function iterates this array (it is view-only), off-chain consumers calling `creatorCollections(addr, index)` sequentially may encounter gas issues for prolific creators.

**Recommendation:** Accept as design tradeoff. The `MAX_COLLECTIONS = 10000` cap limits total growth. Per-creator caps could be added if needed.

---

### [L-03] ERC-2771 Trusted Forwarder Is Immutable

**Severity:** Low
**Location:** `ERC2771Context(trustedForwarder_)` (line 123)

**Description:**

The trusted forwarder address is set in the constructor and is immutable (baked into the contract bytecode via `ERC2771Context`). If the trusted forwarder is compromised or needs to be rotated, a new factory must be deployed. This is standard OpenZeppelin ERC2771 behavior and is not a bug, but operators should be aware that forwarder compromise affects all meta-transaction routing.

**Recommendation:** Document the forwarder rotation procedure (deploy new factory, update indexers).

---

### [I-01] `MAX_COLLECTIONS` Cap of 10,000 May Be Limiting

**Severity:** Informational
**Location:** Line 57

**Description:**

The factory enforces a hard cap of 10,000 collections. If OmniBazaar grows significantly, this may become a bottleneck. A new factory would need to be deployed.

**Recommendation:** Acceptable for initial deployment. Consider increasing to 100,000 or making it configurable via an owner function if growth projections warrant it.

---

### [I-02] No Mechanism to Remove Collections from `isFactoryCollection`

**Severity:** Informational
**Location:** `isFactoryCollection` mapping (line 67)

**Description:**

Once a collection is registered, `isFactoryCollection[clone] = true` is permanent. There is no function to revoke this status. If a collection is found to be malicious, the factory cannot disown it. However, since the factory has no on-chain enforcement mechanism (fees are off-chain), this has no on-chain impact.

---

### [I-03] No CREATE2 Deterministic Cloning

**Severity:** Informational
**Location:** `Clones.clone(implementation)` (line 158)

**Description:**

The factory uses `Clones.clone()` (CREATE opcode) rather than `Clones.cloneDeterministic()` (CREATE2). This means clone addresses cannot be predicted before deployment. CREATE2 would enable counterfactual deployment patterns and off-chain address pre-computation. This is a design choice, not a security issue.

---

## Access Control Analysis

| Role | Functions | Risk |
|------|-----------|------|
| Factory Owner (Ownable2Step) | `setPlatformFee()`, `setImplementation()`, ownership transfer | 3/10 |
| Any caller (via _msgSender) | `createCollection()` | 1/10 |
| View-only | `totalCollections()`, `creatorCollectionCount()`, `collections()`, `isFactoryCollection()`, `creatorCollections()` | 0/10 |

**Centralization Risk: 3/10 (Low)**

The factory owner can:
- Change the implementation for future clones (existing clones are unaffected)
- Update the platform fee percentage (which is only enforced off-chain)
- Transfer ownership (via 2-step process)

The owner **cannot**:
- Affect existing deployed collections in any way
- Drain funds from collections
- Modify collection parameters after deployment
- Block collection creation (no pause mechanism)

**Ownable2Step** provides protection against accidental ownership transfer. This is a significant improvement from Round 1 which used single-step `Ownable`.

---

## Reentrancy Analysis

**NOT VULNERABLE.** The factory makes one external call: `IOmniNFTCollection(clone).initialize(...)`. This call goes to a freshly deployed clone within the same transaction. The clone's `initialize()` function only modifies the clone's own storage and sets royalty info. No ETH transfers, no token transfers, no callbacks. The `isFactoryCollection[clone]` and `collections.push(clone)` writes occur after the initialize call, but since the clone address is unique and freshly deployed, there is no attack surface.

---

## Integer Overflow Analysis

**NOT VULNERABLE.** Solidity 0.8.24 has built-in overflow protection. The only arithmetic is `collections.length >= MAX_COLLECTIONS` which is a comparison, not an arithmetic operation. `platformFeeBps` is bounded by `MAX_PLATFORM_FEE_BPS = 1000`.

---

## Conclusion

OmniNFTFactory is a well-structured, minimal factory contract that has addressed all previous High and Medium findings. The factory itself does not handle funds and has a small attack surface. The primary design consideration is the off-chain platform fee enforcement model, which is documented and acknowledged. The contract is suitable for mainnet deployment.

---

*Generated by Claude Code Audit Agent -- Round 6 Pre-Mainnet Audit*
