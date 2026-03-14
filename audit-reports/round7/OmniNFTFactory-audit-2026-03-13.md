# Security Audit Report: OmniNFTFactory.sol (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13 21:01 UTC
**Audited by:** Claude Code Audit Agent (Opus 4.6)
**Contract:** `Coin/contracts/nft/OmniNFTFactory.sol`
**Companion:** `Coin/contracts/nft/OmniNFTCollection.sol` (the cloned implementation)
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 284 (factory), 601 (collection implementation)
**Upgradeable:** No (ERC-1167 minimal proxy clone pattern)
**Handles Funds:** No (factory itself holds no ETH/tokens; cloned collections handle ETH mint revenue)
**OpenZeppelin Version:** ^5.4.0
**Previous Audits:** Round 1 (2026-02-20) -- 2 High, 4 Medium, 4 Low, 3 Informational

---

## Executive Summary

OmniNFTFactory.sol is a factory contract that deploys ERC-1167 minimal proxy clones of OmniNFTCollection. It uses OpenZeppelin's `Clones.clone()` (CREATE opcode) to produce independent, individually-owned NFT collections. The factory maintains a registry of all deployed collections, tracks per-creator collections, and stores a `platformFeeBps` value for off-chain enforcement.

This Round 7 audit is a comprehensive re-review following remediation of all High and Medium findings from the Round 1 audit (2026-02-20). **All six prior High/Medium findings (H-01, H-02, M-01, M-02, M-03, M-04) have been confirmed as remediated in the current codebase.** The contract has reached a mature security posture.

This audit identifies **zero Critical findings, zero High findings, one Medium finding, three Low findings, and four Informational items**.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 3 |
| Informational | 4 |

---

## Prior Findings -- Remediation Status

### [H-01] `batchMint()` Missing `nonReentrant` (Round 1) -- REMEDIATED

The `batchMint()` function in OmniNFTCollection now has the `nonReentrant` modifier (line 322) and a `MAX_BATCH_SIZE = 100` cap (line 324). Both the reentrancy and unbounded-loop issues from H-01 and L-04 are fully resolved.

### [H-02] Wrong OpenZeppelin Branch -- Clones Share Hardcoded Name/Symbol (Round 1) -- REMEDIATED

OmniNFTCollection now stores per-clone `_collectionName` and `_collectionSymbol` in its own storage (lines 74-76), set during `initialize()` (lines 218-219), and overrides `name()` and `symbol()` (lines 414-442) to return these per-clone values. Each collection now reports its own unique name and symbol on-chain. The approach uses storage-level overrides rather than migrating to OZ Upgradeable contracts, which is an acceptable alternative.

### [M-01] `setPhase()` Silently Deactivates Active Phase (Round 1) -- REMEDIATED

The `setPhase()` function now preserves the `active` state when reconfiguring the currently active phase (lines 245-252). The variable `preserveActive` correctly detects and retains the active status.

### [M-02] Platform Fee Dead Code (Round 1) -- REMEDIATED (Design Changed)

The NatSpec has been updated (lines 47-50) to clarify that `platformFeeBps` is "stored on-chain for transparency and enforced off-chain by the platform indexer." The `CollectionCreated` event now includes `feeBps` (line 91) so off-chain systems can capture the fee that was in effect at deployment time. This is a conscious design decision: on-chain fee enforcement would require the collection to hold a factory reference and deduct fees at withdrawal, adding complexity. The off-chain enforcement model is documented and the dead-code concern no longer applies.

### [M-03] Merkle Leaf Missing chainId and Contract Address (Round 1) -- REMEDIATED

The `_validateWhitelist()` function in OmniNFTCollection now includes `block.chainid`, `address(this)`, and `activePhase` in the Merkle leaf (lines 512-518), preventing cross-chain, cross-collection, and cross-phase proof reuse.

### [M-04] Missing Zero-Address Check on `_owner` in `initialize()` (Round 1) -- REMEDIATED

