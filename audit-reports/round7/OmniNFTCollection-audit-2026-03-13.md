# Security Audit Report: OmniNFTCollection.sol -- Round 7 (Post-Remediation)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 Manual Security Review)
**Contract:** `Coin/contracts/nft/OmniNFTCollection.sol`
**Solidity Version:** 0.8.24 (pinned)
**OpenZeppelin Version:** ^5.4.0
**Lines of Code:** 601
**Upgradeable:** No (ERC-1167 clone pattern with custom initializer)
**Handles Funds:** Yes (ETH mint revenue, ERC-2981 royalties)
**Previous Audits:** Round 1 (2026-02-20), NFTSuite (2026-02-21), Round 6 (2026-03-10)
**Compiler:** Solc 0.8.24 (clean compilation)
**Solhint:** 1 warning (event/error ordering -- cosmetic)
**Tests:** 32/32 passing

---

## Executive Summary

OmniNFTCollection is an ERC-721 collection contract deployed as ERC-1167 minimal proxy clones via OmniNFTFactory. This Round 7 audit confirms that **all** Critical, High, and Medium findings from all previous audit rounds have been remediated:

- **Round 6 M-01 (single-step ownership):** FIXED -- 2-step `transferOwnership()` + `acceptOwnership()` implemented with `pendingOwner` storage, `NotPendingOwner` error, and `OwnershipTransferStarted` event.
- **Round 6 M-02 (onlyOwner using msg.sender):** FIXED -- `onlyOwner` modifier now uses `_msgSender()` for ERC-2771 meta-transaction compatibility (line 164).

The contract is mature and well-hardened after four audit rounds. No new Critical, High, or Medium severity findings were identified. Three Low and three Informational findings are documented below. The contract is **production ready**.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 3 |
| Informational | 3 |

**Overall Assessment: PRODUCTION READY**

---

## Remediation Verification: All Previous Findings

| Round | ID | Severity | Title | Status | Verification |
|-------|-----|----------|-------|--------|--------------|
| R1 | H-01 | High | batchMint _safeMint reentrancy | RESOLVED | `nonReentrant` modifier on `batchMint()` (line 322), `MAX_BATCH_SIZE = 100` (line 324) |
| R1 | H-02 | High | All clones share hardcoded name/symbol | RESOLVED | `name()` (line 414) and `symbol()` (line 432) override to return `_collectionName`/`_collectionSymbol` |
| R1 | M-01 | Medium | setPhase silently deactivates active phase | RESOLVED | `preserveActive` logic (line 245-246) preserves active state during reconfiguration |
| R1 | M-03 | Medium | Merkle leaf missing chainId/contract | RESOLVED | Leaf: `keccak256(abi.encodePacked(block.chainid, address(this), activePhase, caller))` (lines 512-518) |
| R1 | M-04 | Medium | Zero-address owner in initialize | RESOLVED | `if (_owner == address(0)) revert ZeroAddress()` (line 210) |
| Suite | M-06 | Medium | batchMint unbounded + no reentrancy guard | RESOLVED | `MAX_BATCH_SIZE = 100` + `nonReentrant` |
| R6 | M-01 | Medium | Single-step ownership transfer | **RESOLVED** | 2-step pattern: `transferOwnership()` sets `pendingOwner` (line 375), `acceptOwnership()` completes transfer (lines 384-388). `OwnershipTransferStarted` event emitted (lines 155-158). `NotPendingOwner` error defined (line 150). |
| R6 | M-02 | Medium | onlyOwner uses `msg.sender` not `_msgSender()` | **RESOLVED** | `onlyOwner` modifier now reads `_msgSender()` (line 164), consistent with ERC2771Context throughout the contract. |

---

## Reentrancy Analysis

**Status: ADEQUATELY PROTECTED**

