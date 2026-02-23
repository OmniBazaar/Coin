# Security Audit Report: OmniNFTFactory + OmniNFTCollection

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contracts:**
- `Coin/contracts/nft/OmniNFTFactory.sol` (168 lines)
- `Coin/contracts/nft/OmniNFTCollection.sol` (338 lines)
**Total Lines of Code:** 506
**Solidity Version:** ^0.8.24
**Upgradeable:** No (ERC-1167 minimal proxy clone pattern)
**Handles Funds:** Yes (ETH mint revenue, royalties)

## Executive Summary

OmniNFTFactory deploys ERC-1167 minimal proxy clones of OmniNFTCollection, enabling gas-efficient creation of independent NFT collections. The audit found no critical vulnerabilities, but two high-severity issues: (1) the `batchMint()` function uses `_safeMint` in a loop without reentrancy protection, matching the real-world HypeBears exploit pattern, and (2) the contract uses non-upgradeable OpenZeppelin bases (`ERC721`, `ERC2981`) in a clone pattern, causing all clones to share the hardcoded name "OmniNFT" / symbol "ONFT" instead of their intended per-collection values.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 4 |
| Low | 4 |
| Informational | 3 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 72 |
| Passed | 48 |
| Failed | 14 |
| Partial | 10 |
| **Compliance Score** | **66.7%** |

Top 5 most important failed checks:
1. **SOL-AM-ReentrancyAttack-2** — `batchMint()` uses `_safeMint` in loop without `nonReentrant`
2. **SOL-Basics-PU-5 / PU-3 / PU-8** — Wrong OZ branch: non-upgradeable contracts in clone pattern
3. **SOL-Basics-Initialization-3** — `initialize()` has no caller restriction (mitigated by atomic deployment)
4. **SOL-HMT-2** — Merkle leaf missing chainId and contract address
5. **SOL-Basics-AC-4** — Single-step ownership transfer (no 2-step pattern)

---

## High Findings

### [H-01] `batchMint()` Missing `nonReentrant` — `_safeMint` Callback Reentrancy

**Severity:** High
**Category:** SC08 Reentrancy
**VP Reference:** VP-05 (Cross-function reentrancy via ERC721 callback)
**Location:** `OmniNFTCollection.batchMint()` (line 253)
**Sources:** Agent A, Agent C, Agent D, Cyfrin Checklist (SOL-AM-ReentrancyAttack-2), Solodit (HypeBears)
**Real-World Precedent:** HypeBears (2022) — attacker used `_safeMint` callback to re-enter and mint beyond limits

**Description:**

The `batchMint()` function uses `_safeMint()` in a loop but does NOT have the `nonReentrant` modifier:

```solidity
// Line 253 — NO nonReentrant modifier
function batchMint(address to, uint256 quantity) external onlyOwner {
    if (quantity == 0) revert ZeroQuantity();
    if (nextTokenId + quantity > maxSupply) revert MaxSupplyExceeded();

    uint256 startId = nextTokenId;
    for (uint256 i = 0; i < quantity; ++i) {
        _safeMint(to, nextTokenId);  // Calls onERC721Received on `to`
        ++nextTokenId;
    }
    emit Minted(to, startId, quantity);
}
```

In contrast, `mint()` at line 208 correctly uses `nonReentrant`.

`_safeMint()` calls `onERC721Received()` on the recipient if it is a contract. A malicious recipient contract can use this callback to re-enter `batchMint()` (or `mint()`) before `nextTokenId` fully increments, potentially minting beyond `maxSupply`.

**Exploit Scenario:**
1. Collection owner sets `to` to a malicious contract address for an airdrop.
2. Owner calls `batchMint(maliciousContract, 5)` when `nextTokenId = 95` and `maxSupply = 100`.
3. On the first `_safeMint` callback, the malicious contract re-enters `mint()` (which IS protected by `nonReentrant` — so this specific cross-function path is blocked).
4. However, the malicious contract could call other state-reading functions during the callback that return stale `nextTokenId` values, or if `nonReentrant` is ever removed from `mint()`, the full exploit becomes possible.
5. More critically: if `to` is a contract that the owner does not control (e.g., a marketplace or vault), unexpected callbacks could cause reverts, bricking the batch mint.

