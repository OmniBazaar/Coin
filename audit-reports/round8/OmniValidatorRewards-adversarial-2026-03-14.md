# Adversarial Exploit Construction Review: OmniValidatorRewards

**Date:** 2026-03-14
**Reviewer:** Claude Code Adversarial Audit Agent (Round 8)
**Contract:** `Coin/contracts/OmniValidatorRewards.sol`
**Methodology:** Concrete exploit construction across 7 attack categories
**Scope:** OmniValidatorRewards.sol with cross-contract analysis of Bootstrap.sol and OmniCore.sol
**Prior Audit:** Round 7 (2026-03-13) -- 0 Critical, 1 High, 2 Medium, 3 Low, 4 Info
**VP Reference:** `Coin/audit-data/vulnerability-patterns.md`

---

## Viable Exploits Summary

| # | Category | Verdict | Severity | Exploitable? |
|---|----------|---------|----------|--------------|
| 1 | Bootstrap Sybil Dilution | **VIABLE** | High | Yes -- with conditions |
| 2 | Storage Gap Alignment V1/V2 | **VIABLE** | Medium | Yes -- silent corruption on next upgrade |
| 3 | Solvency Invariant | **DEFENDED** | -- | No |
| 4 | Epoch Processing Manipulation | **VIABLE (EDGE)** | Low-Medium | Yes -- batch staleness gaming |
| 5 | Double-Claiming | **DEFENDED** | -- | No |
| 6 | Cross-Contract isValidator() Spoofing | **VIABLE** | High | Yes -- same root cause as #1 |
| 7 | Block Reward Calculation Overflow | **DEFENDED** | -- | No |

---

## Category 1: Bootstrap Sybil Dilution

### Verdict: VIABLE

### Attack Surface Analysis

Bootstrap.sol's `registerNode()` (line 249) and `registerGatewayNode()` (line 285) are **permissionless**. The only guard against re-registration is the `banned` mapping (admin-set). There is no economic bond, deposit, or governance approval required to register a node.

OmniCore.sol's `isValidator()` (line 1057) falls back to Bootstrap.sol:

```solidity
// OmniCore.sol line 1060-1066
if (bootstrapContract != address(0)) {
    try IBootstrap(bootstrapContract).isNodeActive(validator)
        returns (bool isActive, uint8 nodeType)
    {
        return isActive && nodeType < 2;
    } catch { return false; }
}
```

OmniCore.sol's `getActiveNodes()` (line 1086) queries Bootstrap for **all** active gateway (type 0) and computation (type 1) nodes and returns them interleaved. This list is consumed directly by OmniValidatorRewards in `processEpoch()`.

### Concrete Exploit: Sybil Reward Dilution

**Precondition:** `minStakeForRewards == 0` (the V1 default; V2 reinitializer sets it to 1M XOM, but see bypass below).

**Step-by-step:**

1. Attacker creates 50 fresh Avalanche C-Chain addresses: `A1, A2, ..., A50`.

2. For each address `Ai`, attacker calls `Bootstrap.registerNode()`:
   ```
   registerNode(
       "",                    // multiaddr (not needed for type 1)
       "http://fake.ip:3001", // httpEndpoint (non-empty passes check)
       "",                    // wsEndpoint
       "US",                  // region
       1                      // nodeType = computation (bypasses gateway validation)
   )
   ```
   This costs only gas (no deposit/bond). All 50 calls succeed because `banned[Ai]` is false and `registeredNodes.length < MAX_NODES (1000)`.

3. Each `Ai` is now returned by `OmniCore.getActiveNodes()` because Bootstrap reports them as active type-1 nodes, and `nodeType < 2` passes the `isValidator()` check.

4. Each `Ai` calls `submitHeartbeat()`:
   - `omniCore.isValidator(Ai)` returns true (Bootstrap fallback).
   - `lastHeartbeat[Ai] = block.timestamp`, `lastHeartbeatEpoch[Ai] = getCurrentEpoch()`.

5. Any address calls `processEpoch(lastProcessedEpoch + 1)`.

6. In `_computeEpochWeights()`:
   - **With `minStakeForRewards == 0`:** The stake check at line 2141 is skipped entirely (`if (minStake > 0 && ...)` short-circuits to false). Sybil nodes earn weight based on participation score, heartbeat, and transaction count.
   - Sybil nodes have `pScore = 0` (no participation), `sComponent = 0` (no stake), but `hScore = 100` (active heartbeat) and potentially `txScore > 0` if BLOCKCHAIN_ROLE records transactions for them.
   - Activity component per Sybil: `(100 * 60 * 30) / 10000 = 18` weight points.
   - Legitimate validators with full participation might have ~100 weight points.
   - **50 Sybils at 18 weight each = 900 weight points** competing against legitimate validators.

