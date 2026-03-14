# Security Audit Report: OmniChatFee (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 -- Pre-Mainnet Final Review)
**Contract:** `Coin/contracts/chat/OmniChatFee.sol`
**Solidity Version:** 0.8.24 (locked)
**Lines of Code:** 425
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes -- collects XOM fees for chat messages and transfers 100% to UnifiedFeeVault
**Prior Audits:**
- Round 1 (2026-02-28): 0C/0H/1M/4L/4I -- Initial comprehensive audit
- Round 6 (2026-03-10): 0C/0H/2M/3L/2I -- Post-remediation deep dive

---

## Executive Summary

This Round 7 pre-mainnet final audit reviews OmniChatFee.sol after extensive remediation from Rounds 1 and 6. The contract manages per-message chat fees with a free tier (20 messages/month per user) and anti-spam protection via a 10x multiplier on bulk messages. Fees are collected as XOM and transferred 100% to UnifiedFeeVault, which handles the canonical 70/20/10 split.

The contract has matured significantly across three audit rounds. All Medium findings from prior rounds have been properly remediated. The architecture was substantially simplified between Round 1 and Round 6 by removing the in-contract 70/20/10 split and delegating it entirely to UnifiedFeeVault, eliminating the mutable recipient address attack surface and the fee split documentation mismatch.

This audit focuses on residual edge cases, cross-contract integration correctness with UnifiedFeeVault, ERC2771 meta-transaction safety, the payment proof mechanism, and attack surface analysis for the final mainnet deployment.

**Remediation Status from Round 6:**

| Round 6 ID | Severity | Finding | Status |
|------------|----------|---------|--------|
| MEDIUM-01 | Medium | Fee distribution split does not match documentation | **FIXED** -- Contract now sends 100% to UnifiedFeeVault; vault handles 70/20/10 split. Documentation updated. |
| MEDIUM-02 | Medium | Mutable recipient addresses can redirect fees | **FIXED** -- `feeVault` is now `immutable`; no `updateRecipients()` function exists. Attack surface eliminated. |
| LOW-01 | Low | No upper bound on `baseFee` in `setBaseFee()` | **ACCEPTED** -- See L-01 below for re-evaluation |
| LOW-02 | Low | Bulk fee overflow for extreme baseFee | **ACCEPTED** -- Solidity 0.8 reverts on overflow; tied to L-01 |
| LOW-03 | Low | Free tier bypass via multiple addresses | **ACCEPTED** -- Design limitation; KYC enforcement at validator level |
| LOW-04 | Info | 30-day month approximation | **ACCEPTED** -- Documented in NatSpec |
| LOW-05 | Info | paymentProofs grow without bound | **ACCEPTED** -- Boolean per message; zero gas cost on OmniCoin chain |

**Remediation Status from Round 1:**

| Round 1 ID | Severity | Finding | Status |
|------------|----------|---------|--------|
| M-01 | Medium | CEI violation: external calls before state updates | **FIXED** -- State updates (monthlyMessageCount, paymentProofs) now occur before `_collectFee()` in both `payMessageFee()` and `payBulkMessageFee()` |
| L-01 | Low | `setBaseFee()` allows zero | **FIXED** -- `if (newBaseFee == 0) revert ZeroBaseFee()` added |
| L-02 | Low | `updateRecipients()` silent no-op | **FIXED** -- Function removed entirely; feeVault is immutable |
| L-03 | Low | Bulk messages bypass free tier | **DOCUMENTED** -- Intentional by design; NatSpec added explaining anti-spam rationale |
| L-04 | Low | No timelock on admin functions | **PARTIALLY FIXED** -- Ownable2Step adopted; baseFee still instant-change (see L-01) |
| I-01 | Info | Single-step ownership transfer | **FIXED** -- Upgraded to Ownable2Step |
| I-02 | Info | 30-day month approximation | **ACCEPTED** -- Documented |
| I-03 | Info | No validator whitelisting | **ACCEPTED** -- Validator address is for event logging only; fees go to feeVault |
| I-04 | Info | Push transfers to configurable addresses could revert | **FIXED** -- Single push to immutable feeVault; no multi-recipient push risk |

**New Findings (Round 7):**

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 3 |
| Informational | 4 |

---

## Solhint Analysis