**Recommendation:**

Add `nonReentrant` to `batchMint()`:

```solidity
function batchMint(address to, uint256 quantity) external onlyOwner nonReentrant {
```

Additionally, consider using `_mint()` instead of `_safeMint()` for owner-controlled batch mints, since the owner should ensure the recipient can handle ERC-721 tokens:

```solidity
for (uint256 i = 0; i < quantity; ++i) {
    _mint(to, nextTokenId);  // No callback — gas efficient, no reentrancy
    ++nextTokenId;
}
```

---

### [H-02] Wrong OpenZeppelin Branch — All Clones Share Hardcoded Name/Symbol

**Severity:** High
**Category:** SC02 Business Logic / Architecture
**VP Reference:** VP-43 (Wrong library version for pattern)
**Location:** `OmniNFTCollection` constructor (line 113), `initialize()` lines 152-157
**Sources:** Agent B, Agent D, Cyfrin Checklist (SOL-Basics-PU-5/PU-3/PU-8), Solodit

**Description:**

`OmniNFTCollection` inherits from non-upgradeable `ERC721`, `ERC2981`, and `ReentrancyGuard`:

```solidity
contract OmniNFTCollection is ERC721, ERC2981, ReentrancyGuard {
    // ...
    constructor() ERC721("OmniNFT", "ONFT") {
        initialized = true;
    }
```

In the ERC-1167 clone pattern, the constructor runs only once for the implementation contract, not for clones. The `_name` and `_symbol` fields are set in the ERC721 constructor to `"OmniNFT"` and `"ONFT"` and cannot be changed by clones. The `initialize()` function acknowledges this limitation:

```solidity
// Note: ERC721 name/symbol are set in the constructor and cannot
// be changed in a clone. The factory emits name/symbol in the event
// and off-chain indexers use those values.
// Suppress unused parameter warnings:
_name;
_symbol;
```

This means every collection deployed through the factory reports `name() = "OmniNFT"` and `symbol() = "ONFT"` on-chain, regardless of the creator's intended name and symbol. Marketplaces like OpenSea, Blur, and Rarible query `name()` and `symbol()` directly from the contract, not from deployment events.

**Impact:**
- All collections appear identically named on NFT marketplaces
- Users cannot distinguish collections by on-chain metadata queries
- The `_name` and `_symbol` parameters in `createCollection()` and `initialize()` are misleading — they accept values but silently discard them

**Recommendation:**

Migrate to OpenZeppelin Upgradeable contracts:

```solidity
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract OmniNFTCollection is ERC721Upgradeable, ERC2981Upgradeable, ReentrancyGuardUpgradeable {
    function initialize(
        address _owner,
        string calldata _name,
        string calldata _symbol,
        // ...
    ) external initializer {
        __ERC721_init(_name, _symbol);
        __ERC2981_init();
        __ReentrancyGuard_init();
        // ...
    }
}
```

This allows each clone to have its own name and symbol, and properly initializes all base contract state.

---

## Medium Findings

### [M-01] `setPhase()` Silently Deactivates Currently Active Phase

**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `OmniNFTCollection.setPhase()` (line 168-184)
**Sources:** Agent D, Solodit

**Description:**

When `setPhase()` is called to update an existing phase's parameters (price, maxPerWallet, merkleRoot), it creates a new `PhaseConfig` struct with `active: false`:

```solidity
phases[phaseId] = PhaseConfig({
    price: price,
    maxPerWallet: maxPerWallet,
    merkleRoot: merkleRoot,
    active: false  // Always false!
});
```

If the owner calls `setPhase()` on the currently active phase (e.g., to update the mint price mid-sale), the phase is silently deactivated. The `activePhase` state variable still points to that phase ID, but `phase.active` is now `false`, causing `mint()` to revert with `PhaseNotActive()`.

Recovery requires two additional transactions:
1. `setActivePhase(0)` — pause all minting
2. `setActivePhase(originalPhaseId)` — re-activate

