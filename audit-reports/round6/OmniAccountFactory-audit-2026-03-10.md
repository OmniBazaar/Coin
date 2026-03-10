# Security Audit Report: OmniAccountFactory.sol (Round 6 -- Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Opus 4.6, 6-Pass Enhanced)
**Contract:** `Coin/contracts/account-abstraction/OmniAccountFactory.sol`
**Solidity Version:** 0.8.25 (pinned)
**Lines of Code:** 284
**Upgradeable:** No (immutable factory)
**Handles Funds:** No (creates smart wallet accounts but does not custody funds)
**Dependencies:** `OmniAccount` (local), `Clones` (OZ 5.x)
**Previous Audits:** Suite audit (2026-02-21), Round 3 (2026-02-26, 0C/0H/2M/3L/4I)

---

## Executive Summary

OmniAccountFactory is a minimal factory contract that deploys ERC-4337 smart wallet accounts (OmniAccount) as ERC-1167 minimal proxy clones using CREATE2 for deterministic addressing. The factory is called by the EntryPoint via `UserOperation.initCode` and by the Validator's SmartWalletService for explicit account creation.

This Round 6 audit reviews the contract after remediation of Round 3 findings. The contract has grown from 134 lines (Round 3) to 284 lines, incorporating the creation cooldown rate limiter (fixing R3 M-01) and enhanced NatSpec documentation (fixing R3 M-02). The contract was also restructured with an `immutable deployer` address for admin functions.

**All prior findings have been addressed.** This audit identifies no new security vulnerabilities. One Low finding and two Informational observations are noted.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 1 |
| Informational | 2 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

No Critical, High, or Medium findings were identified for this contract. Low and Informational findings accepted as-is.

---

## Remediation Status from Prior Audits

| Prior Finding | Severity | Status | Notes |
|---------------|----------|--------|-------|
| R3 M-01: Unrestricted account creation enables sybil attacks | Medium | **Fixed** | Optional `creationCooldown` rate limiter added (lines 57-58, 120-124, 203-215). `deployer` address controls the cooldown setting. When `creationCooldown > 0`, each `msg.sender` must wait the specified seconds between `createAccount` calls. Default: 0 (disabled). |
| R3 M-02: Front-running of counterfactual addresses | Medium | **Fixed (documentation)** | Comprehensive NatSpec added at lines 20-30 documenting: (a) deterministic addresses are publicly computable, (b) the function is idempotent, (c) front-running only affects event attribution not ownership/funds, (d) off-chain systems should verify `owner()` not event attribution. |
| R3 L-01: accountCount inaccuracy via selfdestruct | Low | **Fixed (documentation)** | NatSpec at lines 49-51 documents that `accountCount` is monotonically increasing and should not be used as a count of active accounts. |
| R3 L-02: Implementation contract initialization protection | Low | **Verified** | OmniAccount constructor calls `_disableInitializers()`. Re-verified in this audit. |
| R3 L-03: Minor gas optimization in _computeSalt | Low | **Acknowledged** | Current implementation retained for readability. No change needed. |
| R3 I-01: Contract matches established ERC-4337 factory pattern | Info | **Acknowledged** | Confirmed. |
| R3 I-02: NatSpec documentation thorough | Info | **Enhanced** | Additional documentation on front-running, rate limiting, and accountCount semantics. |
| R3 I-03: Test coverage adequate | Info | **Acknowledged** | Test gaps noted in R3 are non-critical. |
| R3 I-04: Solhint analysis clean | Info | **Re-verified** | Still clean. |

---

## Detailed Code Review

### Constructor (Lines 104-109)

```solidity
constructor(address entryPoint_) {
    if (entryPoint_ == address(0)) revert InvalidAddress();
    entryPoint = entryPoint_;
    deployer = msg.sender;
    accountImplementation = address(new OmniAccount(entryPoint_));
}
```

The constructor:
1. Validates `entryPoint_` non-zero
2. Records the deployer address (for rate limit admin)
3. Deploys the OmniAccount implementation template

The implementation deployment creates a new `OmniAccount(entryPoint_)` which:
- Sets `entryPoint` as immutable
- Calls `_disableInitializers()` preventing initialization of the template

**Assessment:** Sound. The implementation is correctly protected.

### Rate Limiting (New -- Lines 57-58, 120-124, 203-215)

The rate limiting system consists of:

**State:**
```solidity
uint256 public creationCooldown;           // seconds between creates per sender
mapping(address => uint256) public lastCreated;  // last create timestamp per sender
```