7. Reward dilution: If there are 20 legitimate validators averaging 80 weight each (total = 1600), the 50 Sybils add 900 weight, making the total 2500. Legitimate validators' share drops from 100% to 1600/2500 = **64%** -- a **36% reward theft**.

**With `minStakeForRewards == 1M XOM` (V2 default):**

The stake check at line 2141-2156 fires:
```solidity
if (minStake > 0 && !stakeExempt[validators[i]]) {
    try omniCore.getStake(validators[i]) returns (IOmniCore.Stake memory s) {
        if (!s.active || s.amount < minStake) {
            unchecked { ++i; }
            continue; // SKIP -- no stake
        }
    } catch {
        unchecked { ++i; }
        continue; // SKIP -- call failed
    }
}
```

This **blocks** unstaked Sybil nodes from earning weight. The defense holds **if and only if**:
- `minStakeForRewards` is set to a meaningful value (>= 1M XOM), AND
- Sybil nodes do not have genuine OmniCore stakes, AND
- Sybil nodes are not in the `stakeExempt` mapping.

**Remaining bypass vectors:**

1. **`stakeExempt` mapping:** If admin adds Sybil addresses to `stakeExempt` (social engineering, compromised multisig), Sybils bypass the stake check entirely. The mapping has no cap on the number of exempt addresses.

2. **`minStakeForRewards` set to 0 by admin:** `setMinStakeForRewards(0)` reopens the attack. There is no lower bound enforced in the setter.

3. **Staked Sybils:** An attacker with 50M XOM can stake 1M in each of 50 OmniCore accounts and register 50 computation nodes. Each would pass both the `isValidator()` check and the `minStakeForRewards` check. The cost is 50M XOM locked (not lost), and the attacker earns a proportional share of every epoch's rewards indefinitely. This is an **economic attack** -- profitable if reward share exceeds opportunity cost of staking.

4. **Gateway bonus for staked Sybils:** In `_bootstrapRoleMultiplier()`, the R7 H-01 fix cross-checks OmniCore stake:
   ```solidity
   if (isActive && nodeType == 0) {
       try omniCore.getStake(validator) returns (IOmniCore.Stake memory s) {
           if (s.active && s.amount > 0) {
               return 15000; // 1.5x!
           }
       } catch { }
   }
   ```
   Note: The check is `s.amount > 0`, **not** `s.amount >= minStakeForRewards`. A Sybil gateway with just 1 wei of stake gets the 1.5x bonus. This check should use `minStakeForRewards` as the threshold, not 0.

### Impact

Without `minStakeForRewards > 0`: Up to ~36% reward dilution with 50 Sybil computation nodes (or more with up to 1000 total Bootstrap registrations, capped by `MAX_VALIDATORS_PER_EPOCH = 200`).

With `minStakeForRewards > 0` but gateway bonus bypass: Staked Sybil gateways earn 1.5x with only 1 wei of stake, unfairly amplifying their reward share relative to their economic commitment.

### Recommendations

1. **Critical:** In `_bootstrapRoleMultiplier()`, change `s.amount > 0` to `s.amount >= minStakeForRewards` to align the gateway bonus threshold with the reward eligibility threshold.

2. **Important:** Add a lower bound for `setMinStakeForRewards()` -- e.g., `require(amount == 0 || amount >= 100_000 ether, "min too low")` to prevent admin from accidentally weakening the defense.

3. **Important:** Add a cap on `stakeExempt` mappings or document a sunset schedule.

4. **Operational:** Bootstrap.sol should require a deposit bond for registration, or add admin/governance approval for new nodes.

---

## Category 2: Storage Gap Alignment V1/V2

### Verdict: VIABLE (Silent Corruption Risk on Future Upgrade)

### Storage Slot Enumeration

The contract's own storage variables occupy slots in declaration order (after OpenZeppelin base contract reservations). Let me enumerate each non-constant storage variable and its slot consumption:

**Scalar/Address/Bool/Struct slots (each uses 1 full slot unless packed):**

