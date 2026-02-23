# Security Audit Report: ReputationCredential

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/reputation/ReputationCredential.sol`
**Solidity Version:** ^0.8.24
**Lines of Code:** 280
**Upgradeable:** No
**Handles Funds:** No (soulbound reputation credential only)
**Deployed At:** `0x4f41a213a4eBa3e74Cc17b28695BCC3e8692be63` (chain 131313)

## Executive Summary

ReputationCredential is a soulbound ERC-721 (ERC-5192 compliant) that stores on-chain reputation data for OmniBazaar users. Each user receives at most one non-transferable token containing their marketplace reputation metrics (transactions, rating, KYC tier, participation score, etc.). The contract has a minimal attack surface — it holds no funds, has a single immutable authorized updater, and blocks all transfers via an `_update` override. The audit found **no critical or high vulnerabilities**. The primary concerns are **missing input validation** on reputation data fields (Medium) and the **immutable updater with no key rotation** (Medium). Both are defense-in-depth improvements rather than exploitable vulnerabilities.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 4 |
| Informational | 4 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 48 |
| Passed | 42 |
| Failed | 3 |
| Partial | 3 |
| **Compliance Score** | **87.5%** |

**Top 5 Failed/Partial Checks:**

1. **SOL-Basics-AC-4** (FAIL): `AUTHORIZED_UPDATER` is immutable — cannot be transferred or rotated if compromised or lost
2. **SOL-Basics-AC-6** (FAIL): `approve()` and `setApprovalForAll()` inherited from ERC721 are not overridden for soulbound tokens
3. **SOL-Basics-Function-1** (FAIL): No input validation on `ReputationData` fields — `participationScore`, `kycTier`, `averageRating` unbounded
4. **SOL-AM-ReentrancyAttack-2** (PARTIAL): `_safeMint` callback in `mint()` fires before `_reputation` and `_userToken` state updates
5. **SOL-Basics-Inheritance-3** (PARTIAL): ERC-5192 interface partially implemented — `Unlocked` event not declared

---

## Medium Findings

### [M-01] No Bounds Validation on Reputation Data Fields

**Severity:** Medium
**Category:** SC05 Input Validation / SC02 Business Logic
**VP Reference:** VP-23 (Missing Amount Validation)
**Location:** `mint()` (lines 131-148), `updateReputation()` (lines 156-168)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-Basics-Function-1), Solodit (3+ matches)

**Description:**

The `ReputationData` struct documents specific value ranges in NatSpec comments, but neither `mint()` nor `updateReputation()` enforce these bounds on-chain:

| Field | Documented Range | Actual Type Range | Enforced? |
|-------|-----------------|-------------------|-----------|
| `participationScore` | 0-100 | uint16: 0-65,535 | No |
| `kycTier` | 0-4 | uint8: 0-255 | No |
| `averageRating` | 0-500 (x100 scale) | uint16: 0-65,535 | No |

Since the stated purpose of this contract is to make reputation "verifiable without trusting OmniBazaar infrastructure," on-chain enforcement is the correct defense layer. A compromised or buggy `AUTHORIZED_UPDATER` could write `participationScore = 65535` or `kycTier = 255`, and downstream consumers reading `getReputation()` would have no way to detect the invalid data.

**Impact:** OmniBazaar uses `participationScore >= 50` for validator qualification. An inflated score could grant undeserved validator privileges. An out-of-range `kycTier` could bypass KYC-gated features in integrating contracts.

**Real-World Precedent:** Input validation findings are among the most common in Solodit (SOL-Basics-Function-1). Beefy Finance (Cyfrin audit) had a Medium-severity finding for unconstrained numeric parameters causing reverts.

**Recommendation:**

Add range validation in both functions:

```solidity
error InvalidRating(uint16 rating);
error InvalidKYCTier(uint8 tier);
error InvalidScore(uint16 score);

function _validateReputation(ReputationData calldata data) private pure {
    if (data.averageRating > 500) revert InvalidRating(data.averageRating);
    if (data.kycTier > 4) revert InvalidKYCTier(data.kycTier);
    if (data.participationScore > 100) revert InvalidScore(data.participationScore);
}
```

---

### [M-02] Immutable AUTHORIZED_UPDATER with No Key Rotation

**Severity:** Medium
**Category:** SC01 Access Control
**VP Reference:** VP-06 (Access Control Design)
**Location:** `AUTHORIZED_UPDATER` (line 64), constructor (lines 80-85)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-Basics-AC-4), Solodit (2+ matches)

**Description:**

`AUTHORIZED_UPDATER` is declared `immutable`, meaning it is permanently set at deployment and can never be changed. This creates two operational risks:

1. **Key compromise:** If the updater key is compromised, an attacker can set arbitrary reputation data for any user. There is no mechanism to rotate to a new key — the entire contract must be redeployed and all existing tokens are orphaned.
2. **Key loss:** If the key is lost, no new credentials can be minted and no existing credentials can be updated. The contract becomes permanently read-only.

For a reputation system intended to serve the platform for its lifetime, this creates a single point of failure with no recovery path.

**Real-World Precedent:** Cyfrin's Solodit checklist on rug pull prevention recommends multisig wallets that "allow you to maintain a consistent public wallet address while enabling the underlying signer keys to be changed or updated." The Ronin Network incident ($624M, 2022) demonstrated the catastrophic impact of compromised keys with no rotation mechanism.

**Recommendation:**

Replace immutable updater with a two-step transfer pattern:

```solidity
address public authorizedUpdater;
address public pendingUpdater;