```
contracts/chat/OmniChatFee.sol
   86:5   warning  Immutable variables name are set to be in capitalized SNAKE_CASE              immutable-vars-naming
  120:5   warning  GC: [messageIndex] on Event [MessageFeePaid] could be Indexed                 gas-indexed-events
  120:5   warning  GC: [fee] on Event [MessageFeePaid] could be Indexed                          gas-indexed-events
  120:5   warning  GC: [validator] on Event [MessageFeePaid] could be Indexed                     gas-indexed-events
  133:5   warning  GC: [messageIndex] on Event [FreeMessageUsed] could be Indexed                gas-indexed-events
  133:5   warning  GC: [remaining] on Event [FreeMessageUsed] could be Indexed                   gas-indexed-events
  143:5   warning  GC: [oldFee] on Event [BaseFeeUpdated] could be Indexed                       gas-indexed-events
  143:5   warning  GC: [newFee] on Event [BaseFeeUpdated] could be Indexed                       gas-indexed-events
  198:28  warning  GC: For [userMessageIndex] increment by 1 using: [++variable]                 gas-increment-by-one
  246:28  warning  GC: For [userMessageIndex] increment by 1 using: [++variable]                 gas-increment-by-one
  249:9   warning  GC: For [monthlyMessageCount] increment by 1 using: [++variable]              gas-increment-by-one
  292:13  warning  GC: Non strict inequality found                                                gas-strict-inequalities
  328:5   warning  Function order incorrect, external after external view                         ordering

0 errors, 13 warnings
```

**Assessment:** All 13 warnings are gas optimization suggestions and a function ordering preference. No errors. The gas optimizations are cosmetic on the OmniCoin L1 chain where gas costs are absorbed by validators. The immutable naming convention (`xomToken` vs `XOM_TOKEN`) is a style choice consistent with the rest of the codebase. No action required.

---

## Architecture Review

### Inheritance Chain

```
OmniChatFee
  ├── ReentrancyGuard          (OpenZeppelin -- reentrancy protection)
  ├── Ownable2Step -> Ownable  (OpenZeppelin -- two-step ownership transfer)
  └── ERC2771Context -> Context (OpenZeppelin -- gasless meta-tx support)
```

**Assessment:** Clean inheritance. The diamond conflict between `Context` (inherited via `Ownable`) and `ERC2771Context` is properly resolved with explicit `_msgSender()`, `_msgData()`, and `_contextSuffixLength()` overrides at lines 384-424. All three overrides correctly delegate to `ERC2771Context`, ensuring the trusted forwarder path is always used.

### Fee Flow Architecture

```
User --> OmniChatFee.payMessageFee()
           |
           ├── Free tier (messages 1-20/month):
           |     State updates only, no token transfer
           |
           └── Paid tier (message 21+/month):
                 _collectFee() --> safeTransferFrom(user, feeVault, baseFee)
                                          |
                                   UnifiedFeeVault (immutable address)
                                          |
                                   distribute() --> 70% ODDAO
                                                    20% Staking Pool
                                                    10% Protocol Treasury
```

**Assessment:** The two-contract delegation model is architecturally sound. OmniChatFee is responsible only for metering (free tier tracking, payment proofs, anti-spam multiplier) and fee collection. All distribution logic lives in UnifiedFeeVault. This eliminates the entire class of fee-split arithmetic bugs from OmniChatFee.

### State Variables

| Variable | Type | Mutability | Purpose |
|----------|------|------------|---------|
| `xomToken` | `IERC20` | `immutable` | XOM token reference |
| `feeVault` | `address` | `immutable` | UnifiedFeeVault address |
| `baseFee` | `uint256` | mutable (owner-only) | Per-message fee amount |
| `monthlyMessageCount` | `mapping(address => mapping(uint256 => uint256))` | mutable | Free tier tracking |
| `paymentProofs` | `mapping(address => mapping(bytes32 => mapping(uint256 => bool)))` | mutable | Payment verification |
| `userMessageIndex` | `mapping(address => uint256)` | mutable | Monotonic per-user counter |
| `totalFeesCollected` | `uint256` | mutable | Cumulative fee tracker |

**Assessment:** Minimal state surface. Two immutables prevent post-deployment target manipulation. The only mutable admin parameter is `baseFee`, protected by `onlyOwner` + `Ownable2Step`.