| Function | Guard | External Calls | State Mutations Before Calls | Verdict |
|----------|-------|----------------|------------------------------|---------|
| `mint()` | `nonReentrant` | `_safeMint()` x quantity (onERC721Received callback) | `nextTokenId` incremented per iteration; `mintedPerPhase` updated after loop | SAFE |
| `batchMint()` | `nonReentrant` | `_safeMint()` x quantity (onERC721Received callback) | `nextTokenId` incremented per iteration | SAFE |
| `withdraw()` | `nonReentrant` | `payable(owner).call{value: balance}("")` | Balance read before call, event after | SAFE |
| `setPhase()` | None needed | No external calls | N/A | SAFE |
| `setActivePhase()` | None needed | No external calls | N/A | SAFE |
| `reveal()` | None needed | No external calls | N/A | SAFE |
| `transferOwnership()` | None needed | No external calls | N/A | SAFE |
| `acceptOwnership()` | None needed | No external calls | N/A | SAFE |

**Cross-function reentrancy:** Not possible. `ReentrancyGuard` is contract-wide, preventing re-entry into any `nonReentrant` function while another is executing. The only external callback surface (`_safeMint` -> `onERC721Received`) cannot re-enter `mint()`, `batchMint()`, or `withdraw()`.

**Note on `mint()` state ordering:** `mintedPerPhase` is updated at line 308 *after* the minting loop (lines 304-307). This means during an `onERC721Received` callback mid-loop, the `mintedPerPhase` count has not yet been incremented. However, `nonReentrant` prevents re-entry into `mint()`, so this ordering cannot be exploited. No issue.

---

## Access Control Analysis

### Role Map

| Role | Controlled By | Functions | Trust Level |
|------|---------------|-----------|-------------|
| Owner (collection creator) | `owner` state variable, checked via `onlyOwner` modifier using `_msgSender()` | `setPhase()`, `setActivePhase()`, `batchMint()`, `reveal()`, `withdraw()`, `transferOwnership()` | High privilege |
| Pending Owner | `pendingOwner` state variable | `acceptOwnership()` | One-time privilege |
| Whitelisted Minter | Merkle proof against phase merkleRoot | `mint()` (with valid proof + payment) | Limited |
| Public Minter | Anyone (when public phase active) | `mint()` (with payment) | Minimal |

### Ownership Transfer Security

The 2-step ownership pattern is correctly implemented:

1. Current owner calls `transferOwnership(newOwner)` -- sets `pendingOwner`, emits `OwnershipTransferStarted`
2. `newOwner` calls `acceptOwnership()` -- sets `owner = pendingOwner`, clears `pendingOwner`
3. Zero-address validation on `transferOwnership()` (line 374)
4. Only `pendingOwner` can call `acceptOwnership()` (line 385)

**Verified:** No path exists to bypass the 2-step flow.

### Owner Capabilities (Centralization Risk: 6/10)

The owner **can:**
- Change mint prices and whitelist configs via `setPhase()`
- Pause all minting by setting `activePhase = 0`
- Batch-mint up to `maxSupply` to any address
- Withdraw all accumulated ETH
- Reveal metadata (one-time)
- Transfer ownership (2-step)

The owner **cannot:**
- Modify existing token ownership
- Change royalty config post-initialization
- Increase `maxSupply`
- Re-reveal metadata after initial reveal
- Mint beyond `maxSupply`

This centralization level is standard and appropriate for an NFT collection contract where the creator controls the minting economics.

---

## Minting Security Analysis

### `mint()` (lines 280-311)

**Checks performed (all correct):**
1. `quantity != 0` (line 284)
2. Phase is active (line 285 -> `_validateMintPhase`)
3. Whitelist proof valid if required (line 290 -> `_validateWhitelist`)
4. Per-wallet limit not exceeded (line 291 -> `_validateWalletLimit`)
5. Supply not exceeded: `nextTokenId + quantity > maxSupply` (line 294)
6. Exact payment: `msg.value == phase.price * quantity` (line 300)

**Overflow analysis:**
- `phase.price * quantity`: `price` is `uint256`, `quantity` is `uint256`. Multiplication overflow is checked by Solidity 0.8.24 compiler. If `price` is extremely large (close to `type(uint256).max / maxSupply`), multiplication could revert with panic. This is a non-issue in practice as ETH prices are far below this range.
- `nextTokenId + quantity > maxSupply`: Both are `uint256`. Addition overflow checked by compiler. Since `nextTokenId <= maxSupply` (guaranteed by prior mints) and `quantity <= maxSupply`, no overflow is possible.

### `batchMint()` (lines 319-335)