**Admin function:**
```solidity
function setCreationCooldown(uint256 newCooldown) external {
    if (msg.sender != deployer) revert OnlyDeployer();
    creationCooldown = newCooldown;
    emit CreationCooldownUpdated(newCooldown);
}
```

**Enforcement:**
```solidity
function _enforceRateLimit() internal {
    if (creationCooldown == 0) return;
    if (
        lastCreated[msg.sender] > 0
        && block.timestamp < lastCreated[msg.sender] + creationCooldown
    ) {
        revert CreationCooldownNotMet();
    }
    lastCreated[msg.sender] = block.timestamp;
}
```

**Assessment of the rate limiter:**

1. **Correctly skips enforcement when disabled** (cooldown == 0, line 205).
2. **Correctly allows first creation** for any sender (lastCreated is 0, so `lastCreated[msg.sender] > 0` is false, line 207).
3. **Correctly enforces cooldown** on subsequent calls (timestamp comparison, lines 208-210).
4. **Records timestamp** after enforcement (line 213).
5. **Only applies to new deployments** -- the rate limit check at line 164 is only reached if the predicted address has no code (line 159 returns early for existing accounts).

**Potential concern:** The rate limit applies to `msg.sender`, not to the `owner_` parameter. This means:
- A single attacker EOA can only create one account per cooldown period.
- But the attacker can use multiple EOAs to bypass the rate limit.
- On OmniCoin L1, the EntryPoint calls `createAccount` as `msg.sender`, so all EntryPoint-deployed accounts share the same rate limit. This would be a problem if the EntryPoint were rate-limited globally.

However, examining the flow: when the EntryPoint deploys an account via `initCode`, `msg.sender` in the factory is the **EntryPoint contract itself** (the EntryPoint calls `factory.call(factoryData)` at OmniEntryPoint line 592). This means ALL EntryPoint-initiated account deployments share a single rate limit, and the cooldown would apply to the EntryPoint address, not individual users.

If `creationCooldown` is set to, say, 60 seconds, then only one account can be deployed via the EntryPoint per minute across ALL users. This would create a severe bottleneck if multiple users try to create accounts simultaneously.

This concern is addressed by the default value of 0 (disabled). The rate limiter is intended as an emergency measure, not a permanent configuration. The NatSpec at lines 17-19 documents this.

**Assessment:** The rate limiter works correctly for its intended use case (emergency sybil mitigation). The msg.sender-based enforcement has the EntryPoint-bottleneck caveat described above, which should be documented.

### createAccount (Lines 148-174)

```solidity
function createAccount(
    address owner_,
    uint256 salt
) external returns (address account) {
    if (owner_ == address(0)) revert InvalidAddress();

    bytes32 combinedSalt = _computeSalt(owner_, salt);
    address predicted = accountImplementation
        .predictDeterministicAddress(combinedSalt);

    // If account already exists, return it (idempotent)
    if (predicted.code.length > 0) {
        return predicted;
    }

    // M-01: Enforce rate limiting if configured
    _enforceRateLimit();

    // Deploy minimal proxy and initialize
    account = accountImplementation.cloneDeterministic(
        combinedSalt
    );
    OmniAccount(payable(account)).initialize(owner_);

    ++accountCount;
    emit AccountCreated(account, owner_, salt);
}
```

**Assessment:**

1. **Zero-address owner check:** Correct (line 152).
2. **Idempotent return:** Correct -- returns existing account without reverting (lines 159-161). Does not re-initialize.
3. **Rate limit enforcement:** Called only for new deployments (after idempotency check).
4. **Clone deployment:** Uses `Clones.cloneDeterministic` with the combined salt. The returned address is deterministic.
5. **Initialization:** Calls `initialize(owner_)` immediately after deployment. The `initializer` modifier in OmniAccount prevents re-initialization.
6. **Counter and event:** `accountCount` incremented and `AccountCreated` emitted.

**Front-running analysis (re-verification):**

If an attacker front-runs `createAccount(alice, 0)`:
1. Attacker's tx creates the account and initializes it with `owner_ = alice` (NOT the attacker)
2. Alice's tx hits `predicted.code.length > 0` and returns the existing address
3. Alice's account has the correct owner

The attacker cannot change the owner because `owner_` is a parameter of `createAccount`, and the salt is derived from `owner_` and `salt`. The attacker must use the same `owner_` to get the same predicted address.

**Could an attacker front-run with a different owner?** No. Using `createAccount(attacker, 0)` produces a different `combinedSalt` (because `_computeSalt` hashes the owner), which produces a different predicted address. The attacker's account is at a completely different address.

**Assessment:** Sound. Front-running is harmless by design.

### getAddress (Lines 185-192)