---

## Reentrancy Analysis

### payMessageFee() (lines 188-225)

```
1. CHECKS:   channelId != 0, validator != 0
2. EFFECTS:  userMessageIndex[caller]++
             monthlyMessageCount[caller][month] = used + 1
             paymentProofs[caller][channelId][msgIndex] = true
3. INTERACTIONS: _collectFee(caller, baseFee) --> safeTransferFrom()
```

**Assessment:** CEI-compliant. All state mutations complete before the external `safeTransferFrom` call. The `nonReentrant` modifier provides defense-in-depth. The M-01 finding from Round 1 has been properly remediated.

### payBulkMessageFee() (lines 236-260)

```
1. CHECKS:   channelId != 0, validator != 0
2. EFFECTS:  userMessageIndex[caller]++
             monthlyMessageCount[caller][month]++
             paymentProofs[caller][channelId][msgIndex] = true
3. INTERACTIONS: _collectFee(caller, fee) --> safeTransferFrom()
```

**Assessment:** CEI-compliant. Same pattern as `payMessageFee()`. Both `nonReentrant` and CEI ordering provide layered protection.

### _collectFee() (lines 347-358)

```
1. CHECKS:   fee < MIN_FEE enforcement (floor to MIN_FEE)
2. INTERACTIONS: safeTransferFrom(user, feeVault, fee)
3. EFFECTS:  totalFeesCollected += fee
```

**Assessment:** The `totalFeesCollected` increment occurs after the external call. This is a minor CEI impurity, but since `totalFeesCollected` is a read-only accounting variable (not used in any logic path within this contract), it cannot be exploited. The `nonReentrant` modifier on callers prevents re-entry regardless. **No risk.**

---

## Access Control Review

| Function | Modifier | Caller | Assessment |
|----------|----------|--------|------------|
| `payMessageFee()` | `nonReentrant` | Any user | Correct -- metered by free tier + fee |
| `payBulkMessageFee()` | `nonReentrant` | Any user | Correct -- always charges 10x fee |
| `hasValidPayment()` | `view` | Anyone | Correct -- read-only proof check |
| `freeMessagesRemaining()` | `view` | Anyone | Correct -- read-only |
| `currentMonth()` | `view` | Anyone | Correct -- read-only |
| `nextMessageIndex()` | `view` | Anyone | Correct -- read-only |
| `setBaseFee()` | `onlyOwner` | Owner only | Correct -- protected by Ownable2Step |

**Ownership Model:**
- `Ownable2Step` prevents accidental ownership loss (two-step: `transferOwnership()` + `acceptOwnership()`)
- Single admin key controls only `baseFee` -- no fund extraction, no recipient changes
- `xomToken` and `feeVault` are immutable -- owner cannot redirect fee flow

**Centralization Risk: 2/10** -- The owner can only adjust `baseFee`. They cannot withdraw contract funds (contract holds no funds; `safeTransferFrom` goes directly user -> feeVault). They cannot redirect fees to a different address. The worst case is setting an extremely high fee that makes paid chat prohibitively expensive, but the free tier (20 messages/month) remains unaffected.

---

## Fee Mechanics Analysis

### Free Tier

- **Limit:** 20 messages per 30-day period (constant `FREE_TIER_LIMIT = 20`)
- **Tracking:** `monthlyMessageCount[user][month]` where `month = block.timestamp / 30 days`
- **Reset:** Automatic when the month identifier changes (no explicit reset transaction needed)
- **Cost:** Zero XOM -- no `safeTransferFrom` called for free messages

**Assessment:** Correct. Free tier operates as documented in the CLAUDE.md specification ("Free tier: Up to 20 messages/month").

### Paid Messages

- **Trigger:** When `monthlyMessageCount[user][month] >= FREE_TIER_LIMIT`
- **Fee:** `baseFee` (configurable, currently 0.001 XOM = 1e15 wei)
- **Floor:** `MIN_FEE = 1e15` (0.001 XOM) -- prevents precision-loss rounding to zero
- **Destination:** 100% to `feeVault` (UnifiedFeeVault, immutable)

**Assessment:** Correct. The `MIN_FEE` floor in `_collectFee()` (line 352) ensures that even if `baseFee` is set below `MIN_FEE`, the actual collected amount is at least `MIN_FEE`. However, see L-02 below for an inconsistency this creates.