The `initialize()` function now validates `_owner != address(0)` (line 210), reverting with `ZeroAddress()`.

### [L-01] Single-Step Ownership Transfer (Round 1) -- REMEDIATED

OmniNFTCollection now implements 2-step ownership transfer via `transferOwnership()` + `acceptOwnership()` using a `pendingOwner` state variable (lines 371-388). The factory itself uses OpenZeppelin `Ownable2Step` (line 52).

### [L-02] Clone Initialization Front-Running (Round 1) -- ACKNOWLEDGED (Unchanged)

The factory still deploys and initializes clones atomically in the same transaction (lines 158-168). This is confirmed safe per Cyfrin/Sudoswap v2 precedent. No change needed.

### [L-03] No `_disableInitializers()` Pattern (Round 1) -- ACKNOWLEDGED (Unchanged)

OmniNFTCollection uses `initialized = true` in its constructor (line 183), which achieves the same protection. Since the contract was not migrated to OZ Upgradeable (H-02 was fixed via storage overrides instead), this approach remains valid.

### [L-04] No Maximum Batch Size in `batchMint()` (Round 1) -- REMEDIATED

`MAX_BATCH_SIZE = 100` is now enforced (line 324).

### [I-03] Floating Pragma (Round 1) -- REMEDIATED

Both contracts now use `pragma solidity 0.8.24;` (pinned, no caret).

---

## New Findings

### [M-01] Platform Fee Can Be Changed After Collection Deployment -- No Historical Fee Lock

**Severity:** Medium
**Category:** Business Logic / Economic Design
**Location:** `OmniNFTFactory.setPlatformFee()` (line 191), `CollectionCreated` event (line 84)

**Description:**

The `CollectionCreated` event captures the `platformFeeBps` at the time of collection deployment (line 182). However, the factory owner can call `setPlatformFee()` at any time to change the global fee. This creates an ambiguity for off-chain enforcement: should the platform indexer apply the fee recorded in the deployment event, or the current on-chain `platformFeeBps`?

The NatSpec at line 75 says "M-02: Includes platformFeeBps so off-chain indexers can enforce the fee that was in effect at deployment time," suggesting the intent is to lock the fee per-collection at deployment. However, since enforcement is entirely off-chain, there is no on-chain guarantee that the recorded fee will be honored. The factory owner could:

1. Deploy collections at 2.5% fee.
2. Raise `platformFeeBps` to 10%.
3. Instruct the indexer to use the current on-chain value instead of the event value.
4. Creators who deployed at 2.5% are now subjected to 10% without their consent.

Conversely, a malicious indexer operator could ignore the on-chain value entirely and charge whatever they want, since no on-chain mechanism enforces the fee.

**Impact:** Moderate trust assumption. Creators must trust the platform operator to honor the fee recorded in the deployment event. This is a centralization risk inherent to the off-chain enforcement model.

**Recommendation:**

If the intent is to lock the fee per-collection, store the fee in the cloned collection itself during `initialize()`:

```solidity
// In OmniNFTCollection:
uint16 public platformFeeBps;
address public factory;

function initialize(
    // ... existing params ...
    uint16 _platformFeeBps,
    address _factory
) external {
    platformFeeBps = _platformFeeBps;
    factory = _factory;
}
```

This makes the fee queryable on-chain per-collection and immutable once set. Alternatively, if the current design is intentional (platform retains discretion), document this explicitly in the NatSpec.

---

### [L-01] `setImplementation()` Has No Validation That the New Address Is a Contract

**Severity:** Low
**Category:** Input Validation
**Location:** `OmniNFTFactory.setImplementation()` (lines 201-209)

**Description:**

The function checks that `_implementation != address(0)` but does not verify that the address contains contract code. If the owner accidentally sets the implementation to an EOA or a self-destructed contract, all subsequent `Clones.clone()` calls will deploy proxies that delegate to an empty address. Clones deployed from such an implementation will have no executable code behind the delegatecall, causing all function calls to silently succeed with no-op behavior (returning zero bytes), or revert depending on the caller's expectations.

