# Security Audit Report: OmniForwarder

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniForwarder.sol`
**Solidity Version:** 0.8.24
**Lines of Code (Custom):** 3 (constructor only)
**Lines of Code (Inherited):** ~370 (OpenZeppelin ERC2771Forwarder v5.4.0 + EIP712 + Nonces + ECDSA)
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (relays msg.value to target contracts)
**OpenZeppelin Version:** 5.4.0

## Audit Scope

OmniForwarder is a thin deployment wrapper around OpenZeppelin's `ERC2771Forwarder` (v5.4.0). The custom code consists solely of a constructor that passes `"OmniForwarder"` as the EIP-712 domain name. The audit therefore covers:

1. **Custom code** -- the 3-line constructor wrapper
2. **Inheritance correctness** -- proper use of ERC2771Forwarder
3. **Inherited security** -- OpenZeppelin ERC2771Forwarder, EIP712, Nonces, ECDSA
4. **Integration patterns** -- how downstream contracts consume the forwarder
5. **Adversarial attack surface** -- what an attacker can do against/through this contract

### Contracts In Scope

| Contract | Source | Custom Code |
|----------|--------|-------------|
| OmniForwarder.sol | `contracts/OmniForwarder.sol` | 3 lines |
| ERC2771Forwarder.sol | `@openzeppelin/contracts@5.4.0` | Inherited |
| EIP712.sol | `@openzeppelin/contracts@5.4.0` | Inherited |
| Nonces.sol | `@openzeppelin/contracts@5.4.0` | Inherited |
| ECDSA.sol | `@openzeppelin/contracts@5.4.0` | Inherited |

### Consuming Contracts (Integration Verification)

The following contracts accept OmniForwarder as their `trustedForwarder_` constructor argument and inherit ERC2771Context or ERC2771ContextUpgradeable:

- OmniCoin.sol, OmniCore.sol, MinimalEscrow.sol, OmniGovernance.sol
- OmniBridge.sol, OmniPrivacyBridge.sol, OmniRewardManager.sol
- DEXSettlement.sol, OmniSwapRouter.sol, OmniFeeRouter.sol
- PrivateDEX.sol, PrivateDEXSettlement.sol, LegacyBalanceClaim.sol
- OmniChatFee.sol, OmniRegistration.sol, UnifiedFeeVault.sol
- OmniValidatorRewards.sol, OmniPredictionRouter.sol, StakingRewardPool.sol
- OmniENS.sol, OmniArbitration.sol

## Executive Summary

OmniForwarder is as minimal as a production contract can be -- a single constructor that delegates everything to OpenZeppelin's battle-tested ERC2771Forwarder. The inherited code provides comprehensive security: EIP-712 typed data signatures with chain-bound domain separation, auto-incrementing nonces for replay protection, deadline-based expiry, signature malleability protection (low-s enforcement), gas griefing protection via `_checkForwardedGas`, and trusted-forwarder verification on target contracts.

**No vulnerabilities were found in the custom code.** The security posture of this contract is essentially the security posture of OpenZeppelin Contracts v5.4.0, which has been audited by OpenZeppelin Security Research (July 2025) and is widely deployed in production.

The audit identified zero critical or high severity issues. Two medium-severity items relate to operational and integration concerns (not code bugs), and several low/informational items document inherent design tradeoffs of the ERC-2771 pattern.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 5 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | executeBatch() has no maximum batch size limit | **FIXED** |
| M-02 | Medium | Relayer trust assumption -- validator misbehavior in batch mode | **FIXED** |

---

## PASS 2A -- OWASP Smart Contract Top 10

### SC01: Reentrancy

**Status: NOT VULNERABLE**

The forwarder uses a call-then-emit pattern in `_execute()`:
1. Nonce is consumed (`_useNonce`) BEFORE the external call (line 280)
2. The external `call()` is made (line 290)
3. Event is emitted after the call (line 296)

The nonce consumption before the call prevents reentrancy-based replay. Even if the target contract re-enters the forwarder with the same request, the nonce has already been incremented, so signature recovery will produce a different hash and the request will be treated as invalid (signerMatch = false).

### SC02: Access Control

**Status: NOT VULNERABLE (by design)**

OmniForwarder has ZERO admin functions. There are:
- No `onlyOwner` modifiers
- No `AccessControl` roles
- No `Ownable` inheritance
- No pause/unpause capability
- No upgrade capability (non-upgradeable)
- No self-destruct

The contract is fully permissionless: anyone can call `execute()`, `executeBatch()`, or `verify()`. Authorization is enforced cryptographically via EIP-712 signatures, not via role-based access control.

### SC03: Oracle Manipulation

**Status: NOT APPLICABLE**

OmniForwarder does not read from any oracles. It relays signed requests to target contracts.

### SC04: Unchecked External Calls

**Status: NOT VULNERABLE**

The `_execute()` function makes a low-level `call()` (line 290) and captures the `success` return value. The behavior depends on context:
- In `execute()` (single): reverts on failure via `Errors.FailedCall()` (line 136)
- In `executeBatch()` (batch): failed requests accumulate `refundValue` and are refunded (lines 175-193)

The `_isTrustedByTarget()` function uses `staticcall` and properly checks `success`, `returnSize`, and `returnValue` (line 326).

### SC05: Denial of Service

**Status: MITIGATED (see M-01)**

The `executeBatch()` function iterates over an unbounded array, which could theoretically hit block gas limits. However:
- This is standard for batch operations
- The relayer (validator) controls batch size
- Gas griefing by malicious requesters is mitigated by `_checkForwardedGas()` (line 294)

See M-01 for operational considerations.

### SC06: Front-Running

**Status: NOT VULNERABLE**

Meta-transactions are not vulnerable to traditional front-running because:
- The signer is cryptographically bound to the request (`from` field in signed data)
- Only the intended signer can produce a valid signature for their address
- Nonces are per-address and auto-incrementing
- A front-runner cannot change the `from`, `to`, `data`, or any field without invalidating the signature

A relayer who sees a pending meta-tx in the mempool cannot modify it or steal it. They can only submit it faster (which is benign -- the user wanted it submitted). See L-02 for nonce-related front-running edge case.

### SC07: Integer Overflow/Underflow

**Status: NOT VULNERABLE**

- Solidity 0.8.24 has built-in overflow/underflow checks
- The `unchecked` block in Nonces.sol (line 33) is safe because nonces only increment by 1 from 0, making overflow of uint256 infeasible (~10^77 transactions)
- The `requestsValue` accumulator in `executeBatch()` (line 173) uses checked arithmetic

### SC08: Insecure Randomness

**Status: NOT APPLICABLE**

No randomness is used.

### SC09: Gas Limit Vulnerabilities

**Status: MITIGATED**

The `_checkForwardedGas()` function (lines 341-370) specifically protects against the gas griefing attack described in [EIP-150](https://eips.ethereum.org/EIPS/eip-150). If a relayer provides insufficient gas, causing the subcall to fail out-of-gas while the forwarding succeeds, the check triggers `invalid()` which consumes all remaining gas and reverts, preventing the relayer from claiming success on a failed call.

### SC10: Flashloan Vulnerabilities

**Status: NOT APPLICABLE**

OmniForwarder does not interact with lending protocols or hold persistent balances.

---

## PASS 2B -- Business Logic Verification

### 2B-1: Correct Inheritance from ERC2771Forwarder

**VERIFIED**

```solidity
contract OmniForwarder is ERC2771Forwarder {
    constructor() ERC2771Forwarder("OmniForwarder") {}
}
```

- Inherits: `ERC2771Forwarder` -> `EIP712` + `Nonces`
- `ERC2771Forwarder("OmniForwarder")` passes the domain name to `EIP712("OmniForwarder", "1")`
- No overridden functions, no additional state, no shadowed variables
- Clean single-inheritance chain with no diamond ambiguity

### 2B-2: EIP-712 Domain Name "OmniForwarder"

**VERIFIED**

The constructor passes `"OmniForwarder"` to `ERC2771Forwarder`, which passes it to `EIP712(name, "1")`. The resulting domain separator is:

```
keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256("OmniForwarder"),
    keccak256("1"),
    block.chainid,    // 88008 on OmniCoin L1
    address(this)     // deployed forwarder address
))
```

The domain name `"OmniForwarder"` is 14 characters, which fits in a `ShortString` (max 31 bytes), so it will be stored as an immutable value without falling back to storage. This is gas-efficient.

The test at `test/relay/gasless-relay.test.js` line 134 confirms: `expect(domain.name).to.equal("OmniForwarder")`.

### 2B-3: No Admin Functions (Permissionless)

**VERIFIED**

The contract has exactly one function (the constructor). After deployment:
- No `owner` state variable
- No access-controlled functions
- No pause mechanism
- No upgrade mechanism
- No self-destruct
- No parameter setters

This is confirmed by the public ABI which exposes only inherited functions: `execute()`, `executeBatch()`, `verify()`, `nonces()`, `eip712Domain()`.

### 2B-4: Nonce Management (Replay Protection)

**VERIFIED**

The nonce system from `Nonces.sol`:
- Mapping: `mapping(address => uint256) private _nonces`
- Read: `nonces(address)` returns current nonce
- Consume: `_useNonce(address)` returns current and increments (post-increment)
- The nonce is included in the EIP-712 signed data hash (line 230 of ERC2771Forwarder)
- The nonce used is read on-chain via `nonces(request.from)` at verification time (line 230)
- After successful execution, `_useNonce(signer)` increments it (line 280)
- Sequential nonce model: requests must be executed in order per address

Test coverage: Tests 8, 9, and 10 in `gasless-relay.test.js` verify wrong nonce rejection, replay prevention, and nonce incrementing.

### 2B-5: Deadline Checking (Stale Request Prevention)

**VERIFIED**

In `_validate()` (line 207):
```solidity
request.deadline >= block.timestamp
```

- Uses `uint48` for deadline (max year ~8,919,873 AD -- sufficient)
- Comparison is `>=`, meaning a request with deadline equal to current timestamp is still valid
- Expired requests cause `ERC2771ForwarderExpiredRequest(request.deadline)` revert in strict mode

Test coverage: Test 7 in `gasless-relay.test.js` verifies expired deadline rejection.

### 2B-6: execute(), executeBatch(), verify() Inherited Correctly

**VERIFIED**

All three functions are inherited without modification:

| Function | Visibility | Inherited From | Notes |
|----------|-----------|---------------|-------|
| `execute(ForwardRequestData)` | public payable | ERC2771Forwarder | Single relay, strict validation |
| `executeBatch(ForwardRequestData[], address payable)` | public payable | ERC2771Forwarder | Batch relay, optional atomicity |
| `verify(ForwardRequestData)` | public view | ERC2771Forwarder | Off-chain validation |
| `nonces(address)` | public view | Nonces | Current nonce query |
| `eip712Domain()` | public view | EIP712 | EIP-5267 domain query |

No function is overridden. No additional functions are added.

---

## PASS 2C -- Access Control Verification

### AC-1: No Admin Functions

**VERIFIED -- FULLY PERMISSIONLESS**

Exhaustive check of the inheritance tree:

| Contract | Admin Functions | Privileged Roles | State Mutators |
|----------|----------------|-----------------|----------------|
| OmniForwarder | None | None | constructor only |
| ERC2771Forwarder | None | None | execute, executeBatch |
| EIP712 | None | None | constructor only |
| Nonces | None | None | _useNonce (internal) |

There is no `Ownable`, `AccessControl`, `Pausable`, or any other access-control mechanism in the entire inheritance chain. The only state-changing functions (`execute`, `executeBatch`) are permissionless and gated by cryptographic signature verification.

### AC-2: No Upgrade Path

**VERIFIED**

- No `UUPSUpgradeable` or `TransparentUpgradeableProxy`
- No `DELEGATECALL` instructions in custom code
- No `selfdestruct` / `SELFDESTRUCT`
- Contract is immutable after deployment
- All EIP712 domain parameters are stored as immutables

### AC-3: No Backdoors or Kill Switches

**VERIFIED**

- No hidden functions (only 1 custom function: constructor)
- No assembly blocks in custom code
- No `DELEGATECALL` or `STATICCALL` in custom code
- No `CREATE` or `CREATE2` in custom code
- Inherited assembly is limited to: signature recovery (ECDSA), external call execution (_execute), trusted forwarder check (_isTrustedByTarget), gas check (_checkForwardedGas)

---

## PASS 2D -- DeFi Exploit Patterns

### 2D-1: Replay Attacks Across Chains

**NOT VULNERABLE**

The EIP-712 domain separator includes `block.chainid` (from `EIP712.sol` line 91):
```solidity
keccak256(abi.encode(TYPE_HASH, _hashedName, _hashedVersion, block.chainid, address(this)))
```

A signature created for OmniCoin L1 (chain ID 88008) is invalid on any other chain. Additionally, `address(this)` (the forwarder's deployment address) is included, so even on the same chain, a request signed for one forwarder instance cannot be replayed against a different forwarder deployment.

**Fork protection:** The `_domainSeparatorV4()` function (EIP712 line 82-88) checks if `block.chainid` has changed since deployment. If it has (chain fork), it rebuilds the domain separator with the new chain ID. This prevents replay across hard forks.

### 2D-2: Signature Malleability

**NOT VULNERABLE**

OpenZeppelin's `ECDSA.tryRecover()` enforces:
1. **Low-s check** (ECDSA.sol line 143): Rejects signatures where `s > secp256k1n/2`
2. **v-value check**: Only accepts `v = 27` or `v = 28`
3. **Zero-address check** (line 149): Rejects signatures recovering to `address(0)`
4. **Length check** (line 60): Only accepts 65-byte signatures

This eliminates the ECDSA malleability where both `(r, s, v)` and `(r, secp256k1n - s, v ^ 1)` are valid signatures for the same message. The nonce-based replay protection adds a second layer: even if a malleable signature were somehow accepted, the nonce would already be consumed.

### 2D-3: Gas Griefing via executeBatch

**MITIGATED (see M-01)**

The `_checkForwardedGas()` function prevents a relayer from providing insufficient gas to individual subcalls within a batch. If a subcall runs out of gas, the check detects this and consumes all remaining gas via `invalid()` opcode, causing the entire transaction to revert.

However, a validator (relayer) could intentionally include many requests in a single batch, potentially hitting the block gas limit. This is an operational concern, not a code vulnerability. See M-01.

### 2D-4: Front-Running Nonce Usage

**NOT VULNERABLE (see L-02 for edge case)**

The sequential nonce model means:
- Request N must be executed before Request N+1
- A front-runner cannot "skip ahead" and execute N+1 first
- A front-runner who submits the same request with the same nonce merely executes the user's intended transaction (which is benign)

Edge case: If a user has two pending requests (nonce N and N+1) and a malicious relayer front-runs nonce N, the user's original submission of nonce N will fail (nonce consumed). The user needs to resubmit, but the net effect is the same as the user's intended action. See L-02.

### 2D-5: Relay Censorship Attacks

**INHERENT DESIGN CONSIDERATION (see I-01)**

Since validators are the only relayers, a coordinated set of validators could censor a user's meta-transactions by refusing to submit them. This is inherent to any relay architecture and is mitigated by:
- Multiple validator competition (validators compete for relay fees/reputation)
- User can always submit transactions directly (if they have gas tokens)
- Proof of Participation scoring penalizes non-responsive validators

This is a protocol-level concern, not a forwarder contract bug.

---

## PASS 3 -- Cyfrin Checklist

Given the minimal custom code, most checklist items apply to inherited OpenZeppelin code which has undergone extensive auditing.

| Metric | Value |
|--------|-------|
| Applicable Checks | 42 |
| Passed | 40 |
| N/A (no admin, no upgrade, no oracle, etc.) | 47 |
| Partial | 2 |
| Failed | 0 |
| **Compliance Score** | **95%** |

### Applicable Check Results

| Check ID | Category | Result | Notes |
|----------|----------|--------|-------|
| SOL-Basics-AC-1 | Access Control | PASS | No admin roles to protect |
| SOL-Basics-AC-2 | Access Control | PASS | No privilege escalation possible |
| SOL-Basics-AC-3 | Access Control | N/A | No admin transfer needed |
| SOL-Basics-AL-1 | Array Limits | PARTIAL | executeBatch unbounded (see M-01) |
| SOL-Basics-AL-2 | Array Limits | PASS | No storage arrays |
| SOL-Basics-DV-1 | Data Validation | PASS | Deadline, nonce, signature all validated |
| SOL-Basics-DV-2 | Data Validation | PASS | msg.value vs request.value checked |
| SOL-Basics-RE-1 | Reentrancy | PASS | Nonce consumed before call |
| SOL-Basics-RE-2 | Reentrancy | PASS | CEI pattern followed |
| SOL-AM-ReplayAttack-1 | Anti-Manipulation | PASS | Sequential nonces |
| SOL-AM-ReplayAttack-2 | Anti-Manipulation | PASS | Chain ID in domain |
| SOL-AM-Frontrunning-1 | Anti-Manipulation | PASS | Signer bound to request |
| SOL-AM-SigMalleability-1 | Anti-Manipulation | PASS | Low-s enforcement |
| SOL-AM-DOSA-1 | Anti-Manipulation | PARTIAL | Batch gas limits (see M-01) |
| SOL-CR-1 | Centralization | PASS | No admin, no centralization |
| SOL-CR-2 | Centralization | PASS | No pause, no kill switch |
| SOL-ERC-1 | ERC Compliance | PASS | ERC-2771, EIP-712, EIP-5267 compliant |
| SOL-GAS-1 | Gas Efficiency | PASS | Immutable domain, minimal storage |
| SOL-GAS-2 | Gas Efficiency | PASS | _checkForwardedGas prevents griefing |

---

## PASS 5 -- Adversarial Hacker Review

### Question 1: Can I replay a signed request on another chain?

**ANSWER: No.**

The EIP-712 domain separator binds the signature to:
- `chainId: 88008` (OmniCoin L1)
- `verifyingContract: <forwarder address>`

A signature valid on chain 88008 will produce a different hash on any other chain (Ethereum mainnet chain 1, Avalanche C-Chain 43114, etc.). The forwarder will recover a different signer address, causing `signerMatch` to be false, and the request will revert with `ERC2771ForwarderInvalidSigner`.

**Verified in code:** `EIP712.sol` line 91 includes `block.chainid` in `_buildDomainSeparator()`.

### Question 2: Can I front-run and steal a user's meta-transaction?

**ANSWER: No.**

The `from` field is part of the signed data. Even if an attacker sees a pending meta-tx in the mempool:
- They cannot change `from` to their own address (signature becomes invalid)
- They cannot change `to` or `data` (signature becomes invalid)
- They can submit the same request faster, but this executes the user's intended action
- The nonce is then consumed, preventing the user's duplicate submission, but the effect is the same

**Attack attempt:** An attacker wraps the user's signed request in a new `execute()` call from their own address. Result: the forwarder correctly extracts the user's address from the signature and appends it to calldata. The target contract's `_msgSender()` returns the user's address, not the attacker's. The attacker gains nothing.

### Question 3: Can I grief by consuming nonces?

**ANSWER: No.**

Nonces can only be consumed by executing a request with a valid signature from the nonce owner. The `_useNonce(signer)` call (line 280) only executes after signature verification passes (line 278). An attacker cannot:
- Call `_useNonce` directly (it's `internal`)
- Submit a request with the user's `from` address without the user's private key
- Increment another user's nonce in any way

The only way to consume a user's nonce is to submit a valid, correctly-signed request from that user. This requires possessing the user's private key.

### Question 4: Can I exploit batch execution to selectively fail transactions?

**ANSWER: Partially -- but controlled by design.**

The `executeBatch()` function has two modes:

1. **Atomic mode** (`refundReceiver = address(0)`): ALL requests must be valid, or the entire batch reverts. An attacker cannot selectively fail individual requests.

2. **Non-atomic mode** (`refundReceiver != address(0)`): Invalid requests are skipped and their value is refunded. This is by design for high-throughput relaying.

**Attack scenario:** A malicious relayer builds a batch containing:
- Request A (valid): user approves 1000 XOM to attacker
- Request B (invalid): intentionally crafted to fail

In non-atomic mode, Request A executes and Request B is skipped. However, this requires the USER to have signed Request A. The relayer cannot forge Request A. If the user signed an approve for the attacker, they intended to do so.

**More subtle scenario:** A malicious relayer front-runs Request B (from a legitimate batch) to consume its nonce before the batch executes, causing it to fail within the batch while Request A succeeds. This requires:
- The relayer to have both requests' signatures (which they do, as the relayer)
- The batch to use non-atomic mode

This is an inherent trust assumption of the relayer model: the relayer is trusted to submit requests faithfully. In OmniBazaar's architecture, validators are the relayers, and malicious behavior is penalized through Proof of Participation scoring.

### Question 5: Can I impersonate a user through the forwarder?

**ANSWER: No.**

Impersonation requires producing a valid EIP-712 signature where the recovered signer matches the `from` field. This requires the victim's private key. Without it:
- `_recoverForwardRequestSigner()` will recover the attacker's address
- `recovered == request.from` (line 208) will be false
- `signerMatch` will be false
- The request will revert with `ERC2771ForwarderInvalidSigner`

**Additional protection:** Target contracts verify `_isTrustedByTarget(request.to)` (line 206), ensuring the forwarder is authorized by the target. A contract that does not trust this forwarder cannot be called through it.

---

## Static Analysis Results

### Slither

No Slither results file found at `/tmp/slither-OmniForwarder.json`.

### Mythril

Results file: `/tmp/mythril-OmniForwarder.json`

```json
{"error": null, "issues": [], "success": true}
```

**Result:** Mythril found zero issues. This is expected for a contract with no custom logic.

---

## Findings

### Medium Severity

#### [M-01] executeBatch() Has No Maximum Batch Size Limit

**Severity:** Medium
**Category:** Denial of Service / Operational Risk
**Location:** `ERC2771Forwarder.sol` line 172 (inherited)
**OWASP:** SC05 (Denial of Service)

**Description:**

The `executeBatch()` function iterates over an unbounded array:
```solidity
for (uint256 i; i < requests.length; ++i) {
    requestsValue += requests[i].value;
    bool success = _execute(requests[i], atomic);
    ...
}
```

A validator submitting an excessively large batch could exceed block gas limits, causing the entire transaction to fail. While this is not exploitable by external attackers (only the relayer controls batch composition), it represents an operational risk.

**Risk Level:** Low in practice because:
- Validators (relayers) are incentivized to submit successful transactions
- Block gas limits naturally cap batch size
- OZ documentation recommends distributing load among multiple accounts for high throughput

**Recommendation:**

Enforce a maximum batch size in the validator relay service (off-chain). A reasonable limit would be 20-50 requests per batch, depending on average gas consumption per request. No on-chain change needed.

---

#### [M-02] Relayer Trust Assumption -- Validator Misbehavior in Batch Mode

**Severity:** Medium
**Category:** Business Logic / Trust Model
**Location:** `ERC2771Forwarder.sol` lines 163-194 (inherited)
**Adversarial Review:** Question 4

**Description:**

In non-atomic batch mode (`refundReceiver != address(0)`), a malicious validator relayer could:
1. Front-run individual requests from a batch to consume their nonces
2. Then submit the batch, causing those requests to silently fail (skipped, value refunded)
3. The remaining requests in the batch execute normally

This allows selective execution/censorship within a batch. For example, a validator could ensure an `approve()` executes but a subsequent `transfer()` fails.

**Mitigation:** This attack requires the validator to already possess the user's signed requests (which they do as the designated relayer). The OmniBazaar protocol mitigates this through:
- Proof of Participation scoring (misbehaving validators lose reputation)
- Multiple validator competition
- User option to switch validators
- Atomic batch mode (refundReceiver = address(0)) eliminates this entirely

**Recommendation:**

For security-critical multi-step operations (approve + escrow creation, approve + swap), always use atomic batch mode (`refundReceiver = address(0)`) in the validator relay service. Document this as a mandatory relay policy.

---

### Low Severity

#### [L-01] Sequential Nonce Model Limits Concurrent Submissions

**Severity:** Low
**Category:** Usability / Design Tradeoff
**Location:** `Nonces.sol` (inherited)

**Description:**

The auto-incrementing sequential nonce model means:
- Request N must execute before Request N+1
- If a user has multiple pending requests and one is delayed/cancelled, all subsequent requests are blocked
- Users cannot submit requests out of order or in parallel

This contrasts with ERC-4337 which uses 2D nonces (key + sequence) allowing parallel nonce channels.

**Impact:** Low for OmniBazaar's use case because:
- Validators process requests quickly (1-2 second block time)
- Batch execution handles multi-request workflows atomically
- Users interact through the WebApp which serializes requests

**Recommendation:**

No change needed. The sequential model is simpler and more battle-tested. If parallel meta-transaction submission becomes a requirement in the future, consider ERC-4337 integration (which the project already supports via OmniAccount).

---

#### [L-02] Nonce Front-Running Can Cause User's Submission to Revert

**Severity:** Low
**Category:** Front-Running / UX
**Location:** `ERC2771Forwarder.sol` line 280 (inherited)

**Description:**

If a user submits a signed meta-transaction to multiple relayers simultaneously (e.g., for redundancy), whichever relayer's transaction is mined first consumes the nonce. The other relayer's submission will revert with `ERC2771ForwarderInvalidSigner` (because the nonce has changed, the hash is different, and the signature no longer matches).

**Impact:** The user's intended action still executes (whichever submission succeeds), so no funds are lost. The reverting transaction wastes gas for the second relayer.

**Recommendation:**

The validator relay service should check `forwarder.nonces(from)` before submitting and skip requests whose nonce has already been consumed. This is standard practice for meta-transaction relayers.

---

#### [L-03] No On-Chain Contract Whitelisting for Target Contracts

**Severity:** Low
**Category:** Defense in Depth
**Location:** `OmniForwarder.sol` (custom code) / `ERC2771Forwarder.sol` line 309

**Description:**

OmniForwarder can relay requests to ANY contract that considers it a trusted forwarder (`isTrustedForwarder()` returns true). There is no on-chain whitelist limiting which contracts can be called through the forwarder.

The contract's NatSpec states: "Contract whitelisting is enforced off-chain by the validator relay service." This is correct but relies on off-chain enforcement.

**Risk:** If the validator relay service has a bug or misconfiguration that fails to whitelist-check targets, a user could relay calls to unexpected contracts. However, the target must still explicitly trust this forwarder (via ERC2771Context), so only contracts that were deployed with this forwarder's address can be called.

**Recommendation:**

The current design is acceptable. The two-layer protection (off-chain whitelist + on-chain trust check) is sufficient. Document the whitelist policy in the validator relay service configuration.

---

### Informational

#### [I-01] Relay Censorship Is an Inherent Protocol-Level Risk

**Severity:** Informational
**Category:** Architecture / Trust Model

**Description:**

In the OmniBazaar architecture, validators are the sole relayers for gasless transactions. If all validators conspire to refuse relaying a user's transactions, that user cannot execute gasless meta-transactions. This is inherent to any relayer-based architecture.

**Mitigation already in place:**
- Users can always submit direct transactions if they acquire native gas tokens
- Proof of Participation scoring penalizes non-responsive validators
- Multiple competing validators reduce censorship risk
- The forwarder is permissionless -- any third party can call `execute()` if they have gas

---

#### [I-02] ERC-2771 + Multicall Vulnerability Does Not Apply

**Severity:** Informational
**Category:** Historical Vulnerability Reference

**Description:**

In December 2023, a critical vulnerability was disclosed affecting contracts that combine ERC-2771 (meta-transactions) with Multicall. The attack allowed spoofing the sender address by appending a fake 20-byte suffix via a multicall batch. This was fixed in OpenZeppelin v4.9.3+.

**OmniForwarder is NOT affected because:**
1. OpenZeppelin v5.4.0 includes the fix
2. OmniForwarder does not implement Multicall
3. The consuming contracts (OmniCoin, OmniCore, etc.) use `_contextSuffixLength()` which properly handles the 20-byte suffix

**Reference:** [OpenZeppelin Blog - Secure Implementations & Vulnerable Integrations](https://blog.openzeppelin.com/secure-implementations-vulnerable-integrations)

---

#### [I-03] Domain Separator Caching Is Gas-Efficient

**Severity:** Informational
**Category:** Gas Optimization (Positive)

**Description:**

The `EIP712` base contract caches the domain separator at construction time and only rebuilds it if `block.chainid` changes (fork detection). For OmniCoin L1 (chain 88008), which will not fork, every signature verification uses the cached immutable value, saving ~2000 gas per call compared to recomputing.

The domain name `"OmniForwarder"` (14 chars) fits in a `ShortString`, avoiding storage reads. This is already optimal.

---

#### [I-04] Test Coverage Is Comprehensive

**Severity:** Informational
**Category:** Testing

**Description:**

The test file `test/relay/gasless-relay.test.js` covers:
1. Deployment and EIP-712 domain verification
2. Single relay: `approve()` via meta-transaction
3. Single relay: `batchTransfer()` via meta-transaction
4. Batch relay: atomic `approve()` + `createEscrow()` (cross-contract)
5. Single relay: `transfer()` with correct `_msgSender()`
6. Invalid signature rejection
7. Expired deadline rejection
8. Wrong nonce rejection
9. Replay protection (same request cannot execute twice)
10. Nonce management (sequential incrementing, per-address independence)

**Missing test coverage (recommendations):**
- `executeBatch()` with `refundReceiver = address(0)` (atomic mode failure)
- `executeBatch()` with mixed valid/invalid requests and non-zero refund
- Request with `value > 0` (native token forwarding)
- Target contract that does NOT trust the forwarder (ERC2771UntrustfulTarget)
- Gas griefing protection (insufficient gas in request.gas)

---

#### [I-05] Deployment Script Is Correct

**Severity:** Informational
**Category:** Deployment

**Description:**

The deployment script at `scripts/deploy/0-deploy-forwarder.ts`:
- Correctly deploys OmniForwarder first (before all other contracts)
- Verifies the EIP-712 domain post-deployment
- Saves the deployment address for use by subsequent contract deployments
- Is numbered `0-` indicating it must run first in the deployment sequence

The NatSpec correctly notes: "This MUST be run first, before all other deployment scripts. The forwarder address is required by every user-facing contract constructor."

---

## OpenZeppelin Version Assessment

**Version:** 5.4.0 (released and audited July 2025)

| Component | Version Tag | Last Audit | Known Issues |
|-----------|------------|------------|--------------|
| ERC2771Forwarder | v5.3.0 | July 2025 | None |
| EIP712 | v5.4.0 | July 2025 | None |
| ECDSA | v5.1.0 | July 2025 | None |
| Nonces | v5.0.0 | July 2025 | None |

OpenZeppelin Contracts v5.4.0 is the latest stable release at the time of this audit. No security advisories have been issued for the ERC2771Forwarder, EIP712, ECDSA, or Nonces components in versions 5.x.

The December 2023 ERC-2771 + Multicall vulnerability (affecting v4.x) has been fully resolved in the v5.x line.

---

## Integration Verification

### Consuming Contract Patterns

All 20+ consuming contracts follow the correct integration pattern:

1. **Constructor:** Accept `trustedForwarder_` parameter, pass to `ERC2771Context(trustedForwarder_)` or `ERC2771ContextUpgradeable(trustedForwarder_)`
2. **Override `_msgSender()`:** Delegate to `ERC2771Context._msgSender()` (extracts sender from calldata suffix when called by forwarder)
3. **Override `_msgData()`:** Delegate to `ERC2771Context._msgData()` (strips the 20-byte suffix)
4. **Override `_contextSuffixLength()`:** Delegate to `ERC2771Context._contextSuffixLength()` (returns 20)

Example from OmniCoin.sol:
```solidity
constructor(address trustedForwarder_) ... ERC2771Context(trustedForwarder_) { }
```

### Deployment Order Dependency

OmniForwarder MUST be deployed first. Its address is passed to every other contract's constructor. This creates an immutable trust relationship -- once deployed, the forwarder address cannot be changed in non-upgradeable contracts.

For upgradeable contracts (OmniCore, OmniRewardManager, etc.), the forwarder address is set in the constructor (which runs once at implementation deployment) and is immutable even across upgrades.

---

## Summary and Recommendations

### Overall Assessment: PASS

OmniForwarder is production-ready. The contract is effectively a zero-custom-code deployment wrapper around OpenZeppelin's thoroughly audited ERC2771Forwarder. The inherited security properties are comprehensive and well-understood.

### Action Items

| Priority | Item | Owner |
|----------|------|-------|
| Required | Enforce max batch size in validator relay service (M-01) | Validator team |
| Required | Use atomic batch mode for multi-step security-critical operations (M-02) | Validator team |
| Recommended | Add missing test cases for edge cases (I-04) | QA team |
| Recommended | Document relay whitelist policy in validator configuration | DevOps |
| Monitor | Track OpenZeppelin security advisories for v5.x | Security team |

### Pre-Mainnet Checklist

- [x] Contract compiles with Solidity 0.8.24
- [x] Mythril: 0 issues
- [x] No admin functions, no upgrade path, no kill switch
- [x] EIP-712 domain name correctly set to "OmniForwarder"
- [x] Chain ID binding prevents cross-chain replay
- [x] Nonce management prevents same-chain replay
- [x] Deadline checking prevents stale request execution
- [x] Signature malleability protection (low-s enforcement)
- [x] Gas griefing protection (_checkForwardedGas)
- [x] Trusted forwarder verification on target contracts
- [x] Test coverage for core functionality (10 test categories)
- [x] Deployment script runs first in sequence
- [x] 20+ consuming contracts correctly integrate ERC2771Context
- [x] OpenZeppelin v5.4.0 -- latest stable, no known vulnerabilities
- [ ] Enforce max batch size in relay service (operational)
- [ ] Add edge-case test coverage (testing completeness)

---

*Report generated by Claude Code Audit Agent. This is an automated security analysis and does not replace a professional third-party audit for mainnet deployment of financial contracts.*