### Bulk Messages

- **Fee:** `baseFee * BULK_FEE_MULTIPLIER` (10x)
- **Free tier bypass:** Always charged, even if free messages remain (intentional anti-spam)
- **Monthly count:** Incremented (line 249), consuming a free tier slot

**Assessment:** Correct and well-documented. The intentional design decision to always charge for bulk is noted in the NatSpec (line 229: "always paid").

### Payment Proofs

- **Storage:** `paymentProofs[user][channelId][messageIndex] = true`
- **Verification:** `hasValidPayment(user, channelId, messageIndex)` returns bool
- **Consumer:** Validator nodes call `hasValidPayment()` before relaying messages
- **Uniqueness:** Each `(user, channelId, messageIndex)` tuple is unique because `messageIndex` is derived from the monotonically increasing `userMessageIndex[user]`

**Assessment:** Sound mechanism. The per-user monotonic index prevents index collisions. A user cannot re-use a payment proof for a different message because each `payMessageFee()` call atomically increments the index and sets the proof. Validators can verify payment on-chain without trusting the user.

---

## Spam Prevention Analysis

### Attack: Free Tier Sybil

**Vector:** Create N addresses, each gets 20 free messages/month = 20N free messages.
**Cost:** Each address needs a separate transaction to `payMessageFee()`, which requires gas. On OmniCoin L1, gas is absorbed by validators, so the only cost is the ERC-2771 meta-tx overhead.
**Mitigation:** Validator-level rate limiting and KYC binding. The contract cannot prevent Sybil attacks, but the economic incentive is low (free chat messages have no monetary value to the attacker).
**Assessment:** Accepted design limitation. Same as Round 6 LOW-03.

### Attack: Bulk Fee Evasion

**Vector:** Send individual messages instead of using `payBulkMessageFee()` to avoid the 10x multiplier.
**Mitigation:** Validator nodes enforce the bulk/broadcast classification at the application layer. If a message is classified as bulk by the validator, it requires proof from `payBulkMessageFee()`. The contract only provides the payment mechanism; enforcement is at the validator level.
**Assessment:** Correct split of concerns. On-chain metering, off-chain enforcement.

### Attack: Payment Proof Front-running

**Vector:** Attacker observes a pending `payMessageFee()` transaction and front-runs it to claim the payment proof.
**Mitigation:** Payment proofs are bound to `_msgSender()` (line 195). A front-runner would get a proof under their own address, not the victim's. The victim's subsequent transaction would succeed normally with its own index.
**Assessment:** No vulnerability. Proofs are address-bound.

---

## ERC2771 Meta-Transaction Analysis

### Trusted Forwarder Configuration

- **Constructor parameter:** `trustedForwarder_` (line 166)
- **Can be `address(0)`:** Yes, which disables meta-transaction support
- **Immutable:** The forwarder address is baked into the ERC2771Context at deployment

### _msgSender() Resolution

All user-facing functions use `_msgSender()` (inherited from ERC2771Context) to identify the caller:
- `payMessageFee()` line 195: `address caller = _msgSender()`
- `payBulkMessageFee()` line 243: `address caller = _msgSender()`

The `setBaseFee()` function uses `onlyOwner`, which internally calls `_msgSender()` via the Ownable2Step inheritance chain, correctly resolving through ERC2771Context.

### Forwarder Trust Model

If a malicious forwarder is set at deployment, it could append arbitrary sender addresses to calldata, causing `_msgSender()` to return any address. This would allow:
1. Spending any user's XOM allowance via `payMessageFee()` (since `safeTransferFrom(caller, ...)` uses the forged `_msgSender()`)
2. Generating payment proofs under any user's address

**Mitigation:** The forwarder is immutable and set at deployment. The OmniForwarder contract inherits OpenZeppelin's ERC2771Forwarder with EIP-712 signature verification and nonce management. The forwarder itself is permissionless and cannot be upgraded.

**Assessment:** No vulnerability given a correctly deployed OmniForwarder. The trust assumption on the forwarder is standard for ERC-2771 contracts.

---

## Cross-Contract Integration Analysis

### OmniChatFee <-> UnifiedFeeVault

**Integration point:** `safeTransferFrom(user, feeVault, fee)` in `_collectFee()` (line 355)