OpenZeppelin's `Clones.clone()` does not validate the implementation address -- it simply copies the ERC-1167 proxy bytecode with the embedded address.

**Impact:** Low. The owner is the only party who can call this function (protected by `onlyOwner`), and the damage is limited to future clones -- existing clones are unaffected since they delegate to their original implementation address. However, collections deployed from a broken implementation would be non-functional and could trap user ETH if the minting phase is somehow activated through direct proxy calls.

**Recommendation:**

Add an `extcodesize` check:

```solidity
function setImplementation(address _implementation) external onlyOwner {
    if (_implementation == address(0)) revert InvalidImplementation();
    if (_implementation.code.length == 0) revert InvalidImplementation();
    implementation = _implementation;
    emit ImplementationUpdated(_implementation);
}
```

---

### [L-02] `collections` Array Grows Unboundedly -- No Pagination for On-Chain Enumeration

**Severity:** Low
**Category:** Denial of Service / Gas
**Location:** `OmniNFTFactory.collections` (line 65), `creatorCollections` (line 69)

**Description:**

The `collections` array and per-creator `creatorCollections` mappings grow with each new deployment. While `MAX_COLLECTIONS = 10000` caps the global array, the public getter `collections(uint256)` provides only single-element access. Any off-chain or on-chain consumer that needs to iterate all collections must make 10,000 individual calls at maximum capacity.

The `creatorCollections` mapping has no per-creator cap -- a single creator could deploy all 10,000 collections, resulting in a 10,000-element array under a single key.

**Impact:** Low. This is primarily a UX/gas concern for off-chain indexers, not a security vulnerability. On-chain contracts that need to enumerate all factory collections would face high gas costs. The `MAX_COLLECTIONS` cap prevents truly unbounded growth.

**Recommendation:**

Consider adding a paginated view function:

```solidity
function getCollections(
    uint256 offset,
    uint256 limit
) external view returns (address[] memory result) {
    uint256 total = collections.length;
    if (offset >= total) return new address[](0);
    uint256 end = offset + limit;
    if (end > total) end = total;
    result = new address[](end - offset);
    for (uint256 i = offset; i < end; ++i) {
        result[i - offset] = collections[i];
    }
}
```

---

### [L-03] No Per-Creator Collection Limit -- Single Address Could Exhaust `MAX_COLLECTIONS`

**Severity:** Low
**Category:** Denial of Service
**Location:** `OmniNFTFactory.createCollection()` (lines 142-184)

**Description:**

Any address can call `createCollection()` without restriction. There is no per-creator limit. A single EOA or contract could deploy all 10,000 collections (the `MAX_COLLECTIONS` cap), exhausting the factory's capacity and preventing legitimate creators from deploying.

Each `createCollection()` call costs roughly ~200,000 gas (clone deployment + initialization + storage writes). At 10,000 calls, the total cost is approximately 2 billion gas, which at typical Avalanche gas prices (25 nAVAX) would cost approximately 50 AVAX (~$1,500 at current prices). This is an economically feasible griefing attack.

**Impact:** Low. The attack permanently exhausts the factory. However, the owner can deploy a new factory with a new implementation, so the impact is operational rather than catastrophic. Existing collections remain functional regardless.

**Recommendation:**

Consider adding a per-creator cap:

```solidity
uint256 public constant MAX_PER_CREATOR = 100;

function createCollection(...) external returns (address clone) {
    if (creatorCollections[caller].length >= MAX_PER_CREATOR) {
        revert TooManyCollections();
    }
    // ...
}
```

Alternatively, require a small creation fee (e.g., 0.1 AVAX) to make griefing economically unattractive.

---

### [I-01] ERC-2771 Trusted Forwarder Is Immutable -- Cannot Be Rotated If Compromised

**Severity:** Informational
**Category:** Architecture
**Location:** Constructor (line 123), `ERC2771Context` inheritance

**Description:**

