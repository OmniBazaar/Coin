# Security Audit Report: OmniAccountFactory.sol (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13 21:00 UTC
**Audited by:** Claude Code Audit Agent (Opus 4.6)
**Contract:** `Coin/contracts/account-abstraction/OmniAccountFactory.sol`
**Solidity Version:** 0.8.25 (pinned)
**Lines of Code:** 229
**Upgradeable:** No (immutable factory pattern)
**Handles Funds:** No -- deploys proxy accounts but holds no value itself
**Dependencies:** OpenZeppelin Contracts 5.x (`Clones`), `OmniAccount`
**Deployed Size:** Minimal (single constructor + 3 external functions)
**Previous Audits:** None (first audit for this contract)
**Tests:** 6 passing in `test/account-abstraction/AccountAbstraction.test.js` (OmniAccountFactory section)

---

## Executive Summary

OmniAccountFactory is a lightweight factory contract that deploys ERC-4337 smart wallet accounts (OmniAccount instances) as ERC-1167 minimal proxies via CREATE2. It provides deterministic, counterfactual address computation so that account addresses can be known before on-chain deployment. The ERC-4337 EntryPoint calls this factory via `UserOperation.initCode` when a user's first operation triggers account creation.

The contract includes:
- **Deterministic CREATE2 deployment** using OpenZeppelin `Clones.cloneDeterministic()`
- **Idempotent account creation** (returns existing account if already deployed, no revert)
- **Rate limiting** (optional cooldown between creations per `msg.sender`, controlled by deployer)
- **Counterfactual address prediction** via `getAddress()`

The contract is small, well-structured, and uses battle-tested OpenZeppelin Clones. **Zero Critical findings and zero High findings were identified.** One Medium finding, two Low findings, and three Informational items are reported below. The overall security posture is strong for a factory of this scope.

---

## Findings Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 2 |
| Informational | 3 |
| **Total** | **6** |

---

## Detailed Findings

### M-01: Rate Limit Bypassed for Idempotent Returns -- Attacker Can Probe Without Cooldown

**Severity:** Medium
**Location:** `createAccount()`, lines 148-174
**Status:** Open

**Description:**

When `createAccount()` is called for an (owner, salt) pair that already has a deployed account, the function returns early at line 160 *before* `_enforceRateLimit()` is called at line 164. This means an attacker can call `createAccount()` repeatedly with already-deployed (owner, salt) pairs without triggering the cooldown. The rate limit only gates genuinely new deployments.

While this design is intentional for ERC-4337 compatibility (the EntryPoint must not revert when replaying an initCode for an already-deployed account), it means the rate limit only prevents rapid creation of *new* accounts. An attacker who knows N valid (owner, salt) pairs can call `createAccount()` N times per block with no cooldown, generating N gas-consuming transactions.

More importantly, the rate limit is applied to `msg.sender`, not the `owner_`. When the EntryPoint is the caller (the standard ERC-4337 path), all account creations route through a single `msg.sender` (the EntryPoint address). This means:
1. The first user to create an account via EntryPoint starts the cooldown for *all* users creating accounts via EntryPoint.
2. If `creationCooldown` is set to e.g. 60 seconds, only one account can be created per minute across the *entire* EntryPoint.

**Recommendation:**

Consider applying the rate limit to the `owner_` address instead of `msg.sender`, so that each owner is limited independently:

```solidity
function _enforceRateLimit(address target) internal {
    if (creationCooldown == 0) return;
    if (
        lastCreated[target] > 0
        && block.timestamp < lastCreated[target] + creationCooldown
    ) {
        revert CreationCooldownNotMet();
    }
    lastCreated[target] = block.timestamp;
}
```

Then call `_enforceRateLimit(owner_)` in `createAccount()`. This correctly rate-limits sybil creation per owner without DoSing unrelated users when the EntryPoint is the caller.

Alternatively, if the EntryPoint is expected to be exempt from rate limiting entirely (since the EntryPoint itself has gas budget constraints), consider adding `if (msg.sender == entryPoint) return;` at the start of `_enforceRateLimit()`.

---

### L-01: `deployer` Is Immutable -- No Ownership Transfer for Rate Limit Admin

**Severity:** Low
**Location:** `deployer` declaration, line 46; `setCreationCooldown()`, lines 120-124
**Status:** Open

**Description:**

The `deployer` address is set to `msg.sender` in the constructor and stored as `immutable`. The only admin function is `setCreationCooldown()`, restricted to the deployer. If the deployer private key is compromised, lost, or the team needs to rotate key management to a multi-sig, there is no mechanism to transfer the deployer role.