function transferUpdater(address newUpdater) external onlyUpdater {
    pendingUpdater = newUpdater;
}

function acceptUpdater() external {
    if (msg.sender != pendingUpdater) revert NotAuthorized();
    authorizedUpdater = pendingUpdater;
    pendingUpdater = address(0);
}
```

Alternatively, use OpenZeppelin's `Ownable2Step` or deploy a multisig as the updater.

---

## Low Findings

### [L-01] _safeMint CEI Violation in mint()

**Severity:** Low
**VP Reference:** VP-05 (ERC721 Callback Reentrancy)
**Location:** `mint()` (lines 137-147)
**Sources:** Agent-A, Agent-D, Checklist (SOL-AM-ReentrancyAttack-2), Solodit (3+ matches: XDEFI, NextGen, HypeBears)

The `mint()` function calls `_safeMint(user, tokenId)` at line 140, which triggers `onERC721Received` on the recipient if it is a contract. At the point of the callback, `_reputation[tokenId]` (line 141) and `_userToken[user]` (line 144) have not yet been set. This violates the Checks-Effects-Interactions pattern.

During the callback window:
- `hasReputation(user)` returns `false` even though the token is already owned
- `getReputation(user)` reverts with `TokenNotFound`
- `tokenURI(tokenId)` returns metadata with all-zero reputation data

**Mitigating Factor:** The `onlyUpdater` modifier prevents any address other than the trusted `AUTHORIZED_UPDATER` from calling `mint()`. The recipient's `onERC721Received` callback cannot re-enter `mint()` unless it is the updater itself. This makes practical exploitation extremely unlikely.

**Real-World Precedent:** _safeMint reentrancy is the most frequently reported ERC-721 vulnerability in Solodit. High-severity findings exist for XDEFI (Code4rena), NextGen (Code4rena), and the HypeBears incident (real-world exploit).

**Recommendation:**

Move state updates before `_safeMint`:

```solidity
_reputation[tokenId] = data;
_reputation[tokenId].lastUpdated = uint64(block.timestamp);
_userToken[user] = tokenId;
_safeMint(user, tokenId);  // Interaction last
```

Or use `_mint()` instead of `_safeMint()` since the updater is trusted.

---

### [L-02] Missing Zero-Address Check in Constructor

**Severity:** Low
**VP Reference:** VP-22 (Missing Zero-Address Check)
**Location:** Constructor (lines 80-85)
**Sources:** Agent-A, Agent-C, Agent-D, Solodit (3+ matches)

The constructor does not validate `authorizedUpdater != address(0)`. Since `AUTHORIZED_UPDATER` is immutable, deploying with `address(0)` permanently bricks the contract — no tokens can ever be minted or updated.

**Recommendation:** Add `if (authorizedUpdater == address(0)) revert NotAuthorized();`

---

### [L-03] approve() and setApprovalForAll() Not Blocked for Soulbound Tokens

**Severity:** Low
**VP Reference:** N/A (ERC-5192 Completeness)
**Location:** Inherited from ERC721 (not overridden)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-Basics-AC-6, SOL-Basics-Inheritance-1), Solodit

The `_update` override correctly blocks all transfers, but `approve()` and `setApprovalForAll()` remain callable and succeed. Users can grant approvals that can never be exercised. This wastes gas, creates misleading on-chain state, and may confuse marketplace integrators that check approvals before attempting transfers.

**Recommendation:**

```solidity
function approve(address, uint256) public pure override {
    revert Soulbound();
}