**Checks performed (all correct):**
1. `quantity != 0` (line 323)
2. `quantity <= MAX_BATCH_SIZE (100)` (line 324)
3. `nextTokenId + quantity <= maxSupply` (line 325)
4. Owner-only access (modifier)
5. Reentrancy guard (modifier)

**Gas analysis:** At `MAX_BATCH_SIZE = 100`, each `_safeMint` costs approximately 60,000-80,000 gas (ERC721 storage + callback). Total: ~6-8M gas for 100 mints. Well within block gas limits.

### Per-wallet Limit Bypass Vectors

- **Multiple wallets:** A user can use multiple addresses to bypass `maxPerWallet`. This is inherent to all per-wallet limits on public blockchains and cannot be solved on-chain.
- **Cross-phase accumulation:** `mintedPerPhase` is tracked per-phase, so a user's count resets across phases. This is by design (each phase has its own limit).
- **`batchMint` does not increment `mintedPerPhase`:** Owner batch mints bypass per-wallet tracking. This is intentional since `batchMint` is owner-only.

---

## ERC-721 Compliance Analysis

| Requirement | Status | Details |
|-------------|--------|---------|
| `balanceOf(address)` | Inherited from OZ ERC721 | Correct |
| `ownerOf(uint256)` | Inherited from OZ ERC721 | Correct |
| `safeTransferFrom(address, address, uint256)` | Inherited from OZ ERC721 | Correct |
| `safeTransferFrom(address, address, uint256, bytes)` | Inherited from OZ ERC721 | Correct |
| `transferFrom(address, address, uint256)` | Inherited from OZ ERC721 | Correct |
| `approve(address, uint256)` | Inherited from OZ ERC721 | Correct |
| `setApprovalForAll(address, bool)` | Inherited from OZ ERC721 | Correct |
| `getApproved(uint256)` | Inherited from OZ ERC721 | Correct |
| `isApprovedForAll(address, address)` | Inherited from OZ ERC721 | Correct |
| `supportsInterface(bytes4)` | Overridden (line 472) | Correctly resolves diamond between ERC721 and ERC2981 |
| `name()` | Overridden (line 414) | Returns per-clone name; falls back to "OmniNFT" |
| `symbol()` | Overridden (line 432) | Returns per-clone symbol; falls back to "ONFT" |
| `tokenURI(uint256)` | Overridden (line 451) | Returns unrevealed URI before reveal, or `baseURI + tokenId + ".json"` after |

**Compliance:** Fully ERC-721 compliant. All required functions are present (inherited or overridden). The `supportsInterface` override correctly handles the diamond between `ERC721` and `ERC2981`.

---

## ERC-2981 Royalty Analysis

- Default royalty set during `initialize()` via `_setDefaultRoyalty()` (line 223)
- Maximum enforced: 2500 bps (25%) -- validated at line 211
- Royalty recipient must be non-zero when `royaltyBps > 0` (line 222)
- No function to update royalty post-initialization (immutable -- by design)
- No per-token royalty override (uses default only)
- ERC-2981 is voluntary; enforcement depends on marketplace implementation

---

## ERC-2771 Meta-Transaction Analysis

The contract correctly implements ERC-2771 via OpenZeppelin's `ERC2771Context`:

1. **Constructor:** `trustedForwarder_` is baked into implementation bytecode and inherited by ERC-1167 clones (line 181)
2. **`_msgSender()` override:** Correctly resolves to `ERC2771Context._msgSender()` (line 567)
3. **`_msgData()` override:** Correctly resolves to `ERC2771Context._msgData()` (line 583)
4. **`_contextSuffixLength()` override:** Returns 20 (sender address suffix) (line 598)
5. **`onlyOwner` modifier:** Uses `_msgSender()` (line 164) -- R6 M-02 fix verified
6. **`mint()` function:** Uses `_msgSender()` for caller resolution (line 287)
7. **`acceptOwnership()`:** Uses `_msgSender()` for pending owner check (line 385)

**All caller-identity checks consistently use `_msgSender()`.** Meta-transactions are fully supported for all functions.

**Trusted forwarder risk:** If the trusted forwarder address is compromised, an attacker can impersonate any address for all `_msgSender()` calls. This is the standard ERC-2771 trust model. The forwarder is immutable (set in constructor), so it cannot be changed after deployment. Care must be taken to deploy with a secure, audited forwarder contract.

