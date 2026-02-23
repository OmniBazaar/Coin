# Security Audit Report: LegacyBalanceClaim

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/LegacyBalanceClaim.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 367
**Upgradeable:** No (standard deployment with Ownable)
**Handles Funds:** Yes (mints XOM tokens for legacy user claims)

## Executive Summary

LegacyBalanceClaim is a non-upgradeable migration contract that allows OmniBazaar legacy users to claim their balances as XOM tokens. The owner populates legacy balances (username hash -> amount), a designated validator verifies and submits claims with ECDSA signature proofs, and the contract mints XOM tokens to the claimant's Ethereum address. After the migration period (~2 years), unclaimed balances can be finalized to a specified recipient.

The audit found **1 Critical vulnerability**: the `validator` address defaults to `address(0)` and `ecrecover` returns `address(0)` on invalid signatures, creating a latent exploit path where `_verifyProof()` passes for ANY malformed signature when the validator is unset. While the `onlyValidator` modifier currently prevents exploitation (nobody can be `msg.sender == address(0)`), this is a fragile single-point defense. Additionally, **3 High-severity issues** were found: missing `chainId` in signature message enables cross-chain replay, raw `ecrecover` without ECDSA `s`-value malleability protection, single validator trust (vs. OmniCore's M-of-N multi-sig), and no timelock on migration finalization. Both agents independently identified the signature verification weaknesses as the top priority.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 1 |
| Low | 3 |
| Informational | 2 |

## Findings

### [C-01] Validator Defaults to address(0) — ecrecover Bypass Path

**Severity:** Critical
**Lines:** 88 (constructor), 325 (_verifyProof), 334-358 (_recoverSigner)
**Agents:** Both

**Description:**

The `validator` state variable is never set in the constructor and defaults to `address(0)`. The `_verifyProof()` function checks `require(signer == validator)` where `signer` comes from `ecrecover`. The `ecrecover` precompile returns `address(0)` for malformed signatures rather than reverting.

This creates a dangerous equivalence: when `validator == address(0)`, any malformed signature that causes `ecrecover` to return `address(0)` will pass the proof verification.

The contract is currently protected by the `onlyValidator` modifier on `claim()`, which requires `msg.sender == validator`. Since no transaction can originate from `address(0)`, the modifier blocks exploitation. However, this is a fragile single-point defense — if the contract were refactored to support meta-transactions, relayed claims, or batch processing via a different code path, the `ecrecover` bypass becomes immediately exploitable.

**Impact:** Latent vulnerability. If `onlyValidator` is ever removed or relaxed, any attacker can claim ALL legacy balances by submitting garbage signatures that cause `ecrecover` to return `address(0)`.

**Recommendation:**
1. Set `validator` in the constructor and require it to be non-zero
2. Add `require(signer != address(0), "Invalid signature")` in `_verifyProof()` as defense-in-depth
3. Replace raw `ecrecover` with OpenZeppelin's `ECDSA.recover()` which reverts on invalid signatures

---

### [H-01] Missing chainId in Signature — Cross-Chain Replay Attack

**Severity:** High
**Lines:** 318
**Agents:** Both

**Description:**

The signed message is constructed as:
```solidity
bytes32 message = keccak256(abi.encodePacked(username, ethAddress, address(this)));
```

This includes `address(this)` but NOT `block.chainid`. Compare to `OmniCore.sol` (line 752-757) which includes both `address(this)` AND `block.chainid`.

If the contract is deployed at the same address on multiple chains (common with deterministic deployment via CREATE2), a valid signature from one chain can be replayed on another. Additionally, `abi.encodePacked` with a dynamic `string` type followed by fixed-size types has theoretical collision risks; `abi.encode` is safer.

**Impact:** Cross-chain signature replay enables claiming legacy balances on a fork or secondary deployment without validator authorization.

**Recommendation:**
```solidity
bytes32 message = keccak256(abi.encode(username, ethAddress, address(this), block.chainid));
```

---

### [H-02] Single Validator Trust vs. OmniCore's Multi-Sig Standard

**Severity:** High
**Lines:** 177, 312-326
**Agent:** Agent B

**Description:**

The contract trusts a SINGLE validator address for both transaction authorization (`onlyValidator`) and signature verification (`_verifyProof`). A single compromised validator key enables fabrication of claims for all unclaimed legacy balances.

Compare to `OmniCore.sol` which implements M-of-N multi-sig: multiple unique validator signatures required, duplicate signer detection, each signer verified against a validator registry, nonce-based replay protection.

With ~4.13 billion XOM reserved for migration, a single-key compromise is catastrophic.

**Impact:** A compromised validator key enables theft of all unclaimed legacy balances.

**Recommendation:** Adopt the same M-of-N multi-sig pattern used in `OmniCore.sol`, or deprecate this contract in favor of `OmniCore.claimLegacyBalance()`.

---

### [H-03] No Timelock on Migration Finalization — Premature Seizure Risk

**Severity:** High
**Lines:** 278-292
**Agent:** Agent B

**Description:**

`finalizeMigration()` can be called by the owner at ANY time. The NatSpec mentions "~2 years" but this is not enforced on-chain. The function mints all unclaimed balances to a specified recipient and permanently blocks future claims.

If the owner key is compromised, the attacker can immediately finalize the migration, minting potentially billions of unclaimed XOM to themselves. Even without compromise, premature finalization locks out legitimate users.

**Impact:** Total loss of all unclaimed legacy balances. With ~4.13B XOM at stake, this is critical.

**Recommendation:** Add an on-chain minimum migration period:
```solidity
uint256 public immutable migrationDeadline;
// Set in constructor: migrationDeadline = block.timestamp + 2 years
// Check in finalizeMigration: require(block.timestamp >= migrationDeadline)
```

---

### [M-01] Unbounded Minting with No Supply Cap

**Severity:** Medium
**Lines:** 198, 288
**Agent:** Agent B

**Description:**

The contract mints XOM via `omniCoin.mint()` with no on-chain supply cap. If `legacyBalances` are populated with inflated values (due to decimal conversion errors or other misconfiguration), the contract will mint excess tokens beyond the intended ~4.13B XOM genesis supply.

Compare to `OmniCore.sol` which uses `safeTransfer()` from a pre-funded balance, providing a natural cap.

**Impact:** Token inflation from misconfiguration. No on-chain protection against minting more than the intended migration supply.

**Recommendation:** Add a `MAX_MIGRATION_SUPPLY` constant:
```solidity
uint256 public constant MAX_MIGRATION_SUPPLY = 4_130_000_000 * 10**18;
require(totalReserved <= MAX_MIGRATION_SUPPLY, "Exceeds migration supply");
```

---

### [L-01] Signature Malleability — Raw ecrecover Without s-Value Check

**Severity:** Low
**Lines:** 334-358
**Agents:** Both

**Description:**

The `_recoverSigner()` function uses raw `ecrecover` without enforcing that `s` falls in the lower half of the secp256k1 curve order (EIP-2). While the double-claim guard prevents actual double-spending, malleable signatures can cause confusion in off-chain systems.

**Recommendation:** Use OpenZeppelin's `ECDSA.recover()` which enforces canonical signatures.

---

### [L-02] No Emergency Pause Mechanism

**Severity:** Low
**Lines:** 177
**Agent:** Agent B

**Description:**

If the validator's key is compromised, the owner can call `setValidator()` to rotate the address. However, there is no `pause()` mechanism to immediately halt all claims. Between compromise detection and the owner's rotation transaction, the attacker can drain unclaimed balances.

**Recommendation:** Add OpenZeppelin `Pausable` to `claim()`.

---

### [L-03] initialize() / addLegacyUsers() Ordering Not Enforced

**Severity:** Low
**Lines:** 103, 145
**Agent:** Agent B

**Description:**

If `addLegacyUsers()` is called before `initialize()`, `reservedCount` becomes non-zero, and `initialize()` will revert permanently. Additionally, `initialize()` uses assignment (`totalReserved = total`) while `addLegacyUsers()` uses accumulation (`totalReserved += total`). The `reservedCount == 0` guard prevents the worst case, but the contract relies on correct deployment ordering.

**Recommendation:** Add an `initialized` boolean flag to enforce proper sequencing.

---

### [I-01] Legacy Balance Not Zeroed After Claim — Missed Gas Refund

**Severity:** Informational
**Agents:** Both

**Description:**

After claim, `legacyBalances[usernameHash]` retains its value. While `claimedBy` prevents double-claims, zeroing the balance would provide a ~4,800 gas refund (SSTORE nonzero-to-zero) and cleaner state.

**Recommendation:** Add `legacyBalances[usernameHash] = 0;` after reading the amount.

---

### [I-02] Indexed String Event Parameter — Hash Not Searchable

**Severity:** Informational
**Agents:** Both

**Description:**

`BalanceClaimed` event has `string indexed username`. Indexed strings store only the keccak256 hash, making direct string filtering impossible without pre-computing hashes.

**Recommendation:** Use `bytes32 indexed usernameHash` alongside an unindexed `string username`.

---

## Static Analysis Results

**Solhint:** 0 errors, 59 warnings
- Gas optimization warnings (require → custom errors, struct packing)
- NatSpec completeness
- Style issues

**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 19 raw findings -> 10 unique)
- Pass 6: Report generation

## Conclusion

LegacyBalanceClaim has **significant security gaps compared to the equivalent functionality in OmniCore.sol**:

1. **ecrecover bypass (C-01)** — currently mitigated by `onlyValidator` but the `_verifyProof()` function is independently unsafe.

2. **Missing chainId (H-01)** — cross-chain signature replay is unprotected.

3. **Single validator trust (H-02)** — vs. OmniCore's M-of-N multi-sig. A single key compromise enables theft of all unclaimed balances.

4. **No finalization timelock (H-03)** — owner can immediately seize all unclaimed XOM.

**Strong recommendation:** Given that `OmniCore.sol` already implements legacy claiming with superior security (multi-sig, nonce, chainId, pre-funded transfers), consider deprecating `LegacyBalanceClaim.sol` entirely and using `OmniCore.claimLegacyBalance()` for production migration.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