Since the only admin capability is toggling rate limiting on or off, the blast radius of a compromised deployer key is limited: an attacker could only disable rate limiting (setting `creationCooldown = 0`) or set an excessively high cooldown to grief new account creation. They cannot steal funds, redirect accounts, or alter deployed account ownership.

**Recommendation:**

For a production deployment controlled by a multi-sig or timelock, consider either:
1. Making `deployer` a mutable state variable with a two-step ownership transfer pattern, or
2. Deploying the factory from the intended multi-sig/timelock address so that `deployer` is permanently correct.

Option (2) is simpler and avoids adding complexity to a minimal contract. If rate limiting is not expected to change post-deployment, this finding is acceptable as-is.

---

### L-02: `accountCount` Only Increases -- Not a Reliable Count of Unique Accounts

**Severity:** Low
**Location:** `accountCount`, line 51; `createAccount()`, line 172
**Status:** Open (acknowledged in NatSpec)

**Description:**

`accountCount` is incremented on every new account deployment but is never decremented. The NatSpec at line 49-51 correctly warns: "Do not use it as a count of active accounts; index AccountCreated events off-chain instead."

However, `accountCount` also does not account for the case where a caller creates accounts with different `salt` values for the *same* owner. Each (owner, salt) pair produces a unique address, so a single owner can have multiple accounts, each incrementing `accountCount`. The counter therefore represents "number of proxy deployments" rather than "number of unique owners."

This is not a vulnerability but is noted for completeness since off-chain consumers may incorrectly interpret `accountCount` as a user count.

**Recommendation:**

The existing NatSpec warning is sufficient. No code change needed.

---

### I-01: Front-Running of `createAccount()` Is Mitigated by Idempotency

**Severity:** Informational
**Location:** `createAccount()`, lines 148-174; NatSpec lines 22-30
**Status:** Acknowledged in NatSpec (M-02 documentation)

**Description:**

An adversary who observes a pending `createAccount(owner, salt)` transaction in the mempool can front-run it by submitting the same call with higher gas. Since `createAccount()` is idempotent, the front-runner's transaction deploys the account and emits `AccountCreated`. The original caller's transaction then hits the early return at line 159, getting the same address without reverting but without emitting the event.

The NatSpec at lines 22-30 thoroughly documents this and correctly notes that the front-runner *cannot* change the owner or redirect funds because:
1. The CREATE2 salt incorporates the owner address via `_computeSalt(owner_, salt)`.
2. The `initialize(owner_)` call sets ownership to the legitimate owner.
3. The front-runner gains nothing -- they pay gas for someone else's deployment.

The only impact is event attribution: off-chain indexers should verify account ownership via `OmniAccount.owner()` rather than trusting the `msg.sender` of the `AccountCreated` event.

**Recommendation:**

No code change needed. The NatSpec documentation is thorough.

---

### I-02: Implementation Contract Is Not Self-Destructible but Could Be Initialized

**Severity:** Informational
**Location:** Constructor, line 108; `OmniAccount` constructor, lines 304-308
**Status:** Not exploitable

**Description:**

The factory constructor at line 108 deploys a fresh `OmniAccount` as the implementation template:

```solidity
accountImplementation = address(new OmniAccount(entryPoint_));
```

The `OmniAccount` constructor calls `_disableInitializers()` (line 307), which permanently prevents the implementation itself from being initialized. This is the correct pattern for ERC-1167 clones -- the implementation contract should never hold state.

Even if an attacker directly called `initialize()` on the implementation contract, it would revert because `_disableInitializers()` has already locked the initializer. This finding confirms the protection is in place.

However, note that the implementation contract's `owner` remains `address(0)` and it can still receive ETH via its `receive()` function. Any ETH sent to the implementation address is permanently locked (no `owner` can call `execute()` to withdraw it).

**Recommendation:**

Consider documenting in deployment procedures that the implementation address should not receive funds. No code change needed -- the `_disableInitializers()` pattern is correctly applied.

---

### I-03: No `creationCooldown` Upper Bound

**Severity:** Informational
**Location:** `setCreationCooldown()`, lines 120-124
**Status:** Open

**Description:**

`setCreationCooldown()` accepts any `uint256` value with no upper bound check. The deployer could set it to `type(uint256).max`, effectively preventing all new account creations permanently (assuming the rate limit applies -- see M-01 for the EntryPoint bypass). While the deployer is a trusted role, a compromised deployer key could grief the system by setting an astronomically large cooldown.