---

## Clone Pattern (ERC-1167) Security Analysis

### Initialization Safety

1. Implementation contract: `initialized = true` set in constructor (line 183), preventing initialization of the implementation itself.
2. Clones: `initialized` starts as `false` (Solidity default for `bool`). `initialize()` checks and sets it atomically (lines 206-207).
3. Factory deploys and initializes atomically in `createCollection()` (OmniNFTFactory lines 158-168), preventing front-running.

### Storage Layout Compatibility

The contract uses a flat storage layout (no inheritance from upgradeable contracts). ERC-1167 clones share the implementation's bytecode but have independent storage. No storage collision risk exists because:
- ERC721 storage is in the ERC721 base contract's slots
- ERC2981 storage is in the ERC2981 base contract's slots
- Custom storage variables are declared in OmniNFTCollection directly
- No `delegatecall` to external contracts (ERC-1167 uses `delegatecall` internally but storage is per-clone)

### Implementation Contract Misuse

The implementation contract itself has `initialized = true` from the constructor. It cannot be:
- Initialized again (blocked by `AlreadyInitialized`)
- Used for minting (no phases configured, `activePhase = 0`)
- Used for withdrawal (no ETH balance)

However, someone could call view functions on the implementation, which would return default values. This is harmless.

---

## Merkle Whitelist Security Analysis

**Leaf construction (lines 512-518):**
```solidity
bytes32 leaf = keccak256(
    abi.encodePacked(
        block.chainid,
        address(this),
        activePhase,
        caller
    )
);
```

**Replay protection (M-03 remediation verified):**
- `block.chainid` prevents cross-chain replay
- `address(this)` prevents cross-collection replay (different clones have different addresses)
- `activePhase` prevents cross-phase replay (proof for phase 1 cannot be used in phase 2)

**Second preimage attack:** The leaf uses `abi.encodePacked` with types `(uint256, address, uint8, address)`. The types are all fixed-width (32 + 20 + 1 + 20 = 73 bytes), so no ambiguous encoding is possible. No second preimage risk.

**Empty proof with zero merkleRoot:** When `phase.merkleRoot == bytes32(0)` (public phase), whitelist validation is skipped entirely (line 508). This is correct -- public phases do not require proofs.

---

## Edge Cases and Corner Conditions

### 1. maxSupply = 0

If a collection is initialized with `_maxSupply = 0`, no tokens can ever be minted (both `mint()` and `batchMint()` will revert with `MaxSupplyExceeded` since `0 + quantity > 0`). The factory validates `maxSupply > 0` (OmniNFTFactory line 150), but direct clone initialization outside the factory does not prevent this. Low impact since direct initialization is not a supported use case.

### 2. Phase with price = 0 and maxPerWallet = 0

A phase with `maxPerWallet = 0` has no per-wallet limit (the check at line 544 short-circuits). Combined with `price = 0`, this allows unlimited free minting (up to `maxSupply`). This is intentional behavior for owner-configured free mint phases.

### 3. Royalty with _royaltyBps > 0 and _royaltyRecipient = address(0)

In `initialize()`, line 222 checks `_royaltyBps > 0 && _royaltyRecipient != address(0)` before setting royalties. If `_royaltyBps > 0` but `_royaltyRecipient == address(0)`, royalties are silently not set. The collection will report 0% royalty. This could surprise a creator who passes a valid royaltyBps but forgets the recipient.

### 4. Withdrawal to a contract owner that rejects ETH

If the owner address is a contract that does not accept ETH (no `receive()` or `fallback()`), `withdraw()` will revert with `TransferFailed`. The owner would need to transfer ownership to a non-reverting address first. This is expected behavior.

### 5. acceptOwnership() missing OwnershipTransferred event

When `acceptOwnership()` completes the transfer (line 386-387), no event is emitted confirming the final transfer. Only `OwnershipTransferStarted` is emitted during `transferOwnership()`. Off-chain indexers would need to monitor both `OwnershipTransferStarted` and `acceptOwnership()` transactions to track ownership changes. See L-03 below.

---

## Findings