```solidity
function getAddress(
    address owner_,
    uint256 salt
) external view returns (address predicted) {
    bytes32 combinedSalt = _computeSalt(owner_, salt);
    return accountImplementation
        .predictDeterministicAddress(combinedSalt);
}
```

Uses `Clones.predictDeterministicAddress` which computes the CREATE2 address using `address(this)` as the deployer. This correctly matches the address that `cloneDeterministic` will deploy to.

**Assessment:** Sound.

### _computeSalt (Lines 223-228)

```solidity
function _computeSalt(
    address owner_,
    uint256 salt
) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(owner_, salt));
}
```

`abi.encodePacked(address, uint256)` produces a 52-byte input (20 + 32). Since the types are fixed-length, there is no ambiguity or collision risk. Different `(owner_, salt)` pairs produce different hashes with overwhelming probability.

**Assessment:** Sound.

---

## Low Findings

### [L-01] Rate Limit Applies to msg.sender, Which Is the EntryPoint for initCode Deployments

**Severity:** Low
**Lines:** 164 (`_enforceRateLimit()`), 203-215 (`_enforceRateLimit`)
**Category:** Configuration / Design

**Description:**

As analyzed above, when the EntryPoint deploys an account via `initCode`, the factory's `msg.sender` is the EntryPoint contract address. This means:

1. All EntryPoint-initiated deployments share a single rate limit.
2. If `creationCooldown = 60`, only one account can be deployed via the EntryPoint per minute (globally, not per-user).
3. Direct `createAccount` calls (e.g., from the SmartWalletService) are rate-limited per-caller correctly.

This creates an asymmetry: the rate limiter effectively bottlenecks EntryPoint deployments while correctly rate-limiting direct calls. If the rate limiter is enabled during a period of high account creation activity, legitimate users deploying accounts via UserOp `initCode` would be blocked by the cooldown of the previous user's deployment.

**Impact:** If `creationCooldown > 0`, EntryPoint-initiated account deployments are globally rate-limited to one per cooldown period. This is a severe operational impact if the cooldown is set too high.

**Recommendation:**

1. **Document this behavior** in the NatSpec for `setCreationCooldown`:

```solidity
/// @dev WARNING: When creationCooldown > 0, ALL EntryPoint-initiated
///      deployments share a single rate limit because msg.sender is the
///      EntryPoint address. Set conservatively (e.g., 5 seconds) to avoid
///      blocking legitimate users. A cooldown of 0 (disabled) is recommended
///      for production unless active sybil attack is detected.
```

2. **Consider exempting the EntryPoint** from rate limiting:

```solidity
function _enforceRateLimit() internal {
    if (creationCooldown == 0) return;
    if (msg.sender == entryPoint) return; // EntryPoint is trusted
    // ... existing rate limit logic
}
```

This would allow unlimited EntryPoint deployments while rate-limiting direct callers. The sybil protection then relies entirely on the OmniPaymaster's daily budget and registration checks.

---

## Informational Findings

### [I-01] deployer Is Immutable -- Cannot Transfer Admin Rights

**Severity:** Informational
**Lines:** 46-47

**Description:**

The `deployer` address is set in the constructor and is `immutable`:

```solidity
address public immutable deployer;
```

This means the rate limit admin rights can never be transferred. If the deployer key is compromised or lost:
- Compromised: attacker can set `creationCooldown` to `type(uint256).max`, permanently blocking new account creation
- Lost: the rate limiter can never be adjusted

For a factory contract with no fund custody, this is a low-impact concern. The worst case is deployment of a new factory contract with a new deployer.

**Assessment:** Acceptable for a simple factory. Document the immutability. If admin transferability is desired, consider using OpenZeppelin's `Ownable` instead.

---

### [I-02] AccountAlreadyExists Error Is Declared but Never Used

**Severity:** Informational
**Lines:** 88

**Description:**

The custom error `AccountAlreadyExists` is declared but never used in the contract:

```solidity
error AccountAlreadyExists();
```

The `createAccount` function uses the idempotent pattern (return existing account without reverting), so this error is never thrown. It may have been intended for a version of `createAccount` that reverted on duplicate creation, but the idempotent design was chosen instead.

**Recommendation:** Remove the unused error to keep the contract clean:

```solidity
// Remove: error AccountAlreadyExists();
```

Or document that it is retained for ABI compatibility with off-chain systems that check for it.

---

## Cross-Contract Interaction Analysis

### Factory <-> EntryPoint Integration

**Flow:** The EntryPoint's `_deployAccount` (OmniEntryPoint.sol, line 582-612) extracts the factory address from `initCode[:20]` and calls the remaining bytes as factory calldata with `gas: op.verificationGasLimit`:

