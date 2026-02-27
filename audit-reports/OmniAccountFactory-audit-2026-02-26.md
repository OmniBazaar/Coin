# Security Audit Report: OmniAccountFactory

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/account-abstraction/OmniAccountFactory.sol`
**Solidity Version:** 0.8.25
**OpenZeppelin Version:** 5.4.0 (Clones library, Initializable via OmniAccount)
**Lines of Code:** 134
**Upgradeable:** No (immutable factory, deploys ERC-1167 clones)
**Handles Funds:** Indirectly (creates smart wallet accounts that hold user funds)
**Priority:** MEDIUM
**Previous Audit:** Suite-level audit 2026-02-21 (AccountAbstraction-audit-2026-02-21.md). This is the first standalone audit of OmniAccountFactory.
**Deployed Address:** `0xB4DA36E4346b702C0705b03883E8b87D3D061379` (OmniCoin L1, chain 131313)

## Executive Summary

OmniAccountFactory is a minimal factory contract that deploys ERC-4337 smart wallet accounts (OmniAccount) as ERC-1167 minimal proxy clones using CREATE2 for deterministic addressing. The factory is used by the ERC-4337 EntryPoint to deploy accounts on-the-fly via `UserOperation.initCode`, and by the Validator's SmartWalletService for explicit account creation.

The contract is well-designed and follows established patterns from the ERC-4337 ecosystem (comparable to eth-infinitism's SimpleAccountFactory). It uses OpenZeppelin's `Clones` library for gas-efficient proxy deployment, combines owner and salt into a single CREATE2 salt for deterministic addressing, and provides idempotent account creation (returns existing accounts without reverting).

**No critical or high vulnerabilities were found.** The contract's minimal surface area -- 134 lines, no access control, no fund custody, no upgradeable state -- limits the attack surface. The primary findings relate to the unrestricted `createAccount` function (which enables sybil account creation when combined with the OmniPaymaster's free operation budget), missing front-running protection, and NatSpec documentation gaps.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 4 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 38 |
| Passed | 33 |
| Failed | 1 |
| Partial | 4 |
| **Compliance Score** | **86.8%** |

**Top Failed/Partial Checks:**
1. SOL-AccessControl-1 (Failed): `createAccount` has no access control -- anyone can create unlimited accounts (M-01)
2. SOL-FrontRunning-1 (Partial): Deterministic addresses are front-runnable (M-02)
3. SOL-Events-1 (Partial): `accountCount` lacks corresponding getter for enumeration
4. SOL-Testing-1 (Partial): Missing edge case tests (salt collision, implementation address verification)
5. SOL-Gas-1 (Partial): Minor gas optimization available in `_computeSalt` (L-03)

---

## Medium Findings

### [M-01] Unrestricted Account Creation Enables Sybil Attacks on Paymaster Budget

**Severity:** Medium
**Lines:** 80-100 (createAccount)
**Category:** Access Control / Economic Security

**Description:**

`createAccount` is callable by anyone with any `owner_` and `salt` combination. There is no rate limiting, no registration check, and no fee. While this is standard ERC-4337 factory behavior (the EntryPoint must be able to call it via `initCode`), it creates a direct sybil attack vector when combined with the OmniPaymaster.

The OmniPaymaster grants `freeOpsLimit` (default: 10) free gas-sponsored operations per account. Since `createAccount` costs only the gas to deploy a minimal proxy (~55,000 gas on OmniCoin L1 where gas is effectively free for validators), an attacker can:

1. Generate a fresh EOA address
2. Call `factory.createAccount(freshEOA, 0)` to create a smart wallet
3. The new wallet gets 10 free sponsored operations via the Paymaster
4. Repeat with different EOA addresses

On OmniCoin L1 where validators absorb gas costs, step 2 is free. The OmniPaymaster's `dailySponsorshipBudget` (default: 1000 ops/day) provides some protection, but a sophisticated attacker can exhaust this budget, denying service to legitimate new users.

**Cross-Contract Context:**

The OmniPaymaster has been updated since the 2026-02-21 suite audit to include:
- `dailySponsorshipBudget` with daily reset (sybil protection for free/subsidized modes)
- Allowance checks for XOM payment mode

These mitigate the most severe impact (unbounded paymaster drain), but the factory itself provides no defense-in-depth.

**Impact:** The factory enables unlimited account creation at zero cost, which amplifies any economic incentive tied to per-account allocations (free ops, welcome bonuses, airdrops). While the OmniPaymaster has its own daily budget cap, the factory contributes to a broader sybil surface.

**Recommendation:**

Option A (Minimal, non-breaking): Add an optional rate limiter that the deployer can enable:

```solidity
uint256 public creationCooldown; // seconds between creates per msg.sender
mapping(address => uint256) public lastCreated;