### [L-01] Royalty Silently Not Set When Recipient Is Zero Address

**Severity:** Low
**Location:** `initialize()` (line 222)

**Description:**

The initialization logic conditionally sets royalties:
```solidity
if (_royaltyBps > 0 && _royaltyRecipient != address(0)) {
    _setDefaultRoyalty(_royaltyRecipient, _royaltyBps);
}
```

If a creator calls `createCollection()` with `royaltyBps = 500` (5%) but `royaltyRecipient = address(0)`, no royalty is configured and no error is thrown. The creator would believe they set a 5% royalty, but `royaltyInfo()` will return 0% for all queries. This is a silent misconfiguration that results in permanent loss of royalty revenue since royalties cannot be set after initialization.

**Recommendation:** Revert if `_royaltyBps > 0 && _royaltyRecipient == address(0)`:
```solidity
if (_royaltyBps > 0) {
    if (_royaltyRecipient == address(0)) revert ZeroAddress();
    _setDefaultRoyalty(_royaltyRecipient, _royaltyBps);
}
```

---

### [L-02] `withdraw()` Sends to `owner` Not `_msgSender()` -- No Alternate Withdrawal Path

**Severity:** Low
**Location:** `withdraw()` (line 358)

**Description:**

The `withdraw()` function sends the full contract balance to `owner`:

```solidity
(bool ok, ) = payable(owner).call{value: balance}("");
```

If the owner is a smart contract that reverts on ETH receipt (e.g., a multisig with an issue, or a contract without `receive()`), all accumulated mint revenue is permanently locked. Unlike the factory (which uses Ownable2Step from OZ), the collection's `withdraw()` has no `withdrawTo(address)` variant that would allow specifying an alternate recipient.

The 2-step ownership transfer mitigates this partially (owner can transfer ownership to a working address before withdrawing), but only if the owner contract can still execute `transferOwnership()`.

**Recommendation:** Consider adding a `withdrawTo(address payable to)` function for owner-only use, or accept as design decision. Current risk is low because most collection owners will be EOAs.

---

### [L-03] Missing Event on Ownership Acceptance

**Severity:** Low
**Location:** `acceptOwnership()` (lines 384-388)

**Description:**

When `acceptOwnership()` completes the 2-step ownership transfer, no event is emitted:

```solidity
function acceptOwnership() external {
    if (_msgSender() != pendingOwner) revert NotPendingOwner();
    owner = pendingOwner;
    pendingOwner = address(0);
    // No event emitted here
}
```

The `OwnershipTransferStarted` event is emitted during `transferOwnership()`, but there is no corresponding `OwnershipTransferred(address previousOwner, address newOwner)` event on acceptance. Off-chain systems (indexers, dashboards, marketplace integrations) cannot easily detect when ownership actually changed without polling `owner()` or scanning storage changes.

OpenZeppelin's `Ownable2Step` emits `OwnershipTransferred` in its `acceptOwnership()`. The custom implementation here omits this.

**Recommendation:** Add an `OwnershipTransferred` event:
```solidity
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

function acceptOwnership() external {
    if (_msgSender() != pendingOwner) revert NotPendingOwner();
    address oldOwner = owner;
    owner = pendingOwner;
    pendingOwner = address(0);
    emit OwnershipTransferred(oldOwner, pendingOwner);
}
```

---

### [I-01] No Event Emitted on Phase Configuration

**Severity:** Informational
**Location:** `setPhase()` (lines 235-256)
**Carried From:** Round 1 I-01, Round 6 I-01

**Description:**

`setPhase()` does not emit an event when a phase is configured or reconfigured. Only `setActivePhase()` emits `PhaseChanged`. Off-chain systems cannot track price, whitelist root, or per-wallet limit changes without scanning storage directly.

**Recommendation:** Add a `PhaseConfigured(uint8 indexed phaseId, uint256 price, uint16 maxPerWallet, bytes32 merkleRoot)` event.

---

### [I-02] `reveal()` Is Irreversible -- No URI Update After Reveal

**Severity:** Informational
**Location:** `reveal()` (lines 342-347)
**Carried From:** Round 6 I-03

**Description:**