The `trustedForwarder_` address is set in the constructor via `ERC2771Context(trustedForwarder_)` and is immutable. If the trusted forwarder contract is compromised or needs to be upgraded, the factory cannot update its reference. A compromised forwarder could spoof `_msgSender()` to impersonate any address for `createCollection()`, manipulating the `creator` field in the `CollectionCreated` event and the `creatorCollections` mapping.

The same applies to OmniNFTCollection, where the trusted forwarder is baked into the implementation bytecode and inherited by all clones.

**Impact:** Informational. The forwarder address is typically a well-audited, immutable contract (e.g., OpenZeppelin MinimalForwarder or OmniForwarder). If `address(0)` is passed (as in the test suite), ERC-2771 is effectively disabled and `_msgSender()` returns `msg.sender` directly.

**Recommendation:** Document the trust assumption. If the forwarder is compromised, the factory must be redeployed. Consider using a forwarder registry pattern if forwarder rotation is a requirement.

---

### [I-02] `createCollection()` Does Not Validate `royaltyRecipient` for Zero Address

**Severity:** Informational
**Category:** Input Validation
**Location:** `OmniNFTFactory.createCollection()` (lines 142-184)

**Description:**

The factory passes `royaltyRecipient` directly to `IOmniNFTCollection.initialize()`. The OmniNFTCollection `initialize()` function handles the case where `_royaltyRecipient == address(0)` by simply not setting default royalty (line 222: `if (_royaltyBps > 0 && _royaltyRecipient != address(0))`). This means a creator who specifies a non-zero `royaltyBps` but `address(0)` as the recipient will silently get zero royalties -- the intent is ambiguous.

**Impact:** Informational. The behavior is safe (no funds are lost), but the silent fallback could confuse creators who intended to set royalties.

**Recommendation:** Consider reverting in the factory if `royaltyBps > 0 && royaltyRecipient == address(0)`:

```solidity
if (royaltyBps > 0 && royaltyRecipient == address(0)) {
    revert InvalidRoyaltyConfig();
}
```

---

### [I-03] `MAX_COLLECTIONS` Cap of 10,000 May Be Limiting for a Growing Platform

**Severity:** Informational
**Category:** Architecture / Scalability
**Location:** `OmniNFTFactory.MAX_COLLECTIONS` (line 57)

**Description:**

The factory enforces `MAX_COLLECTIONS = 10000` as a constant. This is a reasonable initial cap, but for a platform aiming at broad marketplace adoption, 10,000 collections may be reached relatively quickly. Since this is a constant (not configurable), the only way to increase capacity is to deploy a new factory.

**Impact:** Informational. Not a security issue, but an operational planning consideration.

**Recommendation:** Consider making this a mutable state variable with an owner-only setter and a reasonable upper bound, or document that the factory is expected to be re-deployed if capacity is exhausted.

---

### [I-04] No Event Emitted on `setPhase()` in OmniNFTCollection

**Severity:** Informational
**Category:** Observability
**Location:** `OmniNFTCollection.setPhase()` (lines 235-256)

**Description:**

This was noted as I-01 in the Round 1 audit and has not been addressed. The `setPhase()` function does not emit an event when a phase is configured or reconfigured. Only `setActivePhase()` emits `PhaseChanged`. Off-chain indexers cannot track price changes, whitelist updates, or per-wallet limit changes without scanning storage directly.

**Recommendation:** Add a `PhaseConfigured(uint8 indexed phaseId, uint256 price, uint16 maxPerWallet, bytes32 merkleRoot)` event.

---

## Access Control Map

