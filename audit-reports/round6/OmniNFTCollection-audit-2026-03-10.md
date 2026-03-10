# Security Audit Report: OmniNFTCollection.sol -- Round 6 (Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (5-Pass Pre-Mainnet Audit)
**Contract:** `Coin/contracts/nft/OmniNFTCollection.sol`
**Solidity Version:** 0.8.24 (pinned)
**OpenZeppelin Version:** ^5.4.0
**Lines of Code:** 571 (up from 338 in Round 1)
**Upgradeable:** No (ERC-1167 clone pattern with custom initializer)
**Handles Funds:** Yes (ETH mint revenue, ERC-2981 royalties)
**Previous Audits:** Round 1 (2026-02-20), NFTSuite combined (2026-02-21)

---

## Executive Summary

OmniNFTCollection is an ERC-721 collection contract deployed as ERC-1167 minimal proxy clones via OmniNFTFactory. This Round 6 audit confirms that all Critical, High, and Medium findings from previous audits have been resolved. The contract has undergone significant hardening:

- **H-01 (batchMint reentrancy):** Fixed -- `nonReentrant` modifier added, `MAX_BATCH_SIZE = 100` enforced
- **H-02 (clone name/symbol):** Fixed -- `name()` and `symbol()` overridden to return per-clone values from `_collectionName` and `_collectionSymbol`
- **M-01 (setPhase deactivation):** Fixed -- `preserveActive` logic preserves active state during reconfiguration
- **M-03 (Merkle leaf missing chainId):** Fixed -- leaf includes `block.chainid`, `address(this)`, and `activePhase`
- **M-04 (zero-address owner):** Fixed -- `initialize()` validates `_owner != address(0)`
- **M-06 (batchMint unbounded):** Fixed -- `MAX_BATCH_SIZE = 100` cap with `BatchSizeExceeded` error

The contract is well-structured with proper use of ReentrancyGuard, ERC2981, and ERC2771Context for meta-transactions. Remaining findings are Low and Informational.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 4 |
| Informational | 3 |

**Overall Assessment: PRODUCTION READY with minor caveats noted below.**

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | Single-step ownership transfer without confirmation | **FIXED** |
| M-02 | Medium | `onlyOwner` modifier uses `msg.sender` instead of `_msgSender()` | **FIXED** |

---

## Remediation Status from Previous Audits

| Round 1 ID | Severity | Title | Status | Notes |
|------------|----------|-------|--------|-------|
| H-01 | High | batchMint _safeMint reentrancy (HypeBears pattern) | RESOLVED | `nonReentrant` modifier added (line 307), `MAX_BATCH_SIZE = 100` (line 309) |
| H-02 | High | All clones share hardcoded name "OmniNFT"/"ONFT" | RESOLVED | `name()` and `symbol()` overridden (lines 384-412) to return `_collectionName`/`_collectionSymbol` stored during `initialize()` |
| M-01 | Medium | setPhase silently deactivates active phase | RESOLVED | `preserveActive` flag (lines 230-231) preserves active state when reconfiguring the current active phase |
| M-02 | Medium | Platform fee dead code | ACKNOWLEDGED | By design -- factory emits fee in event for off-chain enforcement |
| M-03 | Medium | Merkle leaf missing chainId/contract address | RESOLVED | Leaf now: `keccak256(abi.encodePacked(block.chainid, address(this), activePhase, caller))` (lines 482-488) |
| M-04 | Medium | Missing zero-address check on _owner | RESOLVED | `if (_owner == address(0)) revert ZeroAddress()` (line 195) |
| Suite M-06 | Medium | batchMint missing nonReentrant and upper bound | RESOLVED | Both added (lines 307, 309) |
| L-01 | Low | Single-step ownership transfer | UNCHANGED | See M-01 below |
| L-02 | Low | Clone initialization front-running | UNCHANGED | Mitigated by atomic factory deployment |
| L-03 | Low | No _disableInitializers pattern | UNCHANGED | `initialized = true` in constructor achieves same |
| L-04 | Low | No maximum batch size | RESOLVED | `MAX_BATCH_SIZE = 100` added |
| I-01 | Info | No event for phase config | UNCHANGED | Acceptable |
| I-03 | Info | Floating pragma | RESOLVED | Pinned to `0.8.24` |

---

## New Findings (Round 6)

### [M-01] Single-Step Ownership Transfer Without Confirmation

**Severity:** Medium
**Location:** `transferOwnership()` (lines 353-358)

**Description:**

The `transferOwnership()` function immediately transfers ownership to `newOwner` in a single step:

```solidity
function transferOwnership(address newOwner) external onlyOwner {
    if (newOwner == address(0)) revert TransferFailed();
    owner = newOwner;
}
```

This differs from the factory which uses `Ownable2Step`. If the owner mistypes the new address, ownership is permanently and irrevocably lost. The collection owner controls:
- All minting phases and pricing (`setPhase`, `setActivePhase`)
- Batch minting (`batchMint`)
- Revenue withdrawal (`withdraw`)
- Metadata reveal (`reveal`)