The fee transfer does NOT go through UnifiedFeeVault's `deposit()` function. Instead, tokens are sent directly to the vault address via `safeTransferFrom`. This means:

1. The vault's `FeesDeposited` event is NOT emitted for chat fees.
2. The vault's `totalFeesCollected` counter is NOT incremented at deposit time.
3. The vault treats the incoming tokens as undistributed balance. They become distributable only when `distribute(xomToken)` is called by anyone.

**Is this correct?** Yes. The `distribute()` function in UnifiedFeeVault (line 720) calculates distributable amount as `balance - pendingBridge - totalPendingClaims`. Tokens arriving via direct transfer are automatically included in `balance` and will be distributed on the next `distribute()` call.

**Alternative path consideration:** UnifiedFeeVault has `notifyDeposit()` (line 690) specifically for contracts that send fees via direct transfer. OmniChatFee does not call `notifyDeposit()` after the transfer. This means off-chain indexers that rely solely on `FeesDeposited`/`FeesNotified` events may miss chat fee inflows.

**Assessment:** Functionally correct. The fees will be properly distributed. However, off-chain fee accounting/analytics may be incomplete. See I-01 below.

### OmniChatFee <-> OmniCoin (XOM Token)

**Requirement:** Users must approve OmniChatFee contract for `baseFee` (or 10x for bulk) before calling `payMessageFee()`.

**Safety:** `SafeERC20.safeTransferFrom` is used, which handles:
- Tokens that return `false` instead of reverting
- Tokens that return no data (non-standard ERC20)
- OmniCoin is a standard OpenZeppelin ERC20 -- both patterns are safe

**Assessment:** No issues.

### OmniChatFee <-> OmniForwarder

**Requirement:** If deployed with a non-zero `trustedForwarder_`, the forwarder can relay `payMessageFee()` and `payBulkMessageFee()` calls on behalf of users.

**Safety:** The ERC2771 override chain correctly resolves `_msgSender()` through ERC2771Context in all paths. The forwarder's nonce management prevents replay attacks.

**Assessment:** No issues.

---

## New Findings (Round 7)

### [L-01] No Upper Bound on baseFee Allows Effective DoS of Paid Chat

**Severity:** Low
**Location:** `setBaseFee()` (line 328)
**Prior Rounds:** Round 6 LOW-01 (re-evaluated)

```solidity
function setBaseFee(uint256 newBaseFee) external onlyOwner {
    if (newBaseFee == 0) revert ZeroBaseFee();
    uint256 oldFee = baseFee;
    baseFee = newBaseFee;
    emit BaseFeeUpdated(oldFee, newBaseFee);
}
```

The owner can set `baseFee` to any non-zero value up to `type(uint256).max`. Setting it to an extremely high value (e.g., `type(uint256).max / 10` or higher) would:
1. Make `payMessageFee()` revert for all paid messages (insufficient user balance/allowance)
2. Make `payBulkMessageFee()` revert due to overflow in `baseFee * BULK_FEE_MULTIPLIER` (Solidity 0.8 checked math)

The free tier (20 messages/month) would remain unaffected.

**Impact:** A compromised owner key could disable all paid chat messaging. Free tier messaging continues. No funds at risk since the contract holds no balance.

**Recommendation:** Add a `MAX_BASE_FEE` constant (e.g., 1e21 = 1000 XOM) and validate:
```solidity
uint256 public constant MAX_BASE_FEE = 1e21; // 1000 XOM
if (newBaseFee > MAX_BASE_FEE) revert ExcessiveBaseFee();
```

This also prevents the `baseFee * BULK_FEE_MULTIPLIER` overflow scenario.

### [L-02] MIN_FEE Floor in _collectFee Creates Silent Fee Increase

**Severity:** Low
**Location:** `_collectFee()` (line 352)

```solidity
function _collectFee(address user, uint256 fee) internal {
    if (fee < MIN_FEE) fee = MIN_FEE;
    xomToken.safeTransferFrom(user, feeVault, fee);
    totalFeesCollected += fee;
}
```

If the owner sets `baseFee` to a value below `MIN_FEE` (1e15), the contract silently charges `MIN_FEE` instead. This creates a discrepancy:
- `baseFee` is 5e14 (0.0005 XOM)
- User is actually charged 1e15 (0.001 XOM) -- 2x more than `baseFee` indicates
- The `MessageFeePaid` event emits `baseFee` (5e14) at line 221, not the actual charged amount (1e15)