function setApprovalForAll(address, bool) public pure override {
    revert Soulbound();
}
```

---

### [L-04] No Credential Revocation Mechanism

**Severity:** Low
**VP Reference:** N/A (Design Gap)
**Location:** `_update` override (lines 113-122)
**Sources:** Agent-B, Agent-C, Solodit (ERC-5484, PartyDAO)

The `_update` override blocks all non-mint transfers, including burns. There is no `revoke()` or `burn()` function. If a user commits fraud, has their KYC revoked, or is detected as a sybil, their reputation credential persists on-chain with whatever data was last written. The updater can zero out fields via `updateReputation()`, but `hasReputation()` still returns `true`.

**Mitigating Factor:** The updater can effectively neutralize a credential by setting all fields to zero. This achieves most of the practical effect of revocation.

**Recommendation:** Add a `revoke()` function restricted to `onlyUpdater`, or modify `_update` to allow burns: `if (from != address(0) && to != address(0)) revert Soulbound();`

---

## Informational Findings

### [I-01] Floating Pragma

**Severity:** Informational
**Location:** Line 2

The contract uses `pragma solidity ^0.8.24;` which allows compilation with any 0.8.x from 0.8.24 onwards. Pin to `pragma solidity 0.8.24;` for reproducible builds.

---

### [I-02] Missing Unlocked Event (ERC-5192 Partial Compliance)

**Severity:** Informational
**Location:** Events section (lines 37-47)

ERC-5192 defines both `Locked(uint256)` and `Unlocked(uint256)` events. The contract only declares `Locked`. While `Unlocked` is never needed (tokens are permanently locked), declaring it improves interface compliance for ABI-checking tools.

---

### [I-03] Gas-Heavy tokenURI for On-Chain Consumers

**Severity:** Informational
**Location:** `tokenURI()` (lines 208-244)

The fully on-chain metadata generation uses 7 `uint256.toString()` conversions, 8+ `abi.encodePacked()` calls, and Base64 encoding. Estimated gas: ~50,000-100,000 for on-chain callers. This is standard practice for on-chain NFT metadata but worth documenting for composability.

---

### [I-04] Solhint Warnings

**Severity:** Informational
**Location:** Contract-wide

Solhint reports 5 errors and 9 warnings:
- 5x `quotes`: Single quotes used instead of double quotes in JSON string literals
- 3x `use-natspec`: Missing @notice/@param tags on `Locked` event, `AUTHORIZED_UPDATER`, `_update`, `_attr`
- 1x `gas-indexed-events`: `participationScore` on `ReputationUpdated` could be indexed
- 1x `gas-small-strings`: String exceeds 32 bytes in `abi.encodePacked`
- 1x `ordering`: Event definition after custom error definition

---

## Known Exploit Cross-Reference

| Exploit Pattern | Source | Relevance |
|----------------|--------|-----------|
| _safeMint reentrancy (HypeBears) | BlockSec 2022 | Direct — same CEI violation pattern in mint() |
| XDEFI _safeMint callback (Code4rena) | High severity | Direct — state updates after callback, bypassing guard |
| NextGen recursive minting (Code4rena) | High severity | Direct — minting past limits via onERC721Received |
| Missing zero-address validation | CodeHawks, Sherlock | Direct — immutable constructor parameter |
| Input validation failures | Beefy Finance (Cyfrin) | Direct — unconstrained numeric parameters |

No DeFiHackLabs fund-loss incidents match this contract — the contract holds no funds and has no value extraction paths.

## Solodit Similar Findings

- **XDEFI Distribution (Code4rena, 2022):** _safeMint callback reentrancy allowing reward inflation — rated HIGH. Same CEI pattern as L-01.
- **NextGen NFT (Code4rena, 2023):** _safeMint recursive minting past max allowance — rated HIGH.
- **HypeBears (BlockSec, 2022):** Real-world _safeMint reentrancy exploit — practical exploitation of the exact pattern.
- **CodeHawks multiple contests:** Missing zero-address validation in constructors — rated LOW/INFORMATIONAL.
- **PartyDAO (Code4rena):** NFT burn/revocation interactions with governance — rated MEDIUM.
- **ERC-5484 (EIP):** Defines `BurnAuth` for soulbound tokens — production systems expected to implement revocation.

## Static Analysis Summary

### Slither
Skipped — full-project scan exceeds timeout threshold. Slither analyzes all contracts in the Hardhat project simultaneously; individual contract targeting not supported.

### Aderyn
Skipped — Aderyn v0.6.8 incompatible with solc v0.8.33 (project compiler version). Returns compilation errors on all contracts.

### Solhint
**5 errors, 9 warnings:**
- 5x `quotes`: Single quotes in JSON string literals (tokenURI, _attr)
- 3x `use-natspec`: Missing NatSpec on Locked event, AUTHORIZED_UPDATER, _update, _attr
- 1x `gas-indexed-events`: participationScore not indexed
- 1x `gas-small-strings`: Long string in encodePacked
- 1x `ordering`: Event defined after custom error

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| AUTHORIZED_UPDATER (immutable) | `mint()`, `updateReputation()` | 5/10 |
| Token holder | `approve()`, `setApprovalForAll()` (succeed but useless) | 1/10 |
| Any address | View functions: `locked()`, `getReputation()`, `getTokenId()`, `hasReputation()`, `tokenURI()`, `supportsInterface()` | 0/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** The `AUTHORIZED_UPDATER` can mint reputation tokens for any address and set arbitrary reputation data (including out-of-range values due to M-01). A compromised updater could inflate a sybil account's reputation or degrade a legitimate user's credential. However, the updater cannot transfer tokens, drain funds, or upgrade the contract.

**Centralization Risk Rating:** 5/10

The updater has full control over reputation data integrity but no structural damage capability. The immutable design prevents governance takeover but creates a single point of failure for key compromise or loss.

**Recommendation:** Deploy a multisig wallet or governance contract as the `AUTHORIZED_UPDATER`. If using an EOA, implement key rotation capability (see M-02). Consider adding a timelock on reputation downgrades to allow users to dispute before changes take effect.

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