Losing ownership permanently locks all accumulated ETH in the contract (no other withdrawal path exists) and prevents any future administrative actions.

**Recommendation:** Implement a 2-step pattern:
```solidity
address public pendingOwner;

function transferOwnership(address newOwner) external onlyOwner {
    if (newOwner == address(0)) revert ZeroAddress();
    pendingOwner = newOwner;
}

function acceptOwnership() external {
    if (msg.sender != pendingOwner) revert NotOwner();
    owner = pendingOwner;
    pendingOwner = address(0);
}
```

---

### [M-02] `onlyOwner` Modifier Uses `msg.sender` Instead of `_msgSender()`

**Severity:** Medium
**Location:** `onlyOwner` modifier (lines 148-151)

**Description:**

The `onlyOwner` modifier checks `msg.sender != owner`:

```solidity
modifier onlyOwner() {
    if (msg.sender != owner) revert NotOwner();
    _;
}
```

However, the contract supports ERC-2771 meta-transactions via `ERC2771Context`. All other caller-identity checks in the contract use `_msgSender()` (e.g., `mint()` at line 272). The `onlyOwner` modifier should also use `_msgSender()` to support meta-transactions for owner operations. Without this fix, the collection owner cannot use a trusted forwarder to call owner-only functions.

**Impact:** Meta-transaction support is broken for all owner-only operations (`setPhase`, `setActivePhase`, `batchMint`, `reveal`, `withdraw`, `transferOwnership`). The owner must always call these functions directly.

**Recommendation:**
```solidity
modifier onlyOwner() {
    if (_msgSender() != owner) revert NotOwner();
    _;
}
```

---

### [L-01] `withdraw()` Sends All ETH to Owner -- No Platform Fee Deduction

**Severity:** Low
**Location:** `withdraw()` (lines 338-347)

**Description:**

`withdraw()` sends the entire contract balance to the owner. There is no on-chain deduction for the platform fee (`platformFeeBps` stored in the factory). As noted in the factory audit, this is by design -- fees are enforced off-chain. However, a malicious collection owner could call `withdraw()` directly, bypassing the platform's off-chain fee enforcement.

**Recommendation:** Accept as design decision. The off-chain indexer approach is documented. For stronger enforcement, consider adding the factory address and fee deduction to the collection contract.

---

### [L-02] `initialize()` Has No Caller Restriction

**Severity:** Low
**Location:** `initialize()` (lines 182-210)

**Description:**

The `initialize()` function is `external` with no access control. Anyone could call it on a freshly deployed clone before the factory does. However, the factory deploys and initializes atomically in the same transaction (`Clones.clone()` followed by `initialize()`), eliminating the front-running window.

The only risk is if someone deploys a clone of the implementation contract outside the factory (e.g., by calling `Clones.clone()` on the implementation address directly). In that case, anyone could initialize it with arbitrary parameters. This is not a supported use case.

**Recommendation:** For defense-in-depth, consider adding a factory check: `if (_msgSender() != factory) revert Unauthorized();` where `factory` is set in the constructor. However, this would require the implementation to know the factory address at deployment time, which complicates the deployment flow.

---

### [L-03] `_safeMint` in `mint()` Exposes Callback Attack Surface

**Severity:** Low
**Location:** `mint()` (lines 289-291)

**Description:**