The event's `fee` field (line 221: `baseFee`) would show the wrong amount compared to what was actually transferred.

**Impact:** Misleading event data for off-chain indexers and analytics. User is charged more than the emitted fee amount suggests. The discrepancy only occurs if `baseFee < MIN_FEE`, which is unlikely given `MIN_FEE == baseFee` at 1e15 in the current configuration.

**Recommendation:** Either:
1. Enforce `baseFee >= MIN_FEE` in `setBaseFee()` (preferred), or
2. Emit the actual charged amount instead of `baseFee` in events

```solidity
function setBaseFee(uint256 newBaseFee) external onlyOwner {
    if (newBaseFee == 0) revert ZeroBaseFee();
    if (newBaseFee < MIN_FEE) revert FeeBelowMinimum();
    ...
}
```

### [L-03] Bulk Message Fee Event Misleads When baseFee Changes Mid-Month

**Severity:** Low
**Location:** `payBulkMessageFee()` (lines 244, 253-259)

```solidity
uint256 fee = baseFee * BULK_FEE_MULTIPLIER;
// ...
emit MessageFeePaid(caller, channelId, msgIndex, fee, validator);
```

If the owner changes `baseFee` between two calls to `payBulkMessageFee()` within the same month, different users pay different fees for the same type of operation. This is expected behavior (fees are dynamic), but the lack of a timelock means the owner can change the fee in the same block as a user's transaction (front-running risk on chains with a mempool).

**Impact:** On OmniCoin L1 with Avalanche Snowman consensus and validators submitting transactions, front-running is not practical since validators are the only block producers and are incentivized to be honest. On other chains, this would be a higher-severity issue. **Low risk given the deployment target.**

**Recommendation:** For defense-in-depth, consider a minimum delay (e.g., 1 hour or next-block) for `setBaseFee()` changes. This is minor given the deployment environment.

### [I-01] Chat Fees Not Tracked by UnifiedFeeVault Event Trail

**Severity:** Informational
**Location:** `_collectFee()` (line 355)

The `safeTransferFrom(user, feeVault, fee)` transfer bypasses UnifiedFeeVault's `deposit()` function and does not trigger `notifyDeposit()`. Off-chain analytics systems that track fee inflows via `FeesDeposited` or `FeesNotified` events on the vault will not see chat fees until `distribute()` is called.

**Impact:** Incomplete real-time fee analytics. No functional impact -- fees are correctly distributed when `distribute()` is called.

**Recommendation:** After `safeTransferFrom`, call `IUnifiedFeeVault(feeVault).notifyDeposit(address(xomToken), fee)` to emit a tracking event on the vault. This requires OmniChatFee to have `DEPOSITOR_ROLE` on the vault, or the `notifyDeposit()` function to be made permissionless for existing token balances.

Alternatively, accept this as-is and have off-chain indexers also watch `OmniChatFee.MessageFeePaid` events.

### [I-02] Bulk Message Increments monthlyMessageCount Despite Always Being Paid

**Severity:** Informational
**Location:** `payBulkMessageFee()` (line 249)

```solidity
monthlyMessageCount[caller][month]++;
```

Bulk messages always charge the full 10x fee regardless of free tier status. However, they still increment `monthlyMessageCount`, which means a bulk message "uses up" a free tier slot. A user who sends 20 bulk messages (paying 10x for each) would have no free regular messages left.

This is documented as intentional in the NatSpec (Round 1 L-03 remediation). The rationale is that bulk messages should count toward the overall messaging activity metric. However, from a user perspective, it may be confusing that paying for bulk messages reduces their free regular message quota.

**Impact:** User experience confusion. No security impact.

**Recommendation:** Document this behavior in user-facing documentation. Consider separating the bulk counter from the free tier counter if the UX impact becomes a support burden.

### [I-03] totalFeesCollected Can Desynchronize from Actual Vault Receipts

**Severity:** Informational
**Location:** `_collectFee()` (line 357)

```solidity
totalFeesCollected += fee;
```