**Recommendation:**

Consider adding a reasonable upper bound (e.g., 1 day):

```solidity
uint256 internal constant MAX_COOLDOWN = 1 days;

function setCreationCooldown(uint256 newCooldown) external {
    if (msg.sender != deployer) revert OnlyDeployer();
    if (newCooldown > MAX_COOLDOWN) revert CooldownTooLarge();
    creationCooldown = newCooldown;
    emit CreationCooldownUpdated(newCooldown);
}
```

This limits the damage from a compromised deployer key. Alternatively, since the deployer can always set the cooldown back to 0, the risk is limited to temporary griefing and may be acceptable without a cap.

---

## Access Control & Role Map

| Role | Address | Privileges | Mutability |
|------|---------|------------|------------|
| `deployer` | `msg.sender` at construction | `setCreationCooldown()` only | Immutable (cannot be changed) |
| Any caller | Anyone | `createAccount()`, `getAddress()` | N/A |
| EntryPoint | Constructor parameter | No special factory privileges (calls `createAccount()` like anyone) | Immutable |

**Trust Assumptions:**
- The `deployer` is trusted to set reasonable rate limits. The deployer has no ability to alter deployed accounts, steal funds, or change the implementation.
- The `entryPoint` address is immutable and must be correct at deployment time. A wrong EntryPoint address means all ERC-4337 UserOperations will fail at the OmniAccount level (not at the factory level).
- Any address can call `createAccount()` and create an account for any `owner_`. This is by design for ERC-4337 compatibility.

---

## CREATE2 Deployment Analysis

### Salt Computation

```solidity
function _computeSalt(address owner_, uint256 salt) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(owner_, salt));
}
```

The salt combines the owner address (20 bytes) and user-provided salt (32 bytes) via `keccak256(abi.encodePacked(...))`. This ensures:

1. **Owner binding:** Different owners with the same `salt` get different addresses.
2. **Uniqueness per owner:** A single owner can create multiple accounts with different salt values.
3. **No collision risk:** `keccak256` over 52 bytes produces a uniformly distributed 32-byte output. The only collision scenario requires a keccak256 preimage collision, which is computationally infeasible.

**Note on `abi.encodePacked` ambiguity:** While `abi.encodePacked` with dynamic types can produce ambiguous encodings, here both `owner_` (address, 20 bytes fixed) and `salt` (uint256, 32 bytes fixed) are fixed-size types. The encoding is unambiguous: the first 20 bytes are the owner, the remaining 32 bytes are the salt. No collision from encoding ambiguity is possible.

### Deterministic Address Computation

The factory uses OpenZeppelin `Clones.predictDeterministicAddress(implementation, salt)` which computes:

```
address = keccak256(0xff ++ factoryAddress ++ salt ++ keccak256(cloneInitCode))[12:]
```

This is the standard CREATE2 formula. The address is determined entirely by:
- The factory contract address
- The combined salt (owner + user salt)
- The clone bytecode (which embeds the implementation address)

Since all three are deterministic, `getAddress()` reliably predicts the deployment address before the account exists on-chain. This enables counterfactual account funding.

### Clone Initialization

After `cloneDeterministic()`, the factory immediately calls `OmniAccount(payable(account)).initialize(owner_)`. The `initialize` function uses OpenZeppelin `Initializable`, which ensures it can only be called once. The sequence is:
1. Clone is deployed (bytecode exists, no state).
2. `initialize(owner_)` sets the owner (consumes the one-time initializer).
3. Any subsequent `initialize()` call reverts.

**Security:** There is no window between deployment and initialization where an attacker could front-run the `initialize()` call because both happen in the same transaction (same `createAccount()` call). The clone deployment and initialization are atomic.

---

## Edge Case Analysis

### Edge Case 1: Same Owner, Different Salts

An owner can have multiple smart accounts by using different `salt` values. Each produces a unique address. This is expected behavior and useful for privacy (separate accounts for different purposes).

### Edge Case 2: Zero Salt

`salt = 0` is valid. `_computeSalt(owner_, 0)` produces `keccak256(abi.encodePacked(owner_, uint256(0)))`. The result is a valid, unique salt.

### Edge Case 3: Deployer Creates Account for Themselves

Nothing prevents the deployer from calling `createAccount(deployer, salt)`. The deployer gains no special privileges over the created account -- it is owned by the deployer as any other owner would be.

### Edge Case 4: Rate Limit at Block Timestamp Boundary