```solidity
// OmniEntryPoint._deployAccount
(bool success, bytes memory returnData) = factory.call{
    gas: op.verificationGasLimit
}(factoryData);
```

The factory's `createAccount(owner, salt)` returns the deployed address. The EntryPoint verifies that the returned address matches `op.sender`:

```solidity
if (returnData.length > 31) {
    address deployed = abi.decode(returnData, (address));
    if (deployed != op.sender) {
        revert AccountDeploymentFailed(factory);
    }
}
```

After the factory call, the EntryPoint verifies code exists at `op.sender`:

```solidity
if (op.sender.code.length == 0) {
    revert AccountDeploymentFailed(address(0));
}
```

**Assessment:** The integration is correct. The EntryPoint gas-limits the factory call, verifies the return address, and verifies code existence. The factory returns the correct address from `cloneDeterministic`.

### Factory <-> OmniAccount Initialization

The factory calls `OmniAccount(payable(account)).initialize(owner_)` immediately after deployment. The `initializer` modifier ensures this can only be called once. The OpenZeppelin `Initializable` library tracks the initialization state in the clone's storage, preventing re-initialization.

**Front-running the initialize call:**

Could an attacker front-run the `initialize` call? No, because:
1. `cloneDeterministic` and `initialize` are called in the same transaction (lines 167-170)
2. There is no gap between deployment and initialization
3. Even if the transaction were reverted and the account deployed by a front-runner, the front-runner's `createAccount` call would also initialize with the same `owner_`

**Assessment:** Sound.

### Factory + Paymaster Sybil Attack (Re-Assessment)

**Scenario:** Attacker creates many accounts to exhaust the paymaster's daily budget.

**Mitigations present (post-remediation):**
1. **Factory rate limiter** (M-01 fix): Optional cooldown per `msg.sender`
2. **Paymaster daily budget**: 1000 ops/day (configurable)
3. **Paymaster registration check** (M-01 fix in OmniPaymaster): Only registered users get free ops
4. **Paymaster XOM payment**: Unregistered users must pay in XOM

**Combined defense assessment:**
- Without rate limiter (production default): Attacker can create unlimited accounts, but each needs registration to get free ops. Without registration, accounts must pay XOM.
- With rate limiter: Attacker is limited to one account per cooldown period per EOA. Using multiple EOAs bypasses this.
- With registration requirement: Attacker needs to pass sybil checks (phone verification, device fingerprinting) for each account.

**Assessment:** The combined defense-in-depth across factory, paymaster, and registration provides adequate sybil resistance for OmniCoin L1. The factory's rate limiter is the weakest link (bypassable with multiple EOAs) but is complemented by paymaster-level and registration-level protections.

---

## Summary of Recommendations

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1 | L-01 | Low | Document that EntryPoint deployments share a single rate limit; consider exempting EntryPoint from rate limiting |
| 2 | I-01 | Info | Document that deployer is immutable and cannot transfer admin rights |
| 3 | I-02 | Info | Remove unused `AccountAlreadyExists` error |

---

## Conclusion

OmniAccountFactory has been properly enhanced since the Round 3 audit. Both Medium findings have been addressed:

- **M-01 (sybil attack via unrestricted creation):** Addressed with the optional `creationCooldown` rate limiter. The deployer can enable rate limiting during active attacks and disable it for normal operation.
- **M-02 (front-running):** Addressed with comprehensive NatSpec documentation explaining the idempotent design and its implications.

The contract remains minimal (284 lines), follows the established ERC-4337 factory pattern, and introduces no new attack surface. The rate limiter has a documented caveat (L-01: EntryPoint deployments share a global rate limit) but is correctly disabled by default.

The contract's correctness continues to depend on:
1. OpenZeppelin Clones library correctness (battle-tested, v5.x)
2. OmniAccount's `_disableInitializers()` call (re-verified)
3. OmniAccount's `initialize()` with `initializer` modifier (re-verified)
4. Salt computation collision resistance (re-verified)

All four dependencies are satisfied.

**Overall Risk Assessment: LOW** -- suitable for mainnet deployment on OmniCoin L1. The factory is a simple, well-tested contract with no fund custody and minimal attack surface.

---

*Report generated 2026-03-10*
*Methodology: 6-pass audit (static analysis, OWASP SC Top 10, ERC-4337 spec compliance, prior audit remediation verification, cross-contract interaction analysis, report generation)*
*Contract: OmniAccountFactory.sol at 284 lines, Solidity 0.8.25*