If `safeTransferFrom` at line 355 reverts (insufficient allowance, paused token, etc.), the entire transaction reverts and `totalFeesCollected` is not incremented. This is correct behavior. However, if the XOM token were a fee-on-transfer token, the vault would receive less than `fee` but `totalFeesCollected` would record the full `fee` amount.

**Impact:** None in practice. OmniCoin (XOM) is a standard ERC20 without fee-on-transfer mechanics. This is a hypothetical concern only.

**Recommendation:** No action needed. OmniCoin is controlled by the project and will not add fee-on-transfer.

### [I-04] Constructor Accepts address(0) for trustedForwarder Without Event

**Severity:** Informational
**Location:** Constructor (line 166)

```solidity
constructor(
    address _xomToken,
    address _feeVault,
    uint256 _baseFee,
    address trustedForwarder_
) Ownable(msg.sender) ERC2771Context(trustedForwarder_) {
```

The constructor validates `_xomToken` and `_feeVault` against `address(0)` but allows `trustedForwarder_` to be `address(0)` (which disables meta-transactions). This is intentional and documented (line 159: "address(0) to disable"). However, there is no event emitted indicating whether meta-transactions are enabled or disabled at deployment.

**Impact:** Deployment verification tools must check the constructor arguments from the deploy transaction rather than an event. Minor inconvenience.

**Recommendation:** No action needed. Constructor parameters are visible on block explorers.

---

## Edge Case Analysis

### Month Boundary Race Condition

**Scenario:** User sends message 19 at timestamp T (end of month M). The block containing message 20 is produced at timestamp T+1 (start of month M+1).

**Result:** Message 20 counts toward month M+1's quota. User gets 19 messages in month M and starts month M+1 with 19 free messages remaining. No double-counting or missed reset.

**Assessment:** Correct. The 30-day window calculation is deterministic per block timestamp.

### Concurrent Channel Usage

**Scenario:** User sends messages across channels C1, C2, C3 in the same block.

**Result:** Each message gets a unique `userMessageIndex` (0, 1, 2). Payment proofs are correctly scoped: `paymentProofs[user][C1][0]`, `paymentProofs[user][C2][1]`, `paymentProofs[user][C3][2]`. Free tier is shared across all channels (by design -- 20 total, not 20 per channel).

**Assessment:** Correct.

### Token Approval Exhaustion

**Scenario:** User approves exactly `baseFee * N` tokens. After `N` paid messages, the next `payMessageFee()` reverts.

**Result:** `safeTransferFrom` reverts with insufficient allowance. Transaction fails atomically -- no state changes. User must re-approve.

**Assessment:** Correct. No partial state corruption.

### Owner Renounces Ownership

**Scenario:** Owner calls `renounceOwnership()` (inherited from Ownable2Step).

**Result:** `baseFee` becomes permanently locked at its current value. No one can call `setBaseFee()`. The contract continues functioning normally with the frozen fee.

**Assessment:** Acceptable. Unlike contracts where ownership renunciation can trap funds, OmniChatFee holds no funds and the frozen fee is a valid operational state.

---

## Test Coverage Assessment

**Test suite:** `test/OmniChatFee.test.js` -- 45 tests, all passing (2 seconds)

| Category | Tests | Coverage |
|----------|-------|----------|
| Initialization | 7 | Constructor validation, constants, zero-address rejection |
| Free Tier | 6 | 20-message limit, event emission, no XOM charge, proof, index |
| Paid Messages | 6 | Fee charge, event, vault receipt, no contract balance, accounting, proof |
| Bulk Messages | 6 | 10x fee, no free tier, event, vault receipt, zero channelId, zero validator |
| Fee Distribution | 4 | Vault receives 100%, no contract retention, multi-message, exact deduction |
| Payment Proofs | 4 | True for paid, false for unpaid, wrong channel, wrong index |
| View Functions | 4 | Current month, zero index, zero channelId rejection, zero validator rejection |
| Admin Functions | 4 | setBaseFee, event, non-owner rejection, zero rejection |
| Edge Cases | 4 | Month boundary reset, independent user indices, validator-independent routing, multi-channel |

**Missing test coverage:**
1. No test for `MIN_FEE` floor behavior when `baseFee < MIN_FEE`
2. No test for ERC2771 meta-transaction path (deployed with `trustedForwarder_ = ZeroAddress`)
3. No test for `Ownable2Step` two-step transfer flow
4. No test for bulk message consuming free tier slot (I-02 scenario)
5. No integration test with actual UnifiedFeeVault contract

