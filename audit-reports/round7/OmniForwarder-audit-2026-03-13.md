# Security Audit Report: OmniForwarder (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 -- Pre-Mainnet Final Review)
**Contract:** `Coin/contracts/OmniForwarder.sol`
**Solidity Version:** 0.8.24 (locked)
**Lines of Code:** 43 (wrapper) + ~320 inherited (OpenZeppelin ERC2771Forwarder v5.4.0)
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes -- native tokens can be forwarded via `request.value`; also relays calls to token contracts that move ERC-20 balances
**Prior Audits:** None (first audit for this contract)

---

## Executive Summary

OmniForwarder is a minimal deployment wrapper around OpenZeppelin's `ERC2771Forwarder` (v5.4.0). It provides the ERC-2771 trusted forwarder for gasless meta-transactions across the entire OmniCoin ecosystem. The contract itself adds zero custom logic -- it merely sets the EIP-712 domain name to `"OmniForwarder"` and delegates all behavior to the battle-tested OpenZeppelin base.

Because the contract is the single trust anchor for **all** ERC-2771-enabled contracts in the system (27 contracts identified: OmniCoin, OmniCore, MinimalEscrow, DEXSettlement, OmniSwapRouter, OmniBridge, StakingRewardPool, OmniGovernance, OmniParticipation, OmniRewardManager, OmniRegistration, OmniValidatorRewards, UnifiedFeeVault, OmniArbitration, OmniENS, OmniChatFee, LiquidityMining, LiquidityBootstrappingPool, OmniBonding, PrivateDEX, PrivateDEXSettlement, OmniPrivacyBridge, OmniMarketplace, OmniFeeRouter, RWAAMM, RWARouter, OmniPredictionRouter, and the NFT suite), its correctness and deployment integrity are critical. A compromised or incorrectly deployed forwarder could enable arbitrary impersonation of any user across the entire protocol.

The wrapper contract itself is trivially correct. The audit focus is therefore on: (1) the inherited OpenZeppelin attack surface, (2) system-level integration risks, (3) operational security of the relay service, and (4) edge cases in the ERC-2771 trust model.

**New Findings (Round 7):**

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 5 |

---

## Solhint Analysis

```
$ npx solhint contracts/OmniForwarder.sol

0 errors, 0 warnings
```

Clean pass. No linting issues.

---

## Inheritance Chain

```
OmniForwarder
  -> ERC2771Forwarder (OpenZeppelin v5.4.0)
       -> EIP712
            -> IERC5267
       -> Nonces
```

**OpenZeppelin Version:** `@openzeppelin/contracts ^5.4.0`

The ERC2771Forwarder is the latest OpenZeppelin implementation with known mitigations for:
- EIP-150 gas griefing (via `_checkForwardedGas`)
- Signature malleability (via ECDSA `s`-value normalization)
- Replay attacks (via auto-incrementing per-address nonces)
- Stale request submission (via `uint48 deadline`)
- Untrusted target protection (via `_isTrustedByTarget` staticcall)

---

## Access Control Map

| Role | Functions | Direct Risk | Notes |
|------|-----------|-------------|-------|
| **Anyone** | `execute(ForwardRequestData)` | Low | Requires valid EIP-712 signature from `request.from`; caller pays gas |
| **Anyone** | `executeBatch(ForwardRequestData[], address payable)` | Low | Same signature requirement; batch with optional refund |
| **Anyone** | `verify(ForwardRequestData)` | None | View-only signature verification |
| **Anyone** | `nonces(address)` | None | View-only nonce query |
| **Anyone** | `eip712Domain()` | None | View-only EIP-5267 domain query |

**Key observation:** OmniForwarder has **zero admin functions**. There is no owner, no pauser, no upgradeability, no role-based access control. Once deployed, its behavior is fully immutable and permissionless. This is a strong security property.

---

## ERC-2771 Forwarding Analysis

### Signature Validation

The forwarder uses EIP-712 typed data signatures with the following type:

```
ForwardRequest(
    address from,
    address to,
    uint256 value,
    uint256 gas,
    uint256 nonce,
    uint48 deadline,
    bytes data
)
```

**Domain separator:** `{ name: "OmniForwarder", version: "1", chainId, verifyingContract }`