`_enforceRateLimit()` uses `block.timestamp` for cooldown tracking. Since `block.timestamp` can only increase (or stay the same within a block), there is no risk of timestamp manipulation enabling cooldown bypass. Miners can manipulate `block.timestamp` by a few seconds, but this only marginally affects the cooldown window and is not exploitable in practice.

### Edge Case 5: Contract as Owner

`createAccount()` only checks `owner_ != address(0)`. A contract address can be specified as the owner. The deployed OmniAccount would then require the contract owner to sign UserOperations (via ECDSA), which is not possible for most contracts. However, the owner contract could still call `execute()` directly (bypassing the EntryPoint). This is a valid use case for DAO-controlled accounts.

### Edge Case 6: Self-Destruct of Clone

Under EIP-6780 (post-Dencun), `SELFDESTRUCT` only sends funds but does not delete bytecode (unless called in the same transaction as creation). Even pre-Dencun, if an OmniAccount clone were self-destructed (which it cannot be -- there is no `selfdestruct` in the code), calling `createAccount()` again would detect `predicted.code.length > 0` (bytecode still exists post-6780) and return the address without re-deploying.

---

## Reentrancy Analysis

The factory has no reentrancy risk:
- `createAccount()` does not make external calls after state changes. The `Clones.cloneDeterministic()` call is a CREATE2 opcode (not a CALL). The `OmniAccount.initialize()` call is the only external call, and it occurs after `accountCount` is not yet incremented -- but even if it re-entered `createAccount()` with the same parameters, the `predicted.code.length > 0` check would return early. With different parameters, a new account would be created, which is expected behavior.
- No ETH is held or transferred by the factory.
- No callbacks or hooks are invoked.

---

## Gas Considerations

- **Clone deployment cost:** ~45,000 gas (ERC-1167 minimal proxy is 45 bytes).
- **Initialize call:** ~25,000 gas (sets owner in a cold storage slot).
- **Total createAccount:** ~75,000-85,000 gas for new accounts.
- **Idempotent return:** ~5,000 gas (EXTCODESIZE check on warm address).
- **getAddress (view):** No gas (off-chain) or ~2,000 gas (on-chain call).

The contract is gas-efficient. Using ERC-1167 clones instead of full contract deployment saves ~90% of deployment gas.

---

## Solhint Results

```
[solhint] Warning: Rule 'contract-name-camelcase' doesn't exist
[solhint] Warning: Rule 'event-name-camelcase' doesn't exist
```

Zero linting errors or warnings. The two messages are about non-existent rules in the solhint configuration and are not contract issues.

---

## Test Coverage Assessment

The existing test suite (`test/account-abstraction/AccountAbstraction.test.js`) covers:

| Test | Coverage |
|------|----------|
| Deploy with valid entryPoint | Covered |
| Revert on zero-address entryPoint | Covered |
| Create account and emit event | Covered |
| Revert on zero-address owner | Covered |
| Idempotent return for duplicate (owner, salt) | Covered |
| Predict address matches deployed address | Covered |

**Missing test coverage:**

| Scenario | Status |
|----------|--------|
| Rate limiting (setCreationCooldown, CreationCooldownNotMet revert) | **Not tested** |
| OnlyDeployer revert for non-deployer calling setCreationCooldown | **Not tested** |
| Multiple accounts for same owner with different salts | **Not tested** |
| accountCount increments correctly across multiple creates | **Not tested** |
| CreationCooldownUpdated event emission | **Not tested** |
| Rate limit bypass via EntryPoint as msg.sender (M-01) | **Not tested** |

**Recommendation:** Add tests for the rate limiting feature and multi-salt scenarios to improve coverage before mainnet.

---

## Conclusion

OmniAccountFactory is a compact, well-written factory contract that follows established ERC-4337 patterns. The use of OpenZeppelin `Clones` for deterministic proxy deployment is the industry standard approach. The contract correctly handles:

- Zero-address validation on construction and account creation
- Idempotent account creation (no double-deploy, no revert on replay)
- Atomic clone + initialize (no front-run window)
- Deterministic address prediction for counterfactual accounts
- NatSpec documentation of front-running implications

The primary finding (M-01) relates to the rate limiting mechanism being keyed on `msg.sender` rather than the owner being created for, which makes it ineffective when the EntryPoint is the caller. This should be evaluated before enabling rate limiting in production. The remaining findings are low severity or informational.

**Security Posture:** Suitable for mainnet deployment. The M-01 finding should be addressed if rate limiting is expected to be used in production. If rate limiting is disabled (cooldown = 0, which is the default), M-01 has no impact.