**Assessment:** Good functional coverage. The missing tests are primarily for edge cases and integration scenarios. The core fee metering and payment proof logic is well-tested.

---

## Role and Permission Map

```
                    ┌─────────────┐
                    │    Owner    │
                    │ (Ownable2Step)│
                    └──────┬──────┘
                           │
                    setBaseFee()
                    transferOwnership()
                    renounceOwnership()
                           │
    ┌──────────────────────┼──────────────────────┐
    │                      │                      │
    │ Any User             │ Any User             │ Validator
    │ payMessageFee()      │ payBulkMessageFee()  │ (event log only)
    │                      │                      │
    └──────────────────────┼──────────────────────┘
                           │
                    ┌──────▼──────┐
                    │  feeVault   │
                    │ (immutable) │
                    └─────────────┘
```

**Privileged Role Count:** 1 (Owner)
**Owner Power:** Can only change `baseFee`
**Attack Surface from Compromised Owner:** Disabling paid chat (setting extreme fee). No fund theft possible.

---

## Comparison with Prior Contract Version

| Aspect | Round 1 Version | Round 7 Version | Assessment |
|--------|-----------------|-----------------|------------|
| Fee distribution | In-contract 70/20/10 split | 100% to UnifiedFeeVault | Simplified, more secure |
| Recipient addresses | 3 mutable state vars | 1 immutable feeVault | Attack surface eliminated |
| Ownership | Ownable (single-step) | Ownable2Step | Safer ownership transfer |
| CEI compliance | Violated (M-01) | Compliant | Fixed |
| Zero fee prevention | Allowed | Rejected (ZeroBaseFee) | Fixed |
| Validator fee handling | Pull-based pendingValidatorFees | Event log only (no on-chain accumulation) | Simplified; validator paid by vault |
| Contract LOC | 385 | 425 | Slightly larger due to better NatSpec and MIN_FEE |

---

## Conclusion

OmniChatFee has reached mainnet-ready quality. All Medium and High findings from prior rounds have been properly remediated. The architectural simplification from Round 1 (moving fee distribution to UnifiedFeeVault) eliminated the most significant attack surfaces.

The three Low findings (unbounded baseFee, MIN_FEE event discrepancy, mid-block fee change) are minor operational concerns with minimal security impact given the deployment on OmniCoin L1 where validators are trusted block producers.

**Overall Risk Assessment: LOW**

### Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| L-01 | Low | No upper bound on baseFee allows effective DoS of paid chat | Recommend Fix |
| L-02 | Low | MIN_FEE floor creates silent fee increase and event mismatch | Recommend Fix |
| L-03 | Low | Bulk message fee can change mid-block (no timelock) | Accepted (low risk on L1) |
| I-01 | Info | Chat fees not tracked by UnifiedFeeVault event trail | Recommend notifyDeposit() |
| I-02 | Info | Bulk messages consume free tier slots despite always being paid | Documented / Accepted |
| I-03 | Info | totalFeesCollected may desync with fee-on-transfer tokens | Accepted (XOM is standard) |
| I-04 | Info | No event for trustedForwarder configuration at deployment | Accepted |

### Mainnet Deployment Checklist

- [x] All prior Medium findings remediated
- [x] CEI compliance verified in all state-changing functions
- [x] ReentrancyGuard on all external state-changing functions
- [x] SafeERC20 used for all token transfers
- [x] Ownable2Step for ownership management
- [x] ERC2771 diamond overrides correctly implemented
- [x] Immutable feeVault prevents post-deployment fee redirection
- [x] Zero-address validation on constructor parameters
- [x] Zero-fee prevention via ZeroBaseFee error
- [x] MIN_FEE floor prevents precision-loss rounding
- [x] All 45 tests passing
- [ ] Consider: Add MAX_BASE_FEE upper bound (L-01)
- [ ] Consider: Enforce baseFee >= MIN_FEE in setBaseFee() (L-02)
- [ ] Consider: Emit notifyDeposit() to feeVault for analytics (I-01)

---

*Generated by Claude Code Audit Agent v7 -- Round 7 Pre-Mainnet Final Review*
*Prior audit cross-references: Round 1 (2026-02-28), Round 6 (2026-03-10)*