The `mint()` function uses `_safeMint()` which calls `onERC721Received()` on the recipient if it is a contract. While `nonReentrant` prevents re-entering `mint()`, a malicious contract could use the callback to:
1. Read stale state from other contracts during the callback
2. Perform external calls that affect the minting economics (e.g., front-running another user's mint)

The `nonReentrant` guard adequately prevents the primary reentrancy risk. The residual callback risk is theoretical and low-impact.

**Recommendation:** No action needed. The `nonReentrant` guard is sufficient protection.

---

### [L-04] No `burn()` Function -- NFTs Cannot Be Destroyed

**Severity:** Low
**Location:** Contract-wide

**Description:**

The contract does not implement `burn()` or expose ERC721's internal `_burn()`. Once minted, tokens cannot be destroyed. This may be intentional (preserving royalty revenue and collection integrity), but it prevents users from removing unwanted NFTs from their wallet's on-chain record.

**Recommendation:** Document this as intentional. If burning is desired, add:
```solidity
function burn(uint256 tokenId) external {
    if (_msgSender() != ownerOf(tokenId)) revert NotOwner();
    _burn(tokenId);
}
```

---

### [I-01] No Event Emitted on Phase Configuration

**Severity:** Informational
**Location:** `setPhase()` (lines 220-241)

**Description:**

`setPhase()` does not emit an event when a phase is configured. Only `setActivePhase()` emits `PhaseChanged`. Off-chain indexers cannot track price or whitelist changes without scanning storage directly.

**Recommendation:** Add a `PhaseConfigured(uint8 indexed phaseId, uint256 price, uint16 maxPerWallet)` event.

---

### [I-02] `totalMinted()` Returns `nextTokenId`, Not Actual Minted Count

**Severity:** Informational
**Location:** `totalMinted()` (lines 365-367)

**Description:**

The function returns `nextTokenId`. If token IDs start at 0, this equals the total minted count. However, there is no explicit documentation that token IDs are zero-indexed. If the starting ID were ever changed, this function would return an incorrect count. Currently, `nextTokenId` starts at 0 (Solidity default for uint256), so this is correct.

---

### [I-03] `reveal()` Is One-Way and Cannot Be Undone

**Severity:** Informational
**Location:** `reveal()` (lines 327-332)

**Description:**

Once `reveal()` is called, `revealed = true` and `AlreadyRevealed` prevents re-calling. The `_revealedBaseURI` cannot be updated after reveal. If the revealed URI points to incorrect or compromised metadata, there is no recovery path. This is standard NFT reveal behavior but is worth documenting.

**Recommendation:** Consider adding a `setBaseURI()` function (owner-only) that allows updating the URI after reveal, or accept the immutability as a feature (trustless metadata).

---

## Reentrancy Analysis

**Status: ADEQUATELY PROTECTED**

| Function | Reentrancy Guard | External Calls | Verdict |
|----------|-----------------|----------------|---------|
| `mint()` | `nonReentrant` | `_safeMint()` -> `onERC721Received()` callback | SAFE |
| `batchMint()` | `nonReentrant` | `_safeMint()` in loop -> callbacks | SAFE |
| `withdraw()` | `nonReentrant` | `payable(owner).call{value: balance}("")` | SAFE |
| `setPhase()` | None needed | No external calls | SAFE |
| `setActivePhase()` | None needed | No external calls | SAFE |
| `reveal()` | None needed | No external calls | SAFE |
| `transferOwnership()` | None needed | No external calls | SAFE |

The `_safeMint()` callback is the primary reentrancy vector. Both `mint()` and `batchMint()` are protected by `nonReentrant`. The `withdraw()` function uses `nonReentrant` and follows CEI pattern (balance check -> send -> emit).

---

## ERC-721 Callback Analysis

**`_safeMint()` Callbacks:**

Both `mint()` and `batchMint()` use `_safeMint()`, which calls `IERC721Receiver.onERC721Received()` on the recipient if it is a contract. This creates a callback vector:

1. **In `mint()`:** Protected by `nonReentrant`. The callback occurs inside the loop after each token is minted. State is consistent at each callback point because `nextTokenId` is incremented before `_safeMint` returns.

2. **In `batchMint()`:** Protected by `nonReentrant`. Same loop pattern as `mint()`. The callback could theoretically be used to front-run other minters, but this is a general EVM property, not specific to this contract.

**Conclusion:** Callback safety is properly handled via `nonReentrant`. No cross-function reentrancy is possible.

---

## ERC-2981 Royalty Analysis

**Implementation:** The contract uses OpenZeppelin's `ERC2981` with `_setDefaultRoyalty()` called during `initialize()`. This sets a default royalty for all token IDs.

**Enforcement:** ERC-2981 is a voluntary standard. Royalty info is returned by `royaltyInfo()` but enforcement depends on marketplace implementation. Major marketplaces (OpenSea, Blur) have varying levels of ERC-2981 support.

**Configuration:**
- Maximum royalty: 2500 bps (25%) -- validated in `initialize()` line 196
- Royalty recipient validated: must be non-zero if royaltyBps > 0 (line 207)
- No function to update royalty after initialization (immutable)

**Risk:** If the royalty recipient address is lost or compromised, royalties cannot be redirected. This is a tradeoff between immutability (trustless for buyers) and flexibility (collection owner control).

---

## Access Control Analysis

| Role | Functions | Risk |
|------|-----------|------|
| Collection Owner | `setPhase()`, `setActivePhase()`, `batchMint()`, `reveal()`, `withdraw()`, `transferOwnership()` | 6/10 |
| Whitelisted User | `mint()` (with valid Merkle proof + payment) | 1/10 |
| Any User | `mint()` (public phase, with payment) | 1/10 |

**Centralization Risk: 6/10 (Moderate-High)**

The collection owner has full control over minting economics and revenue:
- Can change mint prices instantly via `setPhase()`
- Can batch-mint to themselves up to `maxSupply`
- Can withdraw all accumulated ETH at any time
- Can prevent all minting by setting `activePhase = 0`
- Single-step ownership transfer risks permanent loss

The owner **cannot**:
- Modify existing token ownership
- Change royalty configuration after initialization
- Increase `maxSupply`
- Re-reveal metadata after initial reveal

---

## Conclusion

OmniNFTCollection has resolved all previous Critical, High, and Medium findings. The contract demonstrates strong security practices with `ReentrancyGuard`, `ERC2981` royalties, ERC-2771 meta-transaction support, and Merkle-based whitelist verification with cross-chain replay protection. The two remaining Medium findings (single-step ownership and `onlyOwner` using `msg.sender`) are straightforward fixes. The contract is suitable for mainnet deployment with these minor improvements.

---

*Generated by Claude Code Audit Agent -- Round 6 Pre-Mainnet Audit*