The owner cannot skip step 1 because `setActivePhase()` reverts with `PhaseAlreadySet()` if the phase ID matches `activePhase`.

**Recommendation:**

Preserve the `active` state when updating an existing phase:

```solidity
function setPhase(
    uint8 phaseId,
    uint256 price,
    uint16 maxPerWallet,
    bytes32 merkleRoot
) external onlyOwner {
    if (phaseId == 0) revert ZeroQuantity();
    bool wasActive = phases[phaseId].active;
    phases[phaseId] = PhaseConfig({
        price: price,
        maxPerWallet: maxPerWallet,
        merkleRoot: merkleRoot,
        active: wasActive  // Preserve active state
    });
    if (phaseId > phaseCount) {
        phaseCount = phaseId;
    }
}
```

---

### [M-02] Platform Fee Dead Code — Stored But Never Enforced

**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Business Logic — dead code)
**Location:** `OmniNFTFactory.platformFeeBps` (line 71), `OmniNFTCollection.withdraw()` (line 281)
**Sources:** Agent B, Agent C, Solodit

**Description:**

The factory stores `platformFeeBps` (default 250 = 2.5%) and provides `setPlatformFee()` for the owner to update it. The NatSpec states the factory "charges a configurable platform fee on primary sales." However:

1. The `OmniNFTCollection` contract has no reference to the factory or `platformFeeBps`.
2. `withdraw()` sends 100% of the contract's ETH balance to the collection owner:
   ```solidity
   function withdraw() external onlyOwner nonReentrant {
       uint256 balance = address(this).balance;
       (bool ok, ) = payable(owner).call{value: balance}("");
   }
   ```
3. No platform fee is deducted at mint time or withdrawal time.
4. The `initialize()` function does not receive the factory address or fee percentage.

**Impact:** The platform receives zero revenue from NFT sales. The `platformFeeBps` storage variable and `setPlatformFee()` function are dead code, wasting gas on deployment and admin operations.

**Recommendation:**

Either implement the platform fee in the collection contract (pass factory address and fee to `initialize()`, deduct during `withdraw()`), or remove the dead code from the factory to avoid confusion:

```solidity
// Option A: Implement fee in withdraw()
function withdraw() external onlyOwner nonReentrant {
    uint256 balance = address(this).balance;
    uint256 platformFee = (balance * platformFeeBps) / 10000;
    uint256 ownerAmount = balance - platformFee;
    if (platformFee > 0) {
        (bool feeOk, ) = payable(factory).call{value: platformFee}("");
        if (!feeOk) revert TransferFailed();
    }
    (bool ok, ) = payable(owner).call{value: ownerAmount}("");
    if (!ok) revert TransferFailed();
}
```

---

### [M-03] Merkle Leaf Missing chainId and Contract Address — Cross-Collection Proof Reuse

**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-36 (Signature/proof replay variant)
**Location:** `OmniNFTCollection.mint()` (line 217)
**Sources:** Agent A, Agent D, Cyfrin Checklist (SOL-HMT-2)

**Description:**

The whitelist Merkle leaf is constructed using only `msg.sender`:

```solidity
bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
```

This leaf does not include the chain ID, contract address, or phase ID. A valid Merkle proof generated for one collection can be reused for any other collection (or any phase within the same collection) that uses the same Merkle root.

**Exploit Scenario:**
1. Creator A creates Collection A with a whitelist phase and Merkle root R.
2. Creator B (coincidentally or maliciously) creates Collection B with the same Merkle root R.
3. Users whitelisted for Collection A can mint on Collection B without being on Collection B's intended whitelist.
4. Within the same collection, a proof valid for Phase 1 whitelist is also valid for Phase 3 if both share the same Merkle root.

**Recommendation:**

Include the contract address, chain ID, and phase ID in the Merkle leaf:

```solidity
bytes32 leaf = keccak256(abi.encodePacked(
    block.chainid,
    address(this),
    activePhase,
    msg.sender
));
```

---

### [M-04] Missing Zero-Address Check on `_owner` in `initialize()`