**Verification flow (`_recoverForwardRequestSigner`):**
1. Nonce is read from on-chain storage (not from the request struct)
2. The full typed data hash is computed including all seven fields
3. ECDSA recovery is performed with OpenZeppelin's malleable-signature-safe implementation
4. The recovered signer must exactly match `request.from`

**Result:** Signature validation is sound. The nonce is read from contract state (not attacker-controlled input), preventing nonce-substitution attacks. The `s`-value is constrained to the lower half of the secp256k1 order, preventing signature malleability.

### Replay Protection

- **Same-chain replay:** Prevented by auto-incrementing per-address nonces. After execution, the nonce is consumed before the external call (checks-effects-interactions pattern at line 3937 of flattened source).
- **Cross-chain replay:** Prevented by the EIP-712 domain separator which includes `chainId` and `verifyingContract`. Deploying the same forwarder on a different chain produces a different domain separator.
- **Cross-forwarder replay:** Prevented by `verifyingContract` in the domain separator.

### Deadline Enforcement

The `uint48 deadline` field is compared against `block.timestamp`. This is safe:
- `uint48` provides timestamps up to year 8,921,556 -- no overflow concern
- `block.timestamp` is the only viable time source in Solidity
- Validators on the OmniCoin L1 produce blocks at ~2s intervals, so timestamp accuracy is sufficient

### Gas Griefing Protection

The `_checkForwardedGas` function (lines 3998-4027 of flattened source) verifies that the subcall received at least the gas requested in `request.gas`. If a malicious relayer supplies insufficient gas to cause the subcall to revert (while the outer call succeeds), the check triggers `invalid()` (consuming all remaining gas), ensuring the relayer cannot profit from starving the subcall.

**Result:** The EIP-150 63/64 gas forwarding rule is correctly accounted for.

### Target Trust Verification

`_isTrustedByTarget` (lines 3966-3984) performs a `staticcall` to `target.isTrustedForwarder(address(this))`. This prevents the forwarder from being used against arbitrary contracts that do not opt in.

**Result:** This is correct. All 27 ERC-2771-enabled contracts in the OmniCoin system set the forwarder address in their constructors (immutable for non-upgradeable, constructor-arg for upgradeable), and their `isTrustedForwarder` returns true only for the matching address.

---

## Reentrancy Analysis

The `_execute` function follows checks-effects-interactions:
1. **Check:** Validate signature, deadline, target trust
2. **Effect:** Consume nonce via `_useNonce(signer)` (line 3937)
3. **Interaction:** External `call` to target (line 3947)

The nonce is consumed before the external call, so even if the target contract re-enters the forwarder with the same request, the nonce will have already been incremented and the signature will not validate.

**Result:** No reentrancy vulnerability.

---

## Findings

### M-01: Permissionless Relay Enables Grief-by-Execution

**Severity:** Medium
**Category:** System Design / Operational
**Location:** Inherited `execute()` / `executeBatch()` -- no caller restriction