function createAccount(address owner_, uint256 salt) external returns (address account) {
    if (owner_ == address(0)) revert InvalidAddress();
    if (creationCooldown > 0 && block.timestamp < lastCreated[msg.sender] + creationCooldown) {
        revert CreationCooldownNotMet();
    }
    lastCreated[msg.sender] = block.timestamp;
    // ... rest of function
}
```

Option B (Integration-level): Tie factory account creation to OmniRegistration status. Only registered users (who pass sybil checks) can have accounts created. This requires the EntryPoint's `initCode` to route through a wrapper that checks registration.

Option C (Accept the risk): Document this as an accepted design decision, since the OmniPaymaster's daily budget cap provides the primary sybil defense. The factory is intentionally permissionless to comply with ERC-4337's account deployment model.

**Note:** Option C is reasonable for OmniCoin L1 where gas is free and the Paymaster is the only economic incentive. If additional per-account incentives are added in the future, revisit this decision.

---

### [M-02] Front-Running of Counterfactual Addresses

**Severity:** Medium
**Lines:** 80-100 (createAccount), 110-116 (getAddress)
**Category:** Front-Running / Griefing

**Description:**

A user can call `getAddress(owner, salt)` to compute their future smart wallet address, then fund it with tokens or ETH before deployment. This is the standard ERC-4337 counterfactual pattern and is by design.

However, an adversary who observes a `createAccount(owner, salt)` transaction in the mempool can front-run it by calling `createAccount(owner, salt)` first. Since the function is idempotent (returns existing address if code exists), the original caller's transaction succeeds silently -- but the front-runner's transaction is the one that actually triggers the `AccountCreated` event and increments `accountCount`.

On its own, this is a minor griefing issue. However, the implications are more significant when combined with the initialization step:

1. The factory calls `OmniAccount(payable(account)).initialize(owner_)` on line 96
2. If the front-runner's transaction creates and initializes the account, the original caller's transaction hits the `predicted.code.length > 0` check and returns early (line 90-92)
3. The account is correctly initialized in both cases (same `owner_`)

The real risk is if a different contract at the predicted address were deployed via a separate CREATE2 mechanism. However, since `Clones.cloneDeterministic` uses the factory's address as the deployer, only this factory can deploy to the predicted address. This limits the front-running impact to event/counter griefing.

**Impact:** Low practical impact due to idempotent design and correct initialization. The front-runner cannot change the owner or redirect funds. The griefing is limited to event attribution and `accountCount` ordering.

**Recommendation:**

This is classified as Medium because counterfactual address front-running is a known ERC-4337 concern that users and integrators should be aware of. The current design handles it correctly (idempotent return, same initialization), but consider:

1. Document the front-running behavior explicitly in NatSpec
2. Off-chain infrastructure (SmartWalletService) should not rely on the `AccountCreated` event for attribution -- instead, verify the account's `owner()` directly

No code change required unless the protocol adds factory-level incentives for account creation.

---

## Low Findings

### [L-01] `accountCount` Can Become Inaccurate If Implementation Is Destroyed

**Severity:** Low
**Lines:** 30 (accountCount), 90 (code.length check), 98 (++accountCount)

**Description:**

The idempotent behavior relies on `predicted.code.length > 0` to detect existing accounts. If the OmniAccount implementation were to contain a `selfdestruct` operation (it does not), a previously created clone could be destroyed, causing `predicted.code.length` to return 0 on the next call. The factory would then attempt to re-deploy and re-initialize at the same address, incrementing `accountCount` again.

In Solidity 0.8.25, `selfdestruct` is deprecated but still functional on most EVM chains (pre-EIP-6780 semantics vary by chain). OmniAccount does not contain `selfdestruct`, so this is theoretical.

However, OmniAccount's `execute()` function allows arbitrary external calls, including `delegatecall` if the EntryPoint routes such an operation. A malicious owner could theoretically craft a `delegatecall` to a contract containing `selfdestruct`, which would destroy the proxy.

**Impact:** Theoretical only. OmniAccount does not use `delegatecall`, and `execute()` uses `.call{}` (not `.delegatecall{}`). On OmniCoin L1 (Subnet-EVM post-Cancun), `selfdestruct` semantics may differ from mainnet Ethereum.

**Recommendation:**

No code change needed. Document that `accountCount` is a monotonically increasing counter and should not be used as a precise count of active accounts. For accurate enumeration, index `AccountCreated` events off-chain.

---

### [L-02] Implementation Contract Not Protected Against Direct Initialization

**Severity:** Low
**Lines:** 63 (constructor deploys implementation)

**Description:**

The factory's constructor deploys a new `OmniAccount(entryPoint_)` as the implementation template. The OmniAccount constructor correctly calls `_disableInitializers()` (line 292 of OmniAccount.sol), which prevents the implementation contract itself from being initialized.

This is the correct pattern. If `_disableInitializers()` were missing, anyone could call `initialize(attackerAddress)` on the implementation contract, becoming its owner. While this would not affect clones (each clone has independent storage), it could create confusion if the implementation address were used directly by mistake.

**Verification:** `_disableInitializers()` is called. No vulnerability present.

**Impact:** None -- the protection is correctly implemented.

**Recommendation:** No change needed. This finding is documented for completeness to confirm the protection was verified during audit.

---

### [L-03] Minor Gas Optimization in `_computeSalt`

**Severity:** Low
**Lines:** 128-133 (_computeSalt)

**Description:**

`_computeSalt` uses `abi.encodePacked(owner_, salt)` which concatenates a 20-byte address and a 32-byte uint256, producing a 52-byte input to `keccak256`. This is correct and collision-resistant (different types prevent ambiguity).

However, `abi.encode(owner_, salt)` (non-packed) is equally secure, produces a 64-byte input, and is marginally more explicit about slot boundaries. Both approaches are valid and produce different (but equally deterministic) salts.

A micro-optimization would be to use assembly for the hash computation, saving the memory allocation overhead of `abi.encodePacked`:

```solidity
function _computeSalt(address owner_, uint256 salt) internal pure returns (bytes32) {
    assembly {
        mstore(0x00, owner_)
        mstore(0x20, salt)
        mstore(0x00, keccak256(0x0c, 0x34)) // 20 bytes addr + 32 bytes salt = 52 bytes
    }
    return bytes32(0); // assembly overwrites return slot
}
```

**Impact:** Negligible gas savings (~50-100 gas). The current implementation is correct and readable.

**Recommendation:** No change needed. The current implementation favors readability over micro-optimization, which is appropriate for a factory function that is called infrequently.

---

## Informational Findings

### [I-01] Contract Matches Established ERC-4337 Factory Pattern

**Severity:** Informational

**Description:**

OmniAccountFactory follows the same pattern as eth-infinitism's `SimpleAccountFactory` and Alchemy's `LightAccountFactory`:

| Feature | OmniAccountFactory | eth-infinitism SimpleAccountFactory |
|---------|-------------------|--------------------------------------|
| Clone library | OpenZeppelin Clones | OpenZeppelin Clones |
| Deterministic salt | `keccak256(owner, salt)` | `keccak256(owner, salt)` (via Create2) |
| Idempotent creation | Yes (code.length check) | Yes (code.length check) |
| Access control | None (permissionless) | None (permissionless) |
| Event on creation | Yes | Yes |
| Counter | `accountCount` | None |
| Implementation in constructor | Yes | Yes |

The `accountCount` public counter is the only deviation from the minimal pattern. It has no on-chain consumer but is useful for off-chain monitoring.

The pattern is considered battle-tested with billions of dollars of smart wallet value deployed using equivalent factory designs across Ethereum mainnet.

---

### [I-02] NatSpec Documentation Is Thorough

**Severity:** Informational

**Description:**

The contract has comprehensive NatSpec documentation on all public functions, events, errors, and state variables. The `@dev` tags correctly explain the CREATE2 determinism, the idempotent behavior, and the relationship with the EntryPoint's `initCode` mechanism.

One minor gap: the `accountCount` state variable's documentation could note that it is a monotonically increasing counter (never decremented) and that it does not represent the count of currently active accounts (see L-01).

---

### [I-03] Test Coverage Is Adequate

**Severity:** Informational

**Description:**

The existing test suite (`test/account-abstraction/AccountAbstraction.test.js`) has 5 passing tests for OmniAccountFactory covering:
- Deployment with valid entryPoint and implementation creation
- Revert on zero-address entryPoint
- Account creation with event emission
- Revert on zero-address owner
- Idempotent behavior (same owner+salt returns same address, no second event)
- Address prediction via `getAddress` matches actual deployment

**Missing test coverage:**
1. Creating accounts with different salts for the same owner (verify different addresses)
2. Creating accounts for different owners with the same salt (verify different addresses)
3. Verifying the deployed clone's `entryPoint()` matches the factory's `entryPoint`
4. Verifying the deployed clone's `owner()` matches the provided `owner_`
5. Large salt values (type boundaries)
6. `accountCount` accuracy after multiple creates
7. Gas measurement for account creation
8. Integration with EntryPoint's `initCode` deployment flow

These gaps are non-critical since the core happy path and error paths are covered. The deterministic address tests implicitly validate salt computation correctness.

---

### [I-04] Solhint Analysis Clean

**Severity:** Informational

**Description:**

Running `npx solhint contracts/account-abstraction/OmniAccountFactory.sol` produces zero errors and zero warnings. The contract complies with all configured solhint rules including:
- Correct SPDX license identifier
- Pinned pragma (0.8.25, not floating)
- Custom errors instead of require strings
- Proper NatSpec documentation
- Correct import ordering
- Immutable variable naming (suppressed with inline comments where needed)

No static analysis findings.

---

## Architecture Assessment

### Factory Design (Correct)

```text
OmniAccountFactory (deployed once)
  |
  |-- constructor(entryPoint)
  |     └── Deploys OmniAccount implementation template
  |         └── _disableInitializers() prevents direct init
  |
  |-- createAccount(owner, salt)
  |     ├── Compute deterministic salt: keccak256(owner, salt)
  |     ├── Check if clone already exists at predicted address
  |     │     └── If yes: return existing (idempotent)
  |     ├── Deploy ERC-1167 minimal proxy via CREATE2
  |     ├── Call clone.initialize(owner) to set owner
  |     ├── Increment accountCount
  |     └── Emit AccountCreated(account, owner, salt)
  |
  └── getAddress(owner, salt) [view]
        └── Predict deterministic address without deploying