| Role | Contract | Functions | Protection |
|------|----------|-----------|------------|
| Factory Owner (Ownable2Step) | OmniNFTFactory | `setPlatformFee()`, `setImplementation()`, `transferOwnership()` | `onlyOwner` modifier from Ownable2Step |
| Factory Pending Owner | OmniNFTFactory | `acceptOwnership()` | OZ Ownable2Step internal check |
| Any Address | OmniNFTFactory | `createCollection()`, all view functions | Unrestricted |
| Collection Owner (custom) | OmniNFTCollection | `setPhase()`, `setActivePhase()`, `batchMint()`, `reveal()`, `withdraw()`, `transferOwnership()` | Custom `onlyOwner` modifier (uses `_msgSender()`) |
| Collection Pending Owner | OmniNFTCollection | `acceptOwnership()` | `_msgSender() == pendingOwner` check |
| Any Address | OmniNFTCollection | `mint()`, `initialize()` (one-time), all view functions | `nonReentrant` on `mint()`, `initialized` flag on `initialize()` |

---

## Centralization Risk Assessment

**Factory Centralization: 3/10 (Low)**
- Owner can change implementation for future clones only; existing clones are unaffected
- Owner can update `platformFeeBps`, but enforcement is off-chain and the event records the fee at deployment time
- Owner uses `Ownable2Step` for safe ownership transfer
- No ability to pause, destroy, or modify existing collections
- No ability to receive or control any funds

**Collection Centralization: 5/10 (Moderate)**
- Single owner controls minting phases, pricing, and revenue withdrawal
- Owner can batch-mint up to `maxSupply` to any address
- 2-step ownership transfer mitigates accidental loss (improved from Round 1)
- No timelock on phase changes or reveals
- `withdraw()` sends 100% of balance to owner (platform fee is off-chain)

---

## Clone Deployment Analysis

**Mechanism:** OpenZeppelin `Clones.clone()` (CREATE opcode)

**Key Properties:**
1. **Atomic deploy + init:** The factory deploys and initializes the clone in the same transaction (lines 158-168). There is no window for front-running the `initialize()` call.
2. **Non-deterministic addresses:** `Clones.clone()` uses CREATE, so clone addresses depend on the factory's nonce and are not predictable before the transaction is mined. This prevents pre-computation attacks but also prevents counterfactual deployment.
3. **Implementation delegation:** All clones delegate to the `implementation` address that was set when they were deployed. Changing the implementation via `setImplementation()` only affects future clones.
4. **Storage isolation:** Each clone has its own storage. The implementation's constructor sets `initialized = true` in the implementation's storage, which does not affect clone storage. Clones start with `initialized = false` and are initialized via `initialize()`.
5. **Immutable code:** Clone bytecode is the standard ERC-1167 pattern (45 bytes) and cannot be changed after deployment.

**Potential Issue:** If the implementation contract is self-destructed (possible via a bug or upgrade mechanism in the implementation), all existing clones will break because their delegatecalls will target an empty address. However, OmniNFTCollection has no `selfdestruct` instruction and Solidity 0.8.24 does not allow implicit self-destruct, so this risk is mitigated.

---

## Fee Handling Analysis

**Factory-Level Fees:**
- `platformFeeBps` defaults to 250 (2.5%) and is capped at `MAX_PLATFORM_FEE_BPS = 1000` (10%)
- The fee is recorded in the `CollectionCreated` event for off-chain enforcement
- The factory itself never holds or transfers any ETH or tokens
- Fee enforcement is entirely off-chain via the platform indexer

**Collection-Level Fees:**
- Mint revenue (ETH) accumulates in the collection contract
- `withdraw()` sends 100% to the collection owner
- No on-chain platform fee deduction occurs
- Royalties are handled via ERC-2981 (informational standard -- marketplace-enforced)

**Consistency with OmniBazaar Fee Model:**
- The OmniBazaar fee model (CLAUDE.md) does not specify NFT platform fees as a distinct category
- The 70/20/10 (ODDAO/Staking/Protocol) split from marketplace fees is not implemented here
- NFT collections are independent entities with their own revenue model
- This is consistent with the design: NFT collections are user-deployed contracts, not protocol-operated marketplaces

---

## Edge Cases and Attack Vectors Reviewed