| Slot Offset | Variable | Type | Slots |
|-------------|----------|------|-------|
| 0 | `xomToken` | IERC20 (address) | 1 |
| 1 | `participation` | IOmniParticipation (address) | 1 |
| 2 | `omniCore` | IOmniCore (address) | 1 |
| 3 | `genesisTimestamp` | uint256 | 1 |
| 4 | `lastProcessedEpoch` | uint256 | 1 |
| 5 | `totalBlocksProduced` | uint256 | 1 |
| 6 | `accumulatedRewards` | mapping | 1 (header) |
| 7 | `totalClaimed` | mapping | 1 (header) |
| 8 | `lastHeartbeat` | mapping | 1 (header) |
| 9 | `transactionsProcessed` | mapping | 1 (header) |
| 10 | `epochTotalTransactions` | mapping | 1 (header) |
| 11 | `epochActiveValidators` | mapping | 1 (header) |
| 12-15 | `pendingContracts` | struct (3 addresses + 1 uint256) | 4 |
| 16 | `_ossified` | bool | 1 |
| 17 | `totalOutstandingRewards` | uint256 | 1 |
| 18-19 | `pendingUpgrade` | struct (1 address + 1 uint256) | 2 |
| 20 | `rewardMultiplier` | mapping | 1 (header) |
| 21 | `roleMultiplier` | mapping | 1 (header) |
| 22 | `_originalXomToken` | address | 1 |
| 23 | `penaltyExpiresAt` | mapping | 1 (header) |
| 24 | `__removed_epochTxnCount` | mapping | 1 (header) |
| 25 | `bootstrapContract` | address | 1 |
| 26 | `minStakeForRewards` | uint256 | 1 |
| 27 | `pendingAdmin` | address | 1 |
| 28 | `adminTransferEta` | uint256 | 1 |
| 29 | `stakeExempt` | mapping | 1 (header) |
| 30 | `adminTransferProposer` | address | 1 |
| 31 | `lastHeartbeatEpoch` | mapping | 1 (header) |
| 32 | `totalDistributed` | uint256 | 1 |
| 33-55 | `__gap[23]` | uint256[23] | 23 |

**Total slots consumed by this contract: 33 + 23 = 56.**

### The Problem: Comment vs. Reality

The contract comment (lines 499-502) states:

```solidity
/// @dev Storage gap for future upgrades.
///      Slots used: 25 explicit + mappings (11 slot headers).
///      Gap = 23 to leave headroom. Reduced by 2 for adminTransferProposer
///      and lastHeartbeatEpoch.
```

This claims **25 explicit + 11 mapping headers = 36 slots**. But the actual count (above) shows:

- **Non-mapping slots:** xomToken(1) + participation(1) + omniCore(1) + genesisTimestamp(1) + lastProcessedEpoch(1) + totalBlocksProduced(1) + pendingContracts(4) + _ossified(1) + totalOutstandingRewards(1) + pendingUpgrade(2) + _originalXomToken(1) + bootstrapContract(1) + minStakeForRewards(1) + pendingAdmin(1) + adminTransferEta(1) + adminTransferProposer(1) + totalDistributed(1) = **21 non-mapping slots**
- **Mapping slot headers:** accumulatedRewards, totalClaimed, lastHeartbeat, transactionsProcessed, epochTotalTransactions, epochActiveValidators, rewardMultiplier, roleMultiplier, penaltyExpiresAt, __removed_epochTxnCount, stakeExempt, lastHeartbeatEpoch = **12 mapping slot headers**
- **Total variable slots:** 21 + 12 = **33 slots**
- **With gap:** 33 + 23 = **56 total slots**

The comment says 25 + 11 = 36 slots, but the actual count is 21 + 12 = 33 slots. **The discrepancy is 3 slots.** The comment overcounts non-mapping slots by 4 and undercounts mappings by 1. (Possible: the comment counted the struct slots differently, or was not updated after the R7 `__removed_epochTxnCount` rename.)

### Why This Matters for UUPS Upgrades

In a UUPS proxy, the total layout (base contracts + derived contract) is fixed at deployment. If a V3 implementation adds new state variables, the developer will:

1. Read the `__gap` comment claiming 36 + 23 = 59 slots.
2. Assume they can shrink `__gap` by N and add N new variables.
3. But the actual layout is 33 + 23 = 56, not 36 + 23 = 59.

The **slot count is actually correct** if you simply count variables and gap, because the 23-slot gap was sized relative to the **actual** number of variables, not the comment. The comment is **inaccurate documentation** but the layout itself is valid.

However, there is a subtle danger: if a future developer trusts the comment's slot count (36) and calculates `total_used = 36 + 23 = 59`, then adds a variable while reducing gap to 22, they would believe the total is still 59. In reality, `total_used = 33 + 1 + 22 = 56`, which is consistent. **The layout remains correct despite the wrong comment** because the gap is mechanically correct -- it is an array of 23 slots, period.