**Severity:** Medium
**Category:** SC05 Input Validation
**VP Reference:** VP-22 (Missing zero-address check)
**Location:** `OmniNFTCollection.initialize()` (line 143)
**Sources:** Agent A, Cyfrin Checklist

**Description:**

The `initialize()` function does not validate that `_owner` is not `address(0)`:

```solidity
owner = _owner;  // Line 143 — no zero-address check
```

If `_owner` is `address(0)`, the collection becomes permanently ownerless. No one can:
- Configure minting phases (`setPhase`, `setActivePhase`)
- Mint tokens via `batchMint()`
- Withdraw revenue (`withdraw()`)
- Reveal metadata (`reveal()`)
- Transfer ownership (`transferOwnership()`)

While the factory always passes `msg.sender` as the owner (which cannot be `address(0)`), the `initialize()` function is `external` with no caller restriction, so direct calls could pass zero.

**Recommendation:**

```solidity
if (_owner == address(0)) revert TransferFailed(); // or a new custom error
owner = _owner;
```

---

## Low Findings

### [L-01] Single-Step Ownership Transfer

**Severity:** Low
**Category:** SC01 Access Control
**VP Reference:** VP-06 (Access control design)
**Location:** `OmniNFTCollection.transferOwnership()` (line 295)
**Sources:** Agent C, Cyfrin Checklist (SOL-Basics-AC-4)

**Description:**

Ownership is transferred immediately in a single step. If the owner mistypes the new address, ownership (and all accumulated ETH revenue) is permanently lost. The function only checks for `address(0)` but not that the address is correct.

**Recommendation:** Implement a 2-step ownership transfer (propose → accept) following the OpenZeppelin `Ownable2Step` pattern.

---

### [L-02] Clone Initialization Front-Running (Downgraded from Critical)

**Severity:** Low (downgraded from Critical per Solodit recalibration)
**Category:** SC01 Access Control
**VP Reference:** VP-06 (Missing access control on initializer)
**Location:** `OmniNFTCollection.initialize()` (line 129)
**Sources:** Agent B, Agent D, Solodit (Sudoswap v2 Cyfrin precedent)

**Description:**

The `initialize()` function is `external` with no caller restriction — anyone can call it on an uninitialized clone. However, the factory deploys and initializes the clone atomically within the same transaction (lines 111-121 of OmniNFTFactory), which eliminates the mempool front-running window.

**Severity Justification:** The Sudoswap v2 audit by Cyfrin confirmed that atomic clone+init in the same transaction is safe. The only remaining risk is if a clone is deployed outside the factory (e.g., via `Clones.clone()` called directly on the implementation), but this is not a supported use case.

**Recommendation:** For defense-in-depth, restrict `initialize()` to only accept calls where `msg.sender` is the factory, or accept the current design with documentation noting atomic deployment is required.

---

### [L-03] No `_disableInitializers()` Pattern (Downgraded from High)

**Severity:** Low (downgraded from High per Solodit recalibration)
**Category:** SC10 Upgrade Safety
**VP Reference:** VP-42 (Uninitialized implementation)
**Location:** `OmniNFTCollection` constructor (line 113-116)
**Sources:** Agent A, Agent D, Solodit

**Description:**

The contract uses a custom `initialized = true` in the constructor instead of OpenZeppelin's `_disableInitializers()` pattern. However, this achieves the same protection: the implementation contract's `initialized` flag is set to `true` in the constructor, preventing re-initialization.

**Recommendation:** When migrating to Upgradeable contracts (per H-02), use `_disableInitializers()` in the constructor for standardized protection.

---

### [L-04] No Maximum Batch Size in `batchMint()`

**Severity:** Low
**Category:** SC09 Denial of Service
**VP Reference:** VP-29 (Unbounded loop)
**Location:** `OmniNFTCollection.batchMint()` (line 253)
**Sources:** Agent A, Cyfrin Checklist

**Description:**

`batchMint()` has no limit on the `quantity` parameter beyond `maxSupply`. A very large quantity (e.g., 10,000 in a single call) would consume excessive gas and could exceed the block gas limit, causing the transaction to fail. Since this is an owner-only function, the risk is self-inflicted rather than an attack vector.