| Vector | Status | Notes |
|--------|--------|-------|
| Reentrancy on `createCollection()` | Safe | No ETH transfer, no external call except to freshly deployed clone. Clone's `initialize()` does not make external calls. |
| Front-running `initialize()` on clone | Safe | Atomic deploy + init in same transaction. |
| Implementation upgrade affecting existing clones | Safe | `setImplementation()` only affects future clones. Existing clones delegate to their original implementation. |
| Self-destruct of implementation | Safe | OmniNFTCollection has no `selfdestruct`. Solidity 0.8.24 does not expose `selfdestruct` as a free-standing statement (deprecated in EIP-6049). |
| Overflow in `collections.length` | Safe | Capped at `MAX_COLLECTIONS = 10000`, well within `uint256` range. |
| `_msgSender()` spoofing without trusted forwarder | Safe | When `trustedForwarder_ == address(0)`, `isTrustedForwarder()` returns false for all addresses, and `_msgSender()` returns `msg.sender` directly. |
| Double initialization of implementation | Safe | Constructor sets `initialized = true`. |
| Clone with zero `maxSupply` | Safe | Factory rejects `maxSupply == 0` (line 150). |
| Clone with `royaltyBps > MAX_ROYALTY_BPS` | Safe | OmniNFTCollection `initialize()` checks `_royaltyBps > MAX_ROYALTY_BPS` (line 211). |
| Clone with empty name/symbol | Allowed | Not a security issue. The `name()` override returns fallback "OmniNFT" for empty `_collectionName` (line 420). |
| Gas griefing via MAX_COLLECTIONS exhaustion | See L-03 | Economically feasible (~50 AVAX) but recoverable by deploying new factory. |

---

## Solhint Results

```
[solhint] Warning: Rule 'contract-name-camelcase' doesn't exist
[solhint] Warning: Rule 'event-name-camelcase' doesn't exist
```

**Errors:** 0
**Warnings:** 0 (the two messages are about non-existent rules in the solhint config, not about the contract)

The contract passes solhint cleanly with no security or style warnings.

---

## Test Coverage Assessment

The test file `test/nft/OmniNFTFactory.test.js` contains **31 test cases** covering:

- Deployment validation (implementation address, default fee, owner)
- Collection creation (basic, tracking, marking, zero supply rejection)
- Functional clone verification (phase setup, minting, royalties)
- Admin functions (fee update, implementation update, access control)
- Collection limits (MAX_COLLECTIONS, min/max supply)
- Fee validation (boundary values: 0, 1000, 1001, 65535)
- Access control (Ownable2Step flow, unauthorized access)
- Collection registry (index access, creator mapping, false negatives)
- View functions (initial state, increments, post-update)
- Events (all three events, field verification, M-02 fee inclusion)
- Clone independence (separate ownership, implementation update isolation)

**Coverage Gaps:**
- No test for `MAX_COLLECTIONS` exhaustion (deploying 10,000+ collections)
- No test for ERC-2771 meta-transaction flow (trusted forwarder != address(0))
- No test for `setImplementation()` with a non-contract address (L-01)
- No test for concurrent collection creation by many creators

---

## Summary

OmniNFTFactory.sol has been significantly improved since the Round 1 audit. All six High/Medium findings have been remediated. The contract follows a clean, minimal factory pattern with appropriate access control (Ownable2Step), input validation, and event emission.

The remaining findings are predominantly Low severity and Informational:
- **M-01** highlights a trust assumption in the off-chain fee enforcement model that should be documented or mitigated.
- **L-01** through **L-03** address defense-in-depth improvements (implementation validation, pagination, per-creator caps).
- **I-01** through **I-04** are architectural observations and observability improvements.

The contract is suitable for mainnet deployment in its current form, with the understanding that platform fee enforcement relies on off-chain infrastructure and the trust assumptions documented in M-01.

---

*Generated by Claude Code Audit Agent (Opus 4.6) -- Round 7 Pre-Mainnet Final*
*Manual review: reentrancy paths, access control, CREATE deployment, collection management, fee handling, ERC-2771 integration*
*Cross-referenced against Round 1 audit (2026-02-20) for remediation verification*