```

### Integration Points (Verified)

1. **EntryPoint** (OmniEntryPoint.sol, line 357-379): The EntryPoint's `_deployAccount()` extracts the factory address from `initCode[:20]` and calls the remaining bytes as factory calldata. The factory's `createAccount(owner, salt)` returns the deployed address, which the EntryPoint verifies matches `op.sender`.

2. **SmartWalletService** (Validator/src/services/wallet/SmartWalletService.ts): Uses the `ACCOUNT_FACTORY_ABI` to call `createAccount` and `getAddress` for off-chain account management. The factory's deployed address is configured in `omnicoin-integration.ts` as `OmniAccountFactory: '0xB4DA36E4346b702C0705b03883E8b87D3D061379'`.

3. **E2E Tests** (Validator/mcp-server/tests/e2e/section15-smart-wallet.test.ts): Verifies bytecode presence and `entryPoint()` return value on-chain.

### Gas Analysis

Account creation gas costs:
- `createAccount` (new account): ~80,000-90,000 gas (CREATE2 clone + initialize + storage writes + event)
- `createAccount` (existing account): ~5,000 gas (EXTCODESIZE check + return)
- `getAddress` (view): ~3,000 gas (pure computation, no state access)

The ERC-1167 minimal proxy pattern saves approximately 90% of deployment gas compared to deploying a full OmniAccount contract each time. Each clone is 45 bytes of runtime bytecode that delegates all calls to the implementation.

---

## Summary of Recommendations

### Should-Fix (Before Production)

1. **[M-01]** Evaluate whether to add rate limiting to `createAccount`. If the OmniPaymaster's daily budget cap is considered sufficient sybil protection, document this decision explicitly. If additional per-account incentives are planned (airdrops, welcome bonuses via smart wallets), add factory-level rate limiting or tie creation to OmniRegistration status.

### Consider (Non-Blocking)

2. **[M-02]** Document the front-running behavior in NatSpec. Ensure SmartWalletService does not rely on `AccountCreated` event for security-critical attribution.

3. **[I-03]** Add edge-case tests: different salts/same owner, same salt/different owners, clone owner/entryPoint verification, and EntryPoint `initCode` integration flow.

### Accept (No Action)

4. **[L-01]** `accountCount` inaccuracy via `selfdestruct` is theoretical. Document as monotonic counter.
5. **[L-02]** Implementation initialization protection verified correct. No action needed.
6. **[L-03]** Gas optimization is negligible for an infrequently called factory function.

---

## Conclusion

OmniAccountFactory is a well-implemented, minimal factory contract that follows established ERC-4337 patterns with no deviation from industry-standard designs. At 134 lines with no access control, no fund custody, and no upgradeable state, the attack surface is inherently small.

The two medium findings relate to the permissionless nature of account creation (sybil amplification of paymaster budgets) and deterministic address front-running. Both are known properties of the ERC-4337 factory pattern and are mitigated by the OmniPaymaster's daily budget cap and the factory's idempotent design, respectively. No fundamental design changes are needed.

The contract's correctness depends on:
1. OpenZeppelin Clones library correctness (battle-tested, v5.4.0)
2. OmniAccount's `_disableInitializers()` call (verified present)
3. OmniAccount's `initialize()` being protected by `initializer` modifier (verified present)
4. The salt computation being collision-resistant for distinct (owner, salt) pairs (verified via `keccak256(abi.encodePacked(...))`)

All four dependencies are correctly satisfied. The contract is suitable for production deployment on OmniCoin mainnet in its current form, with the recommendation to document the sybil risk acceptance decision (M-01) and add minor test coverage improvements (I-03).

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