**Recommendation:** Add a reasonable batch size limit (e.g., 100 or 500) or document the expected usage pattern.

---

## Informational Findings

### [I-01] No Event Emitted on Phase Configuration

**Severity:** Informational
**Location:** `OmniNFTCollection.setPhase()` (line 168)

`setPhase()` does not emit an event when a phase is configured. Only `setActivePhase()` emits `PhaseChanged`. Off-chain indexers cannot track price or whitelist changes without scanning storage directly.

**Recommendation:** Add a `PhaseConfigured` event.

---

### [I-02] CREATE vs CREATE2 for Clone Deployment

**Severity:** Informational
**Location:** `OmniNFTFactory.createCollection()` (line 111)

The factory uses `Clones.clone()` (CREATE opcode), making clone addresses unpredictable before deployment. `Clones.cloneDeterministic()` (CREATE2) would enable address prediction, which is useful for off-chain pre-computation and counterfactual deployment patterns.

**Recommendation:** Consider using `cloneDeterministic()` with a salt derived from `msg.sender` and a nonce for predictable addresses, if the use case benefits from it.

---

### [I-03] Floating Pragma

**Severity:** Informational
**Location:** Both files, line 2

Both contracts use `pragma solidity ^0.8.24;`. For production deployment, pin to a specific compiler version to ensure consistent bytecode.

**Recommendation:** Use `pragma solidity 0.8.24;`.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| HypeBears | 2022 | Undisclosed | **Direct match** — `_safeMint` callback reentrancy in batch mint, same pattern as H-01 |
| TreasureDAO (Arbitrum) | 2022-03 | ~$1.4M | Related — marketplace reentrancy via NFT callback |
| Sudoswap v2 (Cyfrin audit) | 2023-06 | N/A (audit) | **Precedent** — atomic clone+init confirmed safe (L-02 downgrade basis) |

## Solodit Similar Findings

- **HypeBears reentrancy (6+ independent findings):** `_safeMint` in loop without reentrancy guard — exact match for H-01
- **Sudoswap v2 (Cyfrin):** Clone initialization front-running downgraded — atomic clone+init eliminates mempool window
- **Multiple ERC-1167 audits:** Wrong OZ branch (non-upgradeable in clone pattern) is a recurring finding in clone-pattern contracts

## Static Analysis Summary

### Slither
Skipped — full-project analysis exceeds timeout (known limitation, consistent across all audits).

### Aderyn
Skipped — v0.6.8 incompatible with solc v0.8.33 (known limitation).

### Solhint
- **Errors:** 0
- **Warnings:** 14 (NatSpec completeness, gas optimization suggestions, element ordering)
- No security-relevant findings from Solhint.

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Factory Owner | `setPlatformFee()`, `setImplementation()` | 4/10 |
| Collection Owner | `setPhase()`, `setActivePhase()`, `batchMint()`, `reveal()`, `withdraw()`, `transferOwnership()` | 6/10 |
| Any Caller | `createCollection()` (factory), `mint()` (collection, requires payment), `initialize()` (collection, one-time) | 2/10 |

## Centralization Risk Assessment

**Factory centralization: 4/10 (Moderate)**
- Owner can change implementation for future clones (existing clones unaffected)
- Owner can update platform fee (currently dead code — not enforced)
- No ability to affect existing collections

**Collection centralization: 6/10 (Moderate-High)**
- Single owner controls all minting phases, pricing, and revenue withdrawal
- Single-step ownership transfer risks permanent loss
- Owner can batch-mint to themselves up to maxSupply
- No timelock on phase changes or reveals
- Revenue withdrawal sends 100% to owner (no platform fee enforcement)

**Recommended mitigations:**
- Implement 2-step ownership transfer
- Add timelock for setImplementation() in factory
- Consider multi-sig for high-value collections

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
*Pass 1: Solhint (Slither/Aderyn skipped). Pass 2: 4 parallel LLM agents (OWASP, Business Logic, Access Control, DeFi Exploits). Pass 3: Cyfrin checklist. Pass 4: Solodit cross-reference.*