**Description:**
The forwarder is fully permissionless -- anyone can call `execute()` with a valid signed request. While this is by design for ERC-2771, it creates an operational concern: if a user signs a request and sends it to the validator relay service, a frontrunner (or any observer of the mempool) can extract the signed request and submit it themselves. The request still executes correctly (the user's action happens), but:

1. The intended validator does not get credit for relaying
2. An attacker could extract signed requests from the validator's pending transaction queue and execute them, wasting the validator's gas while also executing the same request
3. In batch mode, an attacker could selectively execute individual requests from a batch, breaking atomicity assumptions

**Impact:** Low financial impact (the user's intended action still occurs), but medium operational impact for the validator relay service. Could cause double gas expenditure if both the attacker and the validator submit the same request.

**Recommendation:**
The off-chain validator relay service should:
1. Use private mempools or Flashbots-style transaction submission (if available on the OmniCoin L1)
2. Implement request queuing with short TTLs to minimize the frontrunning window
3. Monitor for third-party execution of signed requests and avoid re-submitting consumed nonces

No on-chain fix is required or recommended. Adding a `msg.sender` restriction would break the permissionless relay model.

---

### M-02: No On-Chain Target Whitelist -- Relayer Can Be Tricked Into Arbitrary Calls

**Severity:** Medium
**Category:** Operational Security
**Location:** Inherited `_isTrustedByTarget()` check is necessary but not sufficient

**Description:**
The forwarder will relay calls to **any** contract that returns `true` for `isTrustedForwarder(forwarder)`. If a malicious contract is deployed that trusts the OmniForwarder, and a user signs a request targeting that malicious contract, the forwarder will happily relay the call.

More critically for the validator relay service: a user could craft a signed request targeting a contract with an expensive or state-destructing function (e.g., a contract that performs unbounded loops). The forwarder will execute the call, and the relaying validator pays the gas.

The OpenZeppelin documentation explicitly warns: *"Consider whitelisting target contracts and function selectors."*

**Impact:** A malicious user could cause validators to waste gas on expensive calls to arbitrary contracts. The user pays nothing. This is an economic griefing vector against the relay service.

**Recommendation:**
Implement an off-chain whitelist in the validator relay service that:
1. Only relays requests targeting the known 27+ OmniCoin contracts
2. Optionally restricts function selectors (e.g., block `selfdestruct`-triggering selectors)
3. Rejects requests with excessive `gas` values
4. Rate-limits requests per user address

This is an off-chain concern. The NatSpec documentation on OmniForwarder (line 33) correctly states: *"Contract whitelisting is enforced off-chain by the validator relay service."* This is the right design -- but the relay service must actually implement it.

---

### L-01: Batch Refund Receiver Can Be Arbitrary Address

**Severity:** Low
**Category:** Edge Case
**Location:** Inherited `executeBatch()` -- `refundReceiver` parameter

**Description:**
When `executeBatch()` is called with `refundReceiver != address(0)`, any `msg.value` associated with skipped (invalid) requests is refunded to the specified address. The refund uses `Address.sendValue()`, which performs a low-level `call` with empty calldata.

If the `refundReceiver` is a contract that:
- Reverts on receiving ETH (no `receive` function), the entire batch reverts
- Has a fallback that consumes excessive gas, the relayer pays extra gas

**Impact:** Low. In the OmniCoin architecture, `msg.value` is expected to be 0 for all meta-transactions (users never need native tokens). This vector only applies if `request.value > 0` for some request in a batch.

**Recommendation:**
The validator relay service should:
1. Set `refundReceiver` to its own address (the validator's EOA) when using batches
2. Never relay requests with `request.value > 0` unless explicitly required by a supported flow

---

### L-02: No Emergency Pause or Kill Switch

**Severity:** Low
**Category:** Operational Risk
**Location:** OmniForwarder.sol (entire contract)

**Description:**
OmniForwarder has no `pause()` function, no admin, and no upgradeability. If a critical vulnerability is discovered in the OpenZeppelin ERC2771Forwarder base (or in the ERC-2771 pattern itself), there is no way to stop the forwarder on-chain.

**Impact:** Low probability (OpenZeppelin code is extensively audited), but high impact if triggered. An exploit in the forwarder could allow arbitrary impersonation across all 27 trusted contracts.

**Mitigations already in place:**
1. Each downstream contract has its own `pause()` function, so admin can pause individual contracts even if the forwarder remains active
2. The forwarder's trust is unidirectional -- downstream contracts trust the forwarder, but the forwarder does not hold state or funds (except temporarily during `msg.value` forwarding)

**Recommendation:**
Document an emergency response plan:
1. If the forwarder is compromised, immediately pause all 27 downstream contracts via their admin/pauser roles
2. Deploy a new forwarder and redeploy/reinitialize downstream contracts with the new forwarder address
3. For upgradeable contracts (OmniCore, UnifiedFeeVault, OmniGovernance, etc.), this can be done via proxy upgrade
4. For non-upgradeable contracts (OmniCoin, MinimalEscrow, DEXSettlement, etc.), the `trustedForwarder` is immutable -- these would need redeployment

---

### L-03: Nonce Gap Prevents Out-of-Order Execution

**Severity:** Low
**Category:** Usability / Design
**Location:** Inherited `Nonces` contract -- strictly sequential nonces

**Description:**
OpenZeppelin's `Nonces` contract uses a single auto-incrementing counter per address. If a user signs requests with nonces 0, 1, 2, and request 1 fails or is never submitted, request 2 becomes permanently unexecutable (the nonce in the signature won't match the on-chain nonce).

This is a known limitation of sequential nonces vs. bitmap nonces (like EIP-2612 permits) or nonce channels.

**Impact:** Low. The validator relay service is the only entity submitting transactions, so it controls ordering. The batch mechanism (`executeBatch`) handles sequential nonces correctly by processing requests in order. The test suite (`gasless-relay.test.js`) demonstrates correct nonce management in batches (lines 277-296).

**Recommendation:**
No on-chain change needed. The validator relay service should:
1. Always submit requests in nonce order
2. If a request fails, do not attempt later-nonce requests for the same user until the nonce gap is resolved
3. Consider implementing nonce pre-check before accepting signed requests from users

---

### I-01: EIP-712 Domain Name Hardcoded in Constructor

**Severity:** Informational
**Category:** Deployment
**Location:** OmniForwarder.sol line 42

**Description:**
The domain name `"OmniForwarder"` is hardcoded in the constructor call to `ERC2771Forwarder("OmniForwarder")`. The EIP-712 domain separator is computed at deployment time and cached as an immutable value. If the contract is deployed on the wrong chain or the name needs to change, a full redeployment is required.

**Status:** By design. The immutability is a security feature -- it prevents domain separator manipulation.

---

### I-02: Test Suite Coverage Is Strong but Missing Edge Cases

**Severity:** Informational
**Category:** Testing
**Location:** `test/relay/gasless-relay.test.js`

**Description:**
The test suite (614 lines) covers:
- Deployment and domain verification
- Single relay (approve, transfer, batchTransfer)
- Batch relay (approve + createEscrow atomically)
- Invalid signature rejection
- Expired deadline rejection
- Wrong nonce rejection
- Replay protection
- Independent nonce management per user

Missing test coverage:
1. `executeBatch` with `refundReceiver = address(0)` (atomic mode -- should revert on any invalid request)
2. `executeBatch` with `msg.value > 0` forwarding native tokens
3. Forwarding to a contract that does NOT trust the forwarder (`ERC2771UntrustfulTarget` error)
4. Gas griefing scenario (relayer provides insufficient gas)
5. Request with `request.gas = 0`
6. Concurrent requests from different users in the same batch

**Recommendation:** Add these test cases before mainnet deployment for complete coverage.

---

### I-03: Contract Is a Singleton Trust Anchor for 27+ Contracts

**Severity:** Informational
**Category:** Architecture
**Location:** System-wide

**Description:**
OmniForwarder is deployed once and its address is hardcoded (immutable) into every ERC-2771-enabled contract in the system. This creates a single point of trust:

| Contract Type | Count | Forwarder Mutability |
|---------------|-------|---------------------|
| Non-upgradeable (immutable `trustedForwarder`) | ~12 | Cannot change after deployment |
| Upgradeable (immutable in implementation, but can redeploy implementation) | ~15 | Can change via proxy upgrade |

**Impact:** The forwarder address must be deployed first, and all other contracts must be deployed/initialized with the correct forwarder address. An error in the deployment order or address would require redeployment.

**Recommendation:**
1. Include the forwarder address in the deployment script's verification step
2. After deployment, verify via `eip712Domain()` that the domain is correct
3. For each downstream contract, verify via `isTrustedForwarder(forwarderAddress)` that the trust relationship is established

---

### I-04: Native Token Forwarding via `request.value` Is Supported but Unneeded

**Severity:** Informational
**Category:** Attack Surface Reduction
**Location:** Inherited `execute()` -- `msg.value` == `request.value` check

**Description:**
The forwarder supports forwarding native tokens (ETH/AVAX) via `request.value`. In the OmniCoin architecture, users never need native tokens -- validators absorb all gas costs, and all economic activity uses XOM/pXOM ERC-20 tokens.

The `msg.value` forwarding code is additional attack surface that provides no value in this architecture. However, since it is part of the inherited OpenZeppelin contract, it cannot be removed without forking the library.

**Recommendation:**
The validator relay service should reject any signed request where `request.value > 0`. This eliminates the native-token-forwarding attack surface at the off-chain layer.

---

### I-05: No Events Emitted by OmniForwarder Itself

**Severity:** Informational
**Category:** Monitoring
**Location:** OmniForwarder.sol (entire contract)

**Description:**
OmniForwarder emits no custom events. The inherited `ExecutedForwardRequest(address indexed signer, uint256 nonce, bool success)` event is emitted by the base contract on every execution.

This is sufficient for monitoring. The `signer` is indexed for efficient log filtering, and `success` indicates whether the subcall succeeded.

**Recommendation:** No action needed. The inherited event is adequate.

---

## Cross-Contract Integration Analysis

### Downstream Contract Correctness

All 27 ERC-2771-enabled contracts follow the same pattern for resolving the Context diamond ambiguity:

```solidity
function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
    return ERC2771Context._msgSender();
}

function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
    return ERC2771Context._msgData();
}

function _contextSuffixLength() internal view override(Context, ERC2771Context) returns (uint256) {
    return ERC2771Context._contextSuffixLength();
}
```

This pattern is correct. It ensures that when the forwarder calls a target contract:
1. `_msgSender()` extracts the original user address from the last 20 bytes of calldata
2. `_msgData()` strips those 20 bytes to return the original calldata
3. `_contextSuffixLength()` returns 20 (the size of the appended address)

When called directly (not via the forwarder), `_msgSender()` falls back to `msg.sender` as expected.

### ERC-2771 + delegatecall Warning

OpenZeppelin's `ERC2771Context` documentation warns: *"The usage of delegatecall in this contract is dangerous and may result in context corruption."*

None of the 27 downstream contracts use `delegatecall` in their user-facing functions. Upgradeable contracts use `delegatecall` only in the proxy layer, where the `ERC2771ContextUpgradeable` immutable `_trustedForwarder` is stored in the implementation's bytecode (not in proxy storage), which is correct.

**Result:** No delegatecall context corruption risk.

---

## Deployment Verification Checklist

| Check | Expected | How to Verify |
|-------|----------|---------------|
| EIP-712 domain name | `"OmniForwarder"` | `forwarder.eip712Domain().name` |
| EIP-712 version | `"1"` | `forwarder.eip712Domain().version` |
| Chain ID | `88008` | `forwarder.eip712Domain().chainId` |
| Verifying contract | Deployed address | `forwarder.eip712Domain().verifyingContract` |
| Initial nonce for all addresses | `0` | `forwarder.nonces(address)` |
| Trust relationship per contract | `true` | `targetContract.isTrustedForwarder(forwarderAddress)` |

---

## Gas Analysis

| Function | Approximate Gas Cost | Notes |
|----------|---------------------|-------|
| `execute()` (single relay) | ~60,000 + subcall gas | Signature recovery + nonce update + subcall |
| `executeBatch()` (N requests) | ~60,000 * N + subcall gas | Linear in batch size |
| `verify()` (view) | ~30,000 | Signature recovery + staticcall to target |
| `nonces()` (view) | ~2,600 | Single SLOAD |

Gas costs are dominated by the ECDSA signature recovery (~3,000 gas) and the external subcall. The forwarder adds minimal overhead.

---

## Final Assessment

**Overall Risk: LOW**

OmniForwarder is a textbook-correct deployment of OpenZeppelin's ERC2771Forwarder. The wrapper adds zero custom logic, which means the attack surface is limited to:

1. The well-audited OpenZeppelin base contract (v5.4.0)
2. The off-chain validator relay service (which must implement target whitelisting, rate limiting, and nonce management)
3. The deployment process (correct chain, correct address propagation to downstream contracts)

No critical or high findings were identified. The two medium findings (M-01, M-02) are operational concerns for the relay service rather than smart contract vulnerabilities. The low findings (L-01, L-02, L-03) describe inherent design tradeoffs that are acceptable given the architecture.

**The contract is ready for mainnet deployment**, provided:
1. The validator relay service implements the off-chain protections described in M-01 and M-02
2. The deployment script verifies the EIP-712 domain and trust relationships (see checklist above)
3. An emergency response plan exists for forwarder compromise (see L-02)
4. The additional test cases described in I-02 are implemented before or shortly after launch