Once `reveal()` is called, `revealed = true` permanently. The `_revealedBaseURI` cannot be updated. If the IPFS CID is wrong, the metadata host goes offline, or content needs migration (e.g., IPFS pinning service change), there is no recovery path.

This is a common design choice in NFT collections (immutable metadata = trustless). It is documented here for awareness. If updatable metadata is desired for operational flexibility, a `setBaseURI()` function could be added (owner-only), at the cost of reduced trustlessness for collectors.

---

### [I-03] Solhint Ordering Warning: Event After Custom Error

**Severity:** Informational
**Location:** Line 155

**Description:**

Solhint reports: "Function order is incorrect, event definition can not go after custom error definition (line 150)". The `OwnershipTransferStarted` event (line 155) is placed after the `NotPendingOwner` custom error (line 150). Per Solidity style guide, events should be declared before custom errors.

**Recommendation:** Move the `OwnershipTransferStarted` event declaration to the events section (after line 118), before the custom errors section.

---

## Gas Optimization Notes

The contract is reasonably gas-efficient:

1. **Custom errors** used throughout (cheaper than `require(string)`).
2. **`++i` pre-increment** in mint loops (lines 304, 330) -- saves ~5 gas per iteration vs `i++`.
3. **`calldata` parameters** for string arguments in `initialize()` and `reveal()`.
4. **Storage reads minimized:** `phases[activePhase]` loaded once into `phase` storage pointer in `mint()`.
5. **Potential improvement:** `nextTokenId` could use `uint64` or `uint128` to save a storage slot through struct packing with other state variables, but this would require a storage layout redesign. Not recommended for a deployed contract.

---

## Test Coverage Assessment

**32 tests passing** covering:

| Category | Tests | Coverage |
|----------|-------|----------|
| Initialization | 3 | Complete: valid params, double-init, royalty cap |
| Phase Configuration | 4 | Good: set, reject 0, activate/deactivate, access control |
| Public Minting | 6 | Thorough: single, multiple, wallet limit, max supply, inactive phase, zero qty |
| Paid Minting | 3 | Good: correct payment, incorrect payment, balance accumulation |
| Whitelist Minting | 2 | Basic: valid proof, invalid proof |
| Batch Mint | 3 | Good: success, access control, max supply |
| Reveal | 4 | Complete: pre-reveal URI, post-reveal URI, double reveal, access control |
| Royalties | 3 | Good: royalty info, ERC-2981 interface, ERC-721 interface |
| Withdrawal | 2 | Basic: success, access control |
| Ownership Transfer | 2 | Good: 2-step flow, zero address rejection |

**Missing test coverage (recommendations for hardening):**
- Batch size exceeding `MAX_BATCH_SIZE` (100) -- should test `BatchSizeExceeded` revert
- Withdrawal with zero balance (should test `TransferFailed` revert)
- `acceptOwnership()` from non-pending-owner (should test `NotPendingOwner` revert)
- `setActivePhase()` with same phase (should test `PhaseAlreadySet` revert)
- `remainingSupply()` view function
- Cross-phase minting (mint in phase 1, then phase 2 -- verify separate limits)
- `name()` and `symbol()` return per-clone values (not "OmniNFT"/"ONFT")
- `tokenURI()` for non-existent token (should revert with ERC721NonexistentToken)

---

## Conclusion

OmniNFTCollection has been through four audit rounds and has matured into a well-hardened contract. All previous Critical, High, and Medium findings have been resolved. The Round 6 remediations (2-step ownership transfer and `_msgSender()` in `onlyOwner`) are correctly implemented.

The three Low findings are minor:
- **L-01 (silent royalty skip):** Edge case in initialization that could confuse creators
- **L-02 (no withdrawTo):** ETH could be locked if owner contract rejects transfers
- **L-03 (missing OwnershipTransferred event):** Off-chain tracking gap for ownership changes

None of these represent security vulnerabilities that could lead to loss of user funds or unauthorized access. The contract is **production ready** for mainnet deployment.

**Scope note:** This audit covers `OmniNFTCollection.sol` only. The factory contract (`OmniNFTFactory.sol`) and interaction between them have separate audit reports. The trusted forwarder contract (ERC-2771) is out of scope and must be independently audited.

---

*Generated by Claude Code Audit Agent -- Round 7 Post-Remediation Audit*