**The real risk is if someone "corrects" the gap based on the erroneous comment.** If they believe the gap should be 25 (to make the comment's "25 explicit + 11 maps" add up with gap), they would reduce it by 2, corrupting the `totalDistributed` variable (which would overlap with what was previously gap slot 22) and shifting all subsequent state.

### Impact

Medium severity. The current contract is correctly laid out, but the **misleading comment creates risk for future V3 upgrades**. A developer relying on the comment to calculate gap adjustments could corrupt storage.

### Recommendation

1. **Fix the comment** to reflect the actual count: 21 explicit scalars/addresses/structs + 12 mapping headers = 33 variable slots + 23 gap = 56 total.
2. **Run `@openzeppelin/upgrades-core`'s storage layout tool** before any future upgrade to mechanically verify slot alignment.
3. **Add a V3 storage layout test** that asserts each variable's slot position matches expectations.

---

## Category 3: Solvency Invariant

### Verdict: DEFENDED

### Invariant Under Test

**Claim:** `totalOutstandingRewards + totalDistributed` should never exceed `TOTAL_VALIDATOR_POOL`, and `totalOutstandingRewards` should never exceed `xomToken.balanceOf(address(this))`.

### Attack Attempt: Inflate totalOutstandingRewards Beyond Balance

**Step 1:** Try to distribute more rewards than the contract holds.

In `_distributeRewards()` (line 2006-2018):
```solidity
uint256 contractBalance = xomToken.balanceOf(address(this));
uint256 availableForRewards = contractBalance;
if (availableForRewards > totalOutstandingRewards) {
    availableForRewards -= totalOutstandingRewards;
} else {
    availableForRewards = 0;
}
uint256 maxDistributable = poolRemaining < availableForRewards
    ? poolRemaining : availableForRewards;
```

The `availableForRewards` is `contractBalance - totalOutstandingRewards` (or 0 if that would underflow). Then `effectiveReward = min(epochReward, maxDistributable)`. So the reward distributed in any epoch is bounded by `contractBalance - totalOutstandingRewards`.

After distribution, `totalOutstandingRewards += epochDistributed` and `totalDistributed += epochDistributed`. The new `totalOutstandingRewards` is at most `contractBalance` (since `epochDistributed <= availableForRewards = contractBalance - old_totalOutstandingRewards`).

**Step 2:** Try to claim more than accumulated.

`claimRewards()` reads `amount = accumulatedRewards[caller]`, checks `balanceOf >= amount`, then zeroes `accumulatedRewards[caller]` and decrements `totalOutstandingRewards -= amount`. Since `amount` was added to `totalOutstandingRewards` during distribution, the subtraction cannot underflow (Solidity 0.8 reverts).

**Step 3:** Try to manipulate via reentrancy.

`claimRewards()` has `nonReentrant`, `processEpoch()` has `nonReentrant`. XOM is a standard ERC20 (SafeERC20.safeTransfer), not ERC777, so no callback hooks during transfer.

**Step 4:** Try to drain via `totalDistributed` exceeding `TOTAL_VALIDATOR_POOL`.

`poolRemaining = TOTAL_VALIDATOR_POOL - totalDistributed` (line 2001-2003). If `totalDistributed >= TOTAL_VALIDATOR_POOL`, `poolRemaining = 0`, so `maxDistributable = 0`, so `effectiveReward = 0`, and the function returns at line 2029 with nothing distributed. This is a hard cap.

### Conclusion

The three-layer solvency guard (pool cap + balance check + outstanding tracking) is correctly implemented. No exploit found. The invariant holds under all tested scenarios.

---

## Category 4: Epoch Processing Manipulation

### Verdict: VIABLE (Edge Case -- Batch Staleness Gaming)

### Attack Surface

`processEpoch()` and `processMultipleEpochs()` are **permissionless** (V2 change). Any address can call them. Sequential enforcement prevents double-processing. The question is whether an attacker can **time** epoch processing to maximize or minimize specific validators' rewards.

### Concrete Exploit: Batch Staleness Timing Attack

`processMultipleEpochs()` caches the validator list **once** at the top (line 1117-1118):
```solidity
address[] memory validators = omniCore.getActiveNodes();
```

Then processes up to 50 epochs using this **stale** list. The `_computeEpochWeights()` function also reads **current** `lastHeartbeatEpoch`, `rewardMultiplier`, `roleMultiplier`, `penaltyExpiresAt`, and calls `omniCore.getStake()` at **current** state for each validator in each epoch.

**Scenario:**

1. Validator Alice's penalty expires at timestamp T. Currently her `rewardMultiplier[Alice] = 10` (10% of normal).

2. An attacker (or Alice herself) waits until timestamp T + 1, then calls `processMultipleEpochs(50)`.

3. `_resetExpiredPenalties()` runs once at the top (line 1128), resetting Alice's `rewardMultiplier` to 0 (100%).

4. All 50 epochs are then processed with Alice at **full weight** (100%), even though her penalty was active during the earlier epochs in the batch.

**Impact:** Alice earns full rewards for up to 50 epochs (~100 seconds) that should have been penalized. At 15.602 XOM/epoch with 100% weight share, this is up to ~780 XOM per attack (approximately 50 epochs x 15.6 XOM). This is a small amount per instance but can be repeated every time a penalty expires.

**Mitigating factors:**
- The 100-second staleness window is small relative to the 30-day penalty duration.
- The penalty would have expired 100 seconds later anyway.
- The maximum gain is bounded by 50 epochs of penalty delta.
- This is "accepted behavior" per the Round 4 M-03 finding.

### Concrete Exploit: Heartbeat Race Condition

1. Attacker-validator has been offline for 1000 epochs (2000 seconds).
2. Attacker submits heartbeat at epoch E, setting `lastHeartbeatEpoch[attacker] = E`.
3. In the same block (or next block), attacker calls `processMultipleEpochs(50)` to process epochs `lastProcessedEpoch+1` through `lastProcessedEpoch+50`.
4. In `_computeEpochWeights()`, the epoch-based heartbeat check:
   ```solidity
   uint256 hbEpoch = lastHeartbeatEpoch[validators[i]];
   bool epochActive = hbEpoch > 0 && epoch <= hbEpoch + heartbeatEpochWindow;
   ```
   Only epochs within `[hbEpoch - heartbeatEpochWindow, hbEpoch + heartbeatEpochWindow]` pass. With `heartbeatEpochWindow = 10`, only the 10 most recent epochs (E-9 to E) qualify. The older 40 epochs in the batch are correctly excluded.

**Result:** The heartbeat check limits retroactive claiming to at most 10 epochs (20 seconds). This is correct behavior -- the defense holds for retroactive gaming beyond the heartbeat window.

### Conclusion

The batch staleness issue with penalty expiry is a **viable but low-impact edge case** (accepted in Round 4 M-03). The heartbeat anti-retroactive defense is correctly implemented and limits the window to 10 epochs.

---

## Category 5: Double-Claiming

### Verdict: DEFENDED

### Attack Attempt 1: Call claimRewards() Twice

```solidity
function claimRewards() external nonReentrant {
    address caller = _msgSender();
    uint256 amount = accumulatedRewards[caller];
    if (amount == 0) revert NoRewardsToClaim();
    // ...
    accumulatedRewards[caller] = 0;  // Zeroed before transfer
    totalClaimed[caller] += amount;
    totalOutstandingRewards -= amount;
    xomToken.safeTransfer(caller, amount);
}
```

Second call: `accumulatedRewards[caller]` is already 0, so `amount == 0` triggers `NoRewardsToClaim()` revert. Defense holds.

### Attack Attempt 2: Reentrancy via ERC20 Transfer Callback

XOM (OmniCoin.sol) is a standard ERC20. `safeTransfer` uses OpenZeppelin's SafeERC20 which calls `IERC20.transfer()`. Standard ERC20 transfer does not have callbacks. Even if the attacker deployed a malicious contract as the claimer, the `nonReentrant` modifier blocks re-entry.

### Attack Attempt 3: Process Same Epoch Twice

```solidity
if (epoch != lastProcessedEpoch + 1) {
    revert EpochNotSequential();
}
```

After processing epoch N, `lastProcessedEpoch = N`. Next call must process epoch N+1. Cannot replay epoch N.

### Attack Attempt 4: Front-run claimRewards with processEpoch to Double-Count

Both functions are `nonReentrant`, but they use **separate transactions**. If processEpoch adds to `accumulatedRewards[V]` and then V claims, that's normal operation. The accumulated amount is only distributed once per epoch per validator (in `_distributeRewards()`), and the claim zeroes the accumulator. No double-counting is possible.

### Attack Attempt 5: Meta-Transaction Replay via ERC-2771

`claimRewards()` uses `_msgSender()`, which resolves to the original signer when called through the trusted forwarder. The forwarder (OmniForwarder) is responsible for nonce tracking to prevent signature replay. If the forwarder is correctly implemented (standard ERC-2771 with nonce), replay is prevented. If the forwarder has a bug, that is a forwarder vulnerability, not a OmniValidatorRewards vulnerability.

### Conclusion

Double-claiming is comprehensively defended through: zeroing before transfer (CEI pattern), nonReentrant modifier, sequential epoch enforcement, and standard ERC20 (no callbacks).

---

## Category 6: Cross-Contract isValidator() Spoofing

### Verdict: VIABLE (Same Root Cause as Category 1)

### The Spoofing Chain

```
OmniValidatorRewards.submitHeartbeat()
    -> omniCore.isValidator(msg.sender)
        -> Bootstrap.isNodeActive(msg.sender)
            -> nodeRegistry[msg.sender].active
```

Any address that has called `Bootstrap.registerNode()` or `Bootstrap.registerGatewayNode()` will have `nodeRegistry[msg.sender].active = true`. This makes `isNodeActive()` return `(true, nodeType)`, which makes `isValidator()` return `true` (for nodeType 0 or 1), which allows `submitHeartbeat()` to succeed.

### Concrete Exploit: Bootstrap Self-Registration Affects Rewards

**Step-by-step:**

1. Attacker address `M` calls `Bootstrap.registerNode("", "http://x", "", "US", 1)`.
   - Cost: ~100K gas (~0.0025 AVAX at 25 gwei).
   - No deposit, no approval required.
   - `M` is now an active computation node in Bootstrap.

2. `M` calls `OmniValidatorRewards.submitHeartbeat()`.
   - `omniCore.isValidator(M)` returns true (Bootstrap fallback).
   - `lastHeartbeat[M] = block.timestamp`, `lastHeartbeatEpoch[M] = currentEpoch`.

3. Next `processEpoch()` call:
   - `omniCore.getActiveNodes()` includes `M` in the returned array.
   - In `_computeEpochWeights()`, `M` passes the heartbeat check.
   - **If `minStakeForRewards == 0`:** `M` gets weight 18 (heartbeat only) and earns proportional rewards.
   - **If `minStakeForRewards > 0`:** `M` is skipped due to insufficient stake (defense holds for reward distribution).

4. **However, `M` still counts toward `activeCount`** even though it gets 0 weight (when skipped by the stake check, it does NOT increment `activeCount` -- it `continue`s before that). Wait, let me re-verify...

Looking at the code flow in `_computeEpochWeights()`:
```solidity
if (epochActive) {
    if (minStake > 0 && !stakeExempt[validators[i]]) {
        try omniCore.getStake(validators[i]) returns (...) {
            if (!s.active || s.amount < minStake) {
                unchecked { ++i; }
                continue;  // SKIP -- does NOT reach ++activeCount
            }
        } catch {
            unchecked { ++i; }
            continue;  // SKIP -- does NOT reach ++activeCount
        }
    }
    // ... weight calculation ...
    weights[i] = baseWeight;
    totalWeight += weights[i];
    ++activeCount;  // Only reached if all checks pass
}
```

**Correction:** When `minStakeForRewards > 0`, Sybil nodes with no stake are skipped before `++activeCount`. They do NOT affect `totalWeight` or `activeCount`. The defense is **complete** for reward distribution when `minStakeForRewards > 0`.

### Remaining Impact (with `minStakeForRewards > 0`)

Even though Sybil nodes cannot earn rewards, they can still:

1. **Submit heartbeats** -- pollutes `lastHeartbeat` and `lastHeartbeatEpoch` mappings with useless data (storage bloat, minor gas cost to the attacker).

2. **Appear in `getActiveNodes()` return array** -- increases gas cost of `processEpoch()` because the loop iterates over them before skipping (external call to `omniCore.getStake()` per Sybil per epoch).

3. **Trigger `MAX_VALIDATORS_PER_EPOCH` cap** -- if 200+ Sybils register, they fill the first 200 slots of the interleaved array, potentially **excluding legitimate validators** beyond index 200. This is a **denial-of-service against legitimate validators' rewards**.

### Concrete DoS Exploit: Validator Exclusion via Registration Flooding

1. Attacker registers 150 computation nodes in Bootstrap (interleaved with gateways).
2. If there are 100 legitimate gateways and 150 Sybil computation nodes, `getActiveNodes()` returns an interleaved array of ~250 entries: [g0, s0, g1, s1, ...].
3. `_computeEpochWeights()` processes only the first `MAX_VALIDATORS_PER_EPOCH = 200` entries.
4. Due to interleaving, approximately 100 gateways and 100 Sybils are in the first 200 slots. The remaining 50 Sybils are excluded.
5. **All 100 Sybils are skipped** (no stake), so they don't earn rewards.
6. But they **consumed 100 of the 200 processing slots**, meaning if there were legitimate validators beyond index 200, those validators are excluded from rewards for that epoch.

With more aggressive flooding (1000 registrations, the MAX_NODES cap), an attacker can ensure the first 200 interleaved entries are dominated by Sybils, pushing many legitimate validators past the cap.

### Impact

High severity for the DoS vector: an attacker spending only gas (no economic commitment) can exclude legitimate validators from reward distribution by filling Bootstrap's registry with fake nodes that consume processing slots.

### Recommendations

1. **Critical:** Bootstrap.sol must require an economic bond (deposit) for node registration, or add admin/governance approval.
2. **Important:** `getActiveNodes()` should filter by stake requirement before returning, so unstaked nodes never reach the processing pipeline.
3. **Alternative:** Move the `minStakeForRewards` check from `_computeEpochWeights()` to `getActiveNodes()` in OmniCore, so the returned array only contains economically-committed validators.

---

## Category 7: Block Reward Calculation Overflow

### Verdict: DEFENDED

### Overflow Analysis

**`calculateBlockRewardForEpoch()` (line 1875-1896):**

```solidity
uint256 reward = INITIAL_BLOCK_REWARD; // 15_602_000_000_000_000_000 = 1.56e19
for (uint256 i = 0; i < reductions;) {
    reward = (reward * REDUCTION_FACTOR) / REDUCTION_DENOMINATOR;
    // = (reward * 99) / 100
    unchecked { ++i; }
}
```

- Maximum `reductions` is 99 (capped by `MAX_REDUCTIONS - 1`).
- Each iteration: `reward * 99` at most = `1.56e19 * 99 = 1.544e21`. This is far below `type(uint256).max = 1.16e77`. No overflow.
- The `reward` value only decreases (multiplied by 99/100 each iteration), so subsequent iterations are always smaller.

**`_distributeRewards()` weight calculation (line 2035-2037):**

```solidity
uint256 validatorReward = (effectiveReward * weights[i]) / totalWeight;
```

- `effectiveReward` is at most `INITIAL_BLOCK_REWARD = 1.56e19`.
- `weights[i]` is at most ~150 (100 base + 50% role bonus from 1.5x multiplier on 100-weight validator).
- `effectiveReward * weights[i]` = `1.56e19 * 150 = 2.34e21`. Far below uint256 max.
- `totalWeight` is at least 1 (otherwise `_distributeRewards` returns early).

**`totalDistributed` accumulation:**

- `totalDistributed` accumulates `epochDistributed` each epoch.
- Maximum `epochDistributed` per epoch = `INITIAL_BLOCK_REWARD = 1.56e19`.
- Over 40 years at 2-second epochs: `631,152,000 * 1.56e19 = 9.85e27`. This is about `9.85e9 ether`, well within uint256.
- The solvency guard caps `totalDistributed` at `TOTAL_VALIDATOR_POOL = 6.089e27`, which is even smaller.

**`_calculateActivityComponent()` numerator:**

```solidity
uint256 numerator = (hScore * HEARTBEAT_SUBWEIGHT * ACTIVITY_WEIGHT)
    + (txScore * TX_PROCESSING_SUBWEIGHT * ACTIVITY_WEIGHT);
// = (100 * 60 * 30) + (100 * 40 * 30) = 180000 + 120000 = 300000
```

Maximum numerator = 300,000. No overflow.

**Extreme epoch duration test:**

If an epoch is never processed for years and then `processMultipleEpochs(50)` is called:
- `calculateBlockRewardForEpoch(very_large_epoch)` computes `reductions = epoch / 6_311_520`.
- If `reductions >= 100`, returns 0. No overflow, just zero reward.
- If `reductions < 100`, the loop runs up to 99 iterations -- gas intensive but bounded and no overflow.

### Edge Case: Loop Gas in calculateBlockRewardForEpoch

If `epoch` is just under `MAX_REDUCTIONS * BLOCKS_PER_REDUCTION` (e.g., epoch 625,000,000), then `reductions = 99`, and the loop runs 99 iterations. Each iteration is 2 MUL + 1 DIV = ~20 gas. Total: ~2000 gas for the loop. This is called per-epoch in `processMultipleEpochs`, so 50 * 2000 = 100,000 gas for the reward calculation portion -- negligible.

### Conclusion

All arithmetic paths are safely within uint256 bounds. Solidity 0.8.24's built-in overflow checks protect all operations outside `unchecked` blocks. The only `unchecked` blocks contain loop counter increments that are bounded by loop conditions.

---

## Investigated-But-Defended Categories Summary

| Category | Why Defense Holds |
|----------|------------------|
| **Solvency (Cat 3)** | Three-layer guard: pool cap (`TOTAL_VALIDATOR_POOL`), balance check (`contractBalance - totalOutstandingRewards`), and minimum-of-both. Cannot distribute more than available. CEI pattern in `claimRewards()` with `nonReentrant`. |
| **Double-Claiming (Cat 5)** | `accumulatedRewards` zeroed atomically before transfer. `nonReentrant` blocks reentrancy. Sequential epoch enforcement prevents replay. Standard ERC20 has no transfer callbacks. |
| **Overflow (Cat 7)** | Maximum intermediate value `effectiveReward * weights[i]` = ~2.34e21, far below uint256 max. `totalDistributed` capped at 6.089e27. All `unchecked` blocks contain only loop counter increments bounded by loop conditions. Solidity 0.8.24 built-in overflow protection on all other arithmetic. |

---

## Recommendations Summary

| # | Severity | Finding | Category | Recommendation |
|---|----------|---------|----------|----------------|
| 1 | **High** | Staked Sybil gateways get 1.5x bonus with only 1 wei of stake | Cat 1, Cat 6 | Change `_bootstrapRoleMultiplier()` check from `s.amount > 0` to `s.amount >= minStakeForRewards` |
| 2 | **High** | Bootstrap registration flooding can exclude legitimate validators from the 200-validator processing cap | Cat 6 | Require economic bond in Bootstrap, or filter by stake in `getActiveNodes()` |
| 3 | **Medium** | Storage gap comment incorrect (claims 36 slots, actual is 33) | Cat 2 | Fix comment to reflect actual slot count; run OZ storage layout tool before V3 upgrade |
| 4 | **Low** | `setMinStakeForRewards()` has no lower bound, admin can set to 0 reopening Sybil vector | Cat 1 | Add `require(amount == 0 || amount >= MIN_STAKE_FLOOR)` |
| 5 | **Low** | Batch staleness allows penalty-expiry gaming for ~50 epochs | Cat 4 | Accepted (Round 4 M-03); document in deployment guide |
| 6 | **Info** | `stakeExempt` mapping has no cap or sunset mechanism | Cat 1 | Document planned removal schedule |

---

## Cross-Reference to Vulnerability Patterns

| VP Pattern | Applicability | Status |
|------------|--------------|--------|
| VP-06 (Missing Access Control) | `processEpoch` permissionless by design | Sequential enforcement prevents abuse |
| VP-09 (Unprotected Initializer) | `_disableInitializers()` in constructor | SAFE |
| VP-12 (Integer Overflow) | Solidity 0.8.24 built-in; `unchecked` only on bounded counters | SAFE |
| VP-13 (Precision Loss) | `(effectiveReward * weights[i]) / totalWeight` -- multiply before divide | SAFE (rounding dust accepted) |
| VP-26 (Unchecked ERC20 Transfer) | Uses `SafeERC20.safeTransfer()` | SAFE |
| VP-29 (Unbounded Loop) | Capped at `MAX_VALIDATORS_PER_EPOCH = 200` and `MAX_BATCH_EPOCHS = 50` | SAFE |
| VP-39 (Storage Collision) | Gap present but comment inaccurate | See Cat 2 |
| VP-43 (Storage Layout Violation) | `__removed_epochTxnCount` preserves layout | SAFE (current version) |
| VP-44 (Missing Reinitializer Guard) | Uses `reinitializer(2)` correctly | SAFE |

---

## Conclusion

The OmniValidatorRewards contract has been significantly hardened through 7 prior audit rounds. The solvency invariant, double-claiming prevention, and overflow protections are all correctly implemented and withstood adversarial construction attempts.

The primary remaining risk is the **Bootstrap Sybil/DoS vector** (Categories 1 and 6), which has two dimensions:

1. **Reward dilution** (when `minStakeForRewards == 0`) -- mitigated by the V2 default of 1M XOM, but re-openable by admin.
2. **Validator exclusion DoS** (when `minStakeForRewards > 0`) -- Sybil nodes consume processing slots in the 200-cap without earning rewards, potentially pushing legitimate validators past the cap. This is **not mitigated by `minStakeForRewards`** because the stake check happens *after* the validator is included in the processing loop.

A secondary finding is the **gateway bonus threshold mismatch**: `_bootstrapRoleMultiplier()` grants 1.5x with only `s.amount > 0` (1 wei), while the reward eligibility check requires `s.amount >= minStakeForRewards` (1M XOM). This allows staked Sybil gateways to earn amplified rewards with minimal economic commitment.

The storage gap documentation discrepancy is a latent risk for future upgrades but does not affect the current deployment.

**Overall Adversarial Risk Rating: 5/10** (pre-Bootstrap hardening). Drops to **2/10** once Bootstrap registration requires economic commitment and `getActiveNodes()` pre-filters by stake.

---

*Report generated: 2026-03-14*
*Reviewer: Claude Code Adversarial Audit Agent (Round 8)*
*Contract: OmniValidatorRewards.sol (2,541 lines, Solidity 0.8.24)*
*Methodology: Concrete exploit construction with cross-contract analysis*
*Prior audit: Round 7 (2026-03-13) -- all findings verified*
