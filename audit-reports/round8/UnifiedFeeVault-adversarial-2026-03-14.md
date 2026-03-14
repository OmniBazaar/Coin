# Adversarial Security Review: UnifiedFeeVault.sol (Round 8)

**Date:** 2026-03-14
**Reviewer:** Claude Code Adversarial Audit Agent (Opus 4.6)
**Contract:** `Coin/contracts/UnifiedFeeVault.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 1,696
**Review Type:** Concrete exploit construction across 7 attack categories
**Prior Audit:** Round 7 (2026-03-13) -- 0 Critical, 0 High, 1 Medium, 3 Low, 4 Informational

---

## Executive Summary

This review attempted to construct concrete, step-by-step exploit scenarios across 7 adversarial categories targeting UnifiedFeeVault.sol. After exhaustive analysis of the contract source (1,696 lines), the IFeeSwapRouter interface, the OmniPrivacyBridge conversion flow, the MinimalEscrow fee path, and the DEXSettlement fee path, the findings are:

- **1 Viable Exploit (Medium):** Swap router approval residual -- the `forceApprove` pattern in `swapAndBridge()` can leave a dangling approval if the swap router returns less than the approved amount, allowing a malicious (timelocked) swap router to drain residual approved tokens.
- **1 Viable Exploit (Medium):** Claim redirect used as extraction vector -- `redirectStuckClaim` lacks a timelock and can redirect any quarantined claim to an arbitrary address, including claims not yet claimed by legitimate marketplace participants (referrers, listing nodes, selling nodes).
- **5 Investigated-but-Defended Categories** where the contract's existing defenses hold.

**Overall Assessment:** The contract is well-hardened after 7 prior audit rounds. The two medium findings represent realistic but constrained attack surfaces requiring a compromised admin key in both cases. No critical or high-severity exploits were constructible.

---

## Viable Exploits Table

| # | Attack Name | Severity | Attacker Profile | Confidence | Impact |
|---|------------|----------|-----------------|------------|--------|
| E-01 | Swap Router Approval Residual Drain | Medium | Compromised ADMIN_ROLE (48h timelock bypass via social engineering or key theft) | High | Loss of fee tokens up to residual approval amount per `swapAndBridge()` call |
| E-02 | Admin Redirect of Active Marketplace Claims | Medium | Compromised DEFAULT_ADMIN_ROLE | High | Theft of referrer, listing node, and selling node claimable fees |

---

## E-01: Swap Router Approval Residual Drain

**Severity:** Medium
**VP References:** VP-34 (Front-Running / Transaction Ordering), VP-49 (Approval Race Condition)
**Attacker Profile:** Compromised ADMIN_ROLE key holder who can survive the 48h timelock window
**Confidence:** High -- the code path is verified

### Vulnerable Code

```solidity
// UnifiedFeeVault.sol, lines 1359-1383 (swapAndBridge)
IERC20(token).forceApprove(swapRouter, amount);    // line 1360

uint256 xomBefore =
    IERC20(xomToken).balanceOf(address(this));

IFeeSwapRouter(swapRouter).swapExactInput(          // line 1365
    token, xomToken, amount, minXOMOut,
    address(this), deadline
);

uint256 xomReceived =
    IERC20(xomToken).balanceOf(address(this)) - xomBefore;

if (xomReceived < minXOMOut) {                       // line 1373
    revert InsufficientSwapOutput(xomReceived, minXOMOut);
}

IERC20(xomToken).safeTransfer(bridgeReceiver, xomReceived);  // line 1378
```

### Step-by-Step Exploit

1. **Attacker compromises ADMIN_ROLE** (via key theft, phishing, or insider threat).

2. **Attacker calls `proposeSwapRouter(maliciousRouter)`** (line 1184). The 48-hour timelock starts. The `SwapRouterProposed` event is emitted, giving watchers 48 hours to intervene.

3. **After 48 hours**, attacker calls `applySwapRouter()` (line 1204). The swap router is now set to the attacker-controlled `maliciousRouter`.

4. **Attacker calls `swapAndBridge(USDC, 1000e6, 0, attackerAddr, farFutureDeadline)`** using the BRIDGE_ROLE (which the compromised admin may also control, or could grant to themselves).

5. **The vault calls `IERC20(USDC).forceApprove(maliciousRouter, 1000e6)`** at line 1360. This sets the USDC approval for `maliciousRouter` to 1,000 USDC.

6. **`maliciousRouter.swapExactInput()` is called.** The malicious implementation does the following:
   - Pulls only 500 USDC from the vault (not the full 1000).
   - Sends back 1 XOM to the vault (satisfying `minXOMOut = 0`).
   - Returns normally.

7. **The vault checks `xomReceived >= minXOMOut`.** Since `minXOMOut = 0` and 1 XOM was received, the check passes.

8. **The vault's USDC approval to `maliciousRouter` still has 500 USDC remaining** (forceApprove set 1000, router only pulled 500).

9. **In a separate transaction**, the attacker calls `maliciousRouter.drainResidual()` which calls `IERC20(USDC).transferFrom(vault, attacker, 500e6)` using the residual approval. This succeeds because the vault still has USDC balance and the approval is still active.

10. **The 500 USDC is stolen.** The vault's internal accounting (`pendingBridge[USDC]`) was already decremented by 1000 at step 5, so the vault now has an accounting deficit. Future `distribute()` calls may underflow or produce incorrect distributions.

### Why This Works

- `forceApprove` (OZ `SafeERC20`) sets approval to `amount` regardless of current approval, but it does NOT reset to 0 after the swap completes.
- The IFeeSwapRouter interface `swapExactInput` is expected to pull `amountIn` tokens, but the vault does NOT verify that the router actually consumed the full approved amount.
- The vault uses balance-before/after for XOM output verification but NOT for input token consumption verification.
- If the attacker sets `minXOMOut = 0`, the output check is effectively bypassed.

### Mitigating Factors

- Requires compromised ADMIN_ROLE AND BRIDGE_ROLE (or the ability to grant BRIDGE_ROLE).
- The 48-hour timelock on swap router changes provides an observation window.
- The BRIDGE_ROLE holder sets `minXOMOut`, so a legitimate bot would set a reasonable value, making the attack economically unprofitable for small residuals.
- In practice, `forceApprove` is commonly used in DeFi and the residual is typically zero if the router is honest.

### Recommendation

After each `swapAndBridge()` or `convertPXOMAndBridge()` call, reset the approval to zero:

```solidity
// After the swap interaction block (after line 1375):
IERC20(token).forceApprove(swapRouter, 0);
```

Similarly for `convertPXOMAndBridge()` (after line 1427):
```solidity
IERC20(pxomToken).forceApprove(privacyBridge, 0);
```

This is a defense-in-depth measure. The cost is ~5,000 gas per SSTORE to zero out the approval slot.

---

## E-02: Admin Redirect of Active Marketplace Claims

**Severity:** Medium
**VP References:** VP-06 (Access Control), VP-57 (recoverERC20 Backdoor)
**Attacker Profile:** Compromised DEFAULT_ADMIN_ROLE
**Confidence:** High -- the code path is verified, no timelock protection

### Vulnerable Code

```solidity
// UnifiedFeeVault.sol, lines 1503-1520 (redirectStuckClaim)
function redirectStuckClaim(
    address originalClaimant,
    address newRecipient,
    address token
) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (newRecipient == address(0)) revert ZeroAddress();

    uint256 amount =
        pendingClaims[originalClaimant][token];
    if (amount == 0) revert NoPendingClaim();

    pendingClaims[originalClaimant][token] = 0;
    pendingClaims[newRecipient][token] += amount;

    emit ClaimRedirected(
        originalClaimant, newRecipient, token, amount
    );
}
```

### Step-by-Step Exploit

1. **Context:** After `depositMarketplaceFee()` is called (line 819), referrers, listing nodes, and selling nodes receive claimable amounts in `pendingClaims`. For example, with a 1,000,000 XOM sale:
   - `pendingClaims[referrer][XOM] += 1,750 XOM` (70% of 0.25% referral fee)
   - `pendingClaims[listingNode][XOM] += 1,750 XOM` (70% of 0.25% listing fee)
   - `pendingClaims[sellingNode][XOM] += 500 XOM` (20% of 0.25% listing fee)

2. **Attacker compromises DEFAULT_ADMIN_ROLE.**

3. **Attacker calls `redirectStuckClaim(referrer, attackerAddress, XOM)`**. This immediately moves 1,750 XOM from the referrer's claimable balance to the attacker's claimable balance.

4. **Attacker calls `redirectStuckClaim(listingNode, attackerAddress, XOM)`**. Another 1,750 XOM redirected.

5. **Attacker calls `redirectStuckClaim(sellingNode, attackerAddress, XOM)`**. Another 500 XOM redirected.

6. **Attacker calls `claimPending(XOM)`** to withdraw all 4,000 XOM.

7. **The legitimate referrer, listing node, and selling node now have zero claimable balances.** When they attempt `claimPending()`, they receive `NothingToClaim()`.

### Why This Works

- `redirectStuckClaim` has NO timelock. It executes instantly upon call.
- It requires only `DEFAULT_ADMIN_ROLE`, with no secondary confirmation or delay.
- It was designed for the legitimate case of USDC-blacklisted addresses, but it provides a general-purpose claim theft vector.
- Unlike `rescueToken()` which checks committed funds, `redirectStuckClaim` operates within the committed claims themselves.
- The function is callable even when paused (intentional design per Round 6 L-01 acceptance), so pausing the contract does not prevent this attack.

### Mitigating Factors

- Requires compromised DEFAULT_ADMIN_ROLE (the highest privilege role).
- All redirections emit `ClaimRedirected` events, creating an on-chain audit trail.
- If DEFAULT_ADMIN_ROLE is behind a multi-sig + TimelockController (recommended operational deployment), a single compromised key cannot execute this instantly.
- The intended use case (rescuing USDC-blacklisted claims) is legitimate.

### Recommendation

1. **Add a 48-hour timelock** to `redirectStuckClaim()` using a propose/apply pattern, consistent with all other admin configuration changes:

```solidity
function proposeClaimRedirect(
    address originalClaimant,
    address newRecipient,
    address token
) external onlyRole(DEFAULT_ADMIN_ROLE) { ... }

function applyClaimRedirect() external onlyRole(DEFAULT_ADMIN_ROLE) { ... }
```

2. Alternatively, require that `originalClaimant` has demonstrably failed to claim (e.g., has a `claimPending()` revert history) before allowing redirect. This is harder to enforce on-chain but could be approximated by requiring the claim to have existed for a minimum duration (e.g., 30 days).

---

## Investigated-but-Defended Categories

### Category 1: Quarantine Escape via Redirect

**Attack Hypothesis:** Can quarantined tokens (failed push transfers in `_safePushOrQuarantine`) be extracted through fee recipient changes or `rescueToken()`?

**Investigation:**

1. **Recipient change + claim:** If `stakingPool` reverts on push, the amount goes to `pendingClaims[stakingPool][token]`. The admin then calls `proposeRecipients(newStakingPool, ...)` and `applyRecipients()` after 48h. Now `stakingPool` state variable points to `newStakingPool`. But `pendingClaims[oldStakingPool][token]` still holds the quarantined amount. The old staking pool address must call `claimPending()` to retrieve it. If the old staking pool is a contract that cannot call `claimPending()`, the funds are stuck -- but `redirectStuckClaim()` can redirect them (see E-02 above for the risk this poses).

2. **`rescueToken()` extraction:** The admin calls `rescueToken(token, amount, adminAddr)`. The function computes:
   ```solidity
   uint256 committed = pendingBridge[token] + totalPendingClaims[token];
   if (vaultBalance < committed + amount) revert CannotRescueCommittedFunds(token, committed);
   ```
   The quarantined claims are included in `totalPendingClaims[token]`, so they cannot be rescued. **Defense holds.**

3. **Double-distribution after claim:** As analyzed in Round 7 M-01, when `claimPending()` is called, it decrements both the vault's token balance and `totalPendingClaims[token]`, keeping the `distributable = balance - pendingBridge - totalPendingClaims` calculation sound. **Defense holds.**

**Verdict: DEFENDED** -- Quarantined tokens are properly tracked in `totalPendingClaims` and excluded from both `rescueToken()` and `distribute()`. The only extraction path is `redirectStuckClaim()` (see E-02).

---

### Category 2: Swap Approval Patterns

**Attack Hypothesis:** Does the vault approve tokens to external contracts in a way that can be exploited?

**Investigation:**

Two approval sites exist:

1. **`swapAndBridge()` line 1360:** `IERC20(token).forceApprove(swapRouter, amount)`
2. **`convertPXOMAndBridge()` line 1413:** `IERC20(pxomToken).forceApprove(privacyBridge, amount)`

Both use `forceApprove` (OpenZeppelin SafeERC20), which sets the approval to `amount` in a single call, avoiding the approve-race condition (VP-49). However, the approval is never reset to zero after the interaction. See **E-01** for the viable exploit.

The `deposit()` and `depositMarketplaceFee()` functions use `safeTransferFrom()` to pull tokens INTO the vault -- no approval is granted TO any external contract. **No vulnerability.**

The `_safePushOrQuarantine()` function uses a low-level `call` with `IERC20.transfer.selector`, which does NOT require prior approval (it transfers FROM the vault, not TO the vault). **No vulnerability.**

**Verdict: PARTIAL VULNERABILITY** -- See E-01 for the residual approval exploit. All other approval patterns are safe.

---

### Category 3: pXOM Bridge Reentrancy

**Attack Hypothesis:** Can the privacy conversion path be re-entered via token callbacks during `convertPXOMAndBridge()`?

**Investigation:**

The `convertPXOMAndBridge()` execution flow (lines 1396-1434):

1. `nonReentrant` modifier is applied.
2. `_validatePXOMBridge()` checks balances and addresses.
3. **Effects:** `pendingBridge[pxomToken] -= amount; totalBridged[pxomToken] += amount;` (state updated BEFORE external calls).
4. **Interaction 1:** `IERC20(pxomToken).forceApprove(privacyBridge, amount)` -- sets approval, no callback risk.
5. **Interaction 2:** `IOmniPrivacyBridge(privacyBridge).convertPXOMtoXOM(amount)` -- this calls into the privacy bridge.

Inside `OmniPrivacyBridge.convertPXOMtoXOM()` (lines 378-409):
- It has its own `nonReentrant` modifier.
- It calls `privateOmniCoin.burnFrom(caller, amount)` where caller = the vault.
- It calls `omniCoin.safeTransfer(caller, amount)` where caller = the vault.

**Reentrancy via `burnFrom`:** The `burnFrom` function on PrivateOmniCoin (an ERC20) decrements the allowance and balance. Standard ERC20 `burn` does not trigger any callbacks (no ERC777 hooks). OmniCoin/PrivateOmniCoin are standard ERC20 tokens (confirmed by project documentation: "OmniCoin (XOM) is the primary token and does not have these features"). **No callback vector.**

**Reentrancy via `safeTransfer` to vault:** The privacy bridge transfers XOM to the vault (msg.sender = vault). The vault is a contract, but it has no `receive()`, `fallback()`, or `tokensReceived()` hook. `safeTransfer` for ERC20 does not trigger `onERC721Received`-style callbacks -- it is a plain ERC20 transfer. **No callback vector.**

**Reentrancy via malicious privacy bridge:** If a compromised admin replaces `privacyBridge` with a malicious contract (after 48h timelock), the malicious `convertPXOMtoXOM()` could attempt to re-enter the vault. However, the `nonReentrant` modifier on `convertPXOMAndBridge()` prevents any re-entry into any `nonReentrant`-guarded function on the vault. The malicious bridge could:
- Call `distribute()` -- blocked by `nonReentrant`.
- Call `claimPending()` -- blocked by `nonReentrant`.
- Call `deposit()` -- blocked by `nonReentrant`.
- Call `bridgeToTreasury()` -- blocked by `nonReentrant`.
- Call `swapAndBridge()` -- blocked by `nonReentrant`.

The only functions NOT guarded by `nonReentrant` are:
- `notifyDeposit()` -- requires `DEPOSITOR_ROLE`, emits event only, no state impact.
- `proposeRecipients()` and other propose/apply functions -- require `ADMIN_ROLE`.
- `pause()`/`unpause()` -- require `ADMIN_ROLE`.
- `redirectStuckClaim()` -- requires `DEFAULT_ADMIN_ROLE`.
- View functions -- read-only.

Even if the malicious bridge calls `redirectStuckClaim()` (which has no `nonReentrant`), it would need `DEFAULT_ADMIN_ROLE`, which the bridge contract does not have.

**Read-only reentrancy (VP-04):** The vault's view functions (`undistributed`, `pendingForBridge`, `getClaimable`) could return temporarily inconsistent values during the callback. However, `pendingBridge[pxomToken]` was already decremented (line 1409) before the external call, so the view functions would show the post-decrement state. The XOM balance has not yet increased (the bridge transfer happens during the callback). If an external contract reads `undistributed(xomToken)` during the callback, it would see a lower balance than expected. This is inconsistent but does NOT create an exploitable path because:
- `distribute()` is blocked by `nonReentrant`.
- No other contract uses the vault's view functions for on-chain pricing or share calculations.

**Verdict: DEFENDED** -- The combination of `nonReentrant` on the vault, `nonReentrant` on OmniPrivacyBridge, CEI pattern (state updated before external calls), and standard ERC20 tokens (no callback hooks) provides multi-layered reentrancy protection. No viable re-entry path exists.

---

### Category 4: Fee Distribution Manipulation

**Attack Hypothesis:** Can fee ratios be manipulated or recipients redirected to steal funds?

**Investigation:**

1. **Ratio manipulation:** `ODDAO_BPS`, `STAKING_BPS`, and `PROTOCOL_BPS` are `public constant` values (7000, 2000, 1000). They cannot be changed, even by an upgrade, because constants are embedded in bytecode. An upgrade could change the `distribute()` logic, but `_authorizeUpgrade()` requires `DEFAULT_ADMIN_ROLE` and can be permanently blocked by ossification. **Defense holds.**

2. **Recipient redirection:** All recipient changes (`stakingPool`, `protocolTreasury`) use 48-hour timelocks (`proposeRecipients`/`applyRecipients`). The swap router and privacy bridge also have 48-hour timelocks. The XOM token address has a 48-hour timelock. The bridge mode has a 48-hour timelock. **Defense holds.**

3. **Multiple pending proposals:** An attacker could rapidly call `proposeRecipients()` multiple times, each overwriting the pending values. Only the last proposal takes effect, and it must still wait 48 hours from the last `proposeRecipients()` call. This is actually defensive -- repeated proposals EXTEND the wait time, not shorten it. **Defense holds.**

4. **Exploiting zero-address fallback in `depositMarketplaceFee()`:** When `referrer`, `referrerL2`, `listingNode`, or `sellingNode` is `address(0)`, their share goes to `pendingBridge[token]` (ODDAO). A malicious DEPOSITOR_ROLE contract could always pass `address(0)` for all participants, diverting all marketplace sub-splits to ODDAO instead of legitimate referrers/nodes. However:
   - This requires a compromised DEPOSITOR_ROLE contract (the upstream MinimalEscrow or DEXSettlement).
   - The upstream contracts have their own access controls.
   - The vault cannot enforce that the depositor passes correct addresses -- this is a trust boundary by design.
   **Accepted design boundary.**

5. **Flash loan distribution front-running:** An attacker flash-loans tokens, transfers them to the vault, calls `distribute()`, and recovers the distributed amounts. Analysis:
   - The flash-loaned tokens enter the vault balance.
   - `distribute()` splits them 70/20/10.
   - 70% stays in the vault as `pendingBridge` (not extractable without BRIDGE_ROLE).
   - 20% is pushed to `stakingPool` (not the attacker).
   - 10% is pushed to `protocolTreasury` (not the attacker).
   - The attacker has no way to recover ANY of the distributed tokens.
   - The flash loan cannot be repaid, so the transaction reverts.
   **Defense holds.**

**Verdict: DEFENDED** -- Fee ratios are immutable constants. All recipient changes are timelocked. Flash loan distribution is not profitable for attackers.

---

### Category 5: Token Rescue Scope

**Attack Hypothesis:** Can `rescueToken()` extract actively managed tokens (committed fees)?

**Investigation:**

```solidity
function rescueToken(address token, uint256 amount, address recipient)
    external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE)
{
    // ...
    uint256 vaultBalance = IERC20(token).balanceOf(address(this));
    uint256 committed = pendingBridge[token] + totalPendingClaims[token];
    if (vaultBalance < committed + amount) {
        revert CannotRescueCommittedFunds(token, committed);
    }
    IERC20(token).safeTransfer(recipient, amount);
}
```

**Attempted exploits:**

1. **Direct over-rescue:** `rescueToken(XOM, vaultBalance, attacker)` -- reverts because `vaultBalance < committed + vaultBalance` when `committed > 0`. **Blocked.**

2. **Rescue before distribute:** Tokens arrive via `deposit()` but `distribute()` has not been called. These tokens are NOT in `pendingBridge` or `totalPendingClaims` yet. Can they be rescued?
   - Yes, technically. The `committed` calculation does not include undistributed tokens.
   - However, `rescueToken()` requires `DEFAULT_ADMIN_ROLE`, and the rescued tokens would be tokens that no one has a claim to yet.
   - If someone calls `distribute()` before the admin calls `rescueToken()`, the tokens move into `pendingBridge` and `totalPendingClaims`, making them unrescuable.
   - **This is intended behavior** -- rescueToken is meant for accidentally sent tokens, not committed fees.

3. **Rescue via rebasing/deflation:** If a fee-on-transfer token reduces the vault's actual balance below the `committed` sum, `rescueToken()` would revert (balance < committed + amount). This is correct behavior. **Defense holds.**

4. **Rescue of one token to affect another:** `rescueToken()` operates per-token. Rescuing USDC does not affect XOM committed amounts. **Defense holds.**

5. **Race condition: rescue vs. claimPending:** Admin calls `rescueToken(XOM, surplusAmount, admin)`. Concurrently, a referrer calls `claimPending(XOM)`. If `claimPending` executes first, `totalPendingClaims` decreases and `vaultBalance` decreases by the same amount, so `surplus = vaultBalance - committed` remains the same. If `rescueToken` executes first, the surplus is consumed and the referrer's `claimPending` still succeeds (the referrer's tokens are still in the vault, protected by the `committed` check). **Defense holds.**

**Verdict: DEFENDED** -- `rescueToken()` correctly includes both `pendingBridge` and `totalPendingClaims` in its committed funds calculation. It can only extract truly surplus tokens.

---

### Category 6: Timelock Bypass

**Attack Hypothesis:** Can pending configuration changes be applied prematurely?

**Investigation:**

All timelock functions follow the same pattern:

```solidity
// Propose
pendingValue = newValue;
changeTimestamp = block.timestamp + RECIPIENT_CHANGE_DELAY;  // 48 hours

// Apply
if (pendingValue == address(0)) revert NoPendingChange();
if (block.timestamp < changeTimestamp) revert TimelockNotExpired();
activeValue = pendingValue;
delete pendingValue;
delete changeTimestamp;
```

**Attempted bypasses:**

1. **Block timestamp manipulation:** Avalanche validators have limited ability to manipulate `block.timestamp` (typically 1-2 seconds). 48 hours = 172,800 seconds. Manipulation of 1-2 seconds is negligible. **Cannot bypass.**

2. **Upgrade bypass:** Could an admin upgrade the contract to a new implementation that removes the timelock check? Yes, but `_authorizeUpgrade()` also requires `DEFAULT_ADMIN_ROLE`. If the admin is compromised to the point of deploying a malicious upgrade, all timelocks are moot anyway. Additionally, the 48-hour timelock does not apply to upgrades themselves (UUPS `upgradeToAndCall` is instant). **This is an accepted centralization risk**, mitigated by the ossification option and the recommendation to deploy behind a multi-sig TimelockController.

3. **Overwrite proposal to shorten wait:** Calling `proposeSwapRouter(A)` at T=0, then `proposeSwapRouter(B)` at T=47h. The second call sets `swapRouterChangeTimestamp = T+47h + 48h = T+95h`. The attacker must still wait 48 hours from the LATEST proposal. **Cannot shorten.**

4. **Apply with stale proposal:** Could an attacker prepare a proposal, wait 48 hours, but then someone else overwrites the proposal? The overwrite resets the timestamp. The stale proposal's `pendingSwapRouter` value is replaced. The attacker calling `applySwapRouter()` would apply the NEW value (the overwriter's), not the attacker's original. **Cannot exploit stale proposals.**

5. **Ossification bypass:** `confirmOssification()` checks `block.timestamp >= ossificationScheduledAt`. Once `_ossified = true`, `_authorizeUpgrade()` permanently blocks upgrades. There is no function to unset `_ossified`. **Irreversible as designed.**

6. **Re-initialization attack:** The constructor calls `_disableInitializers()` on the implementation contract. The proxy's `initialize()` has the `initializer` modifier (one-time). No re-initialization path exists. **Defense holds.**

**Verdict: DEFENDED** -- All timelocks use `block.timestamp + 48 hours` with strict `<` comparison. No bypass mechanism was found. The only circumvention is via UUPS upgrade, which is an accepted centralization risk mitigated by ossification.

---

### Category 7: Cross-Contract Interactions

**Attack Hypothesis:** Can other OmniBazaar contracts manipulate the vault's state to create inconsistencies?

**Investigation:**

**Fee inflow paths:**

1. **MinimalEscrow -> vault:** Uses `safeTransfer(FEE_VAULT, feeAmount)` for both marketplace and arbitration fees. This is a direct transfer -- the vault receives tokens but its internal accounting (`pendingBridge`, `totalPendingClaims`) is NOT updated. The tokens sit as undistributed balance until `distribute()` is called. **No manipulation vector** -- MinimalEscrow cannot influence the vault's internal state.

2. **DEXSettlement -> vault:** Uses `safeTransfer(feeRecipients.feeVault, vaultShare)` for the 30% fee share. Same pattern as MinimalEscrow -- direct transfer, no internal state manipulation. **No manipulation vector.**

3. **RWAAMM -> vault:** Uses direct `safeTransfer` + `notifyDeposit()`. The `notifyDeposit()` only emits an event, modifying no state. **No manipulation vector.**

4. **`deposit()` by DEPOSITOR_ROLE contracts:** Uses `safeTransferFrom()` with balance-before/after pattern. The depositor must have approved the vault. The vault pulls tokens -- the depositor cannot cause the vault to receive more or fewer tokens than the `safeTransferFrom` amount (modulo fee-on-transfer, which is handled). **No manipulation vector.**

**Fee outflow paths:**

5. **`distribute()` -> `stakingPool` / `protocolTreasury`:** Uses `_safePushOrQuarantine()`. If the recipient is a malicious contract that reverts deliberately, the push fails and the amount is quarantined. This is intended behavior. The malicious recipient could:
   - Always revert to accumulate a large `pendingClaims` balance, then claim it all at once. But this is just delayed claiming -- not a profit vector.
   - Revert selectively to cause quarantine, then `claimPending()` when convenient. Again, not a profit vector.
   **No manipulation vector.**

6. **`bridgeToTreasury()` by BRIDGE_ROLE:** Sends tokens to an arbitrary `bridgeReceiver`. The amount is bounded by `pendingBridge[token]`. A compromised BRIDGE_ROLE could send ODDAO funds to an attacker address. **This is an accepted trust assumption** -- BRIDGE_ROLE is trusted by design.

7. **`swapAndBridge()` by BRIDGE_ROLE:** See E-01 for the residual approval issue. Beyond that, a compromised BRIDGE_ROLE could call this with `minXOMOut = 0` to accept a terrible swap price. **Accepted trust assumption, documented in Round 7 L-03.**

**State manipulation via token donation:**

8. **Direct ERC20 transfer to vault:** Anyone can send tokens to the vault without calling `deposit()`. These tokens become undistributed balance and would be included in the next `distribute()` call. This is intentional -- `distribute()` is permissionless and handles whatever balance is available. The donated tokens would be split 70/20/10 to legitimate recipients. **No profit vector for attacker.**

9. **Donation to manipulate `undistributed()` view:** An attacker could donate tokens to inflate the `undistributed()` view function, potentially misleading off-chain systems. But since `distribute()` sends 70% to `pendingBridge` (internal), 20% to `stakingPool`, and 10% to `protocolTreasury`, the attacker loses the donated tokens. **No profit vector.**

**Cross-contract accounting consistency:**

10. **MinimalEscrow `totalMarketplaceFees` vs vault `totalDistributed`:** MinimalEscrow tracks `totalMarketplaceFees[token]` separately from the vault's `totalDistributed[token]`. These are independent counters on different contracts. A discrepancy between them does not create an exploit -- it is simply a reconciliation task for off-chain analytics. **No vulnerability.**

11. **Multiple DEPOSITOR_ROLE contracts calling `deposit()` concurrently:** Each `deposit()` call is atomic (single transaction) and uses `nonReentrant`. Two deposits in the same block execute sequentially. The balance-before/after pattern correctly handles sequential deposits. **No vulnerability.**

**Verdict: DEFENDED** -- Cross-contract interactions are limited to token transfers (in and out). No external contract can modify the vault's internal accounting state (`pendingBridge`, `totalPendingClaims`, `pendingClaims`). The vault's state is self-consistent and resistant to manipulation from external contracts.

---

## Additional Observations

### Observation 1: `notifyDeposit()` Lacks `nonReentrant` and `whenNotPaused`

`notifyDeposit()` (line 690) has neither `nonReentrant` nor `whenNotPaused`. It only emits an event and has no state changes, so there is no reentrancy or pause-bypass risk. However, a compromised DEPOSITOR_ROLE could call `notifyDeposit()` while the contract is paused, emitting misleading `FeesNotified` events. **Impact: Informational only** -- off-chain indexers might record phantom deposits.

### Observation 2: `claimPending()` Is Not Pausable

`claimPending()` (line 779) does not use `whenNotPaused`. This is intentional -- users should always be able to withdraw their quarantined funds, even during emergencies. However, this means a pause does not prevent token outflows from quarantined claims. **Impact: Accepted design** -- the pause is meant to stop new deposits and distributions, not freeze existing claims.

### Observation 3: `depositMarketplaceFee()` Rounding Dust

With `saleAmount = 10000` (the minimum):
- `totalFee = 10000 / 100 = 100`
- `txFee = 100 / 2 = 50`
- `refFee = 100 / 4 = 25`
- `listFee = 100 - 50 - 25 = 25`
- `txOddao = (50 * 7000) / 10000 = 35`
- `txStaking = (50 * 2000) / 10000 = 10`
- `txProtocol = 50 - 35 - 10 = 5`

All sub-splits produce non-zero values at the minimum. No rounding-to-zero dust loss occurs. **Verified correct.**

### Observation 4: Single Pending Bridge Mode Proposal Slot

The `pendingBridgeModeToken` and `pendingBridgeMode` state variables store only one pending bridge mode change at a time. If an admin proposes a bridge mode change for token A, then proposes for token B, the token A proposal is silently overwritten. This is consistent with other timelock patterns in the contract (re-proposal overwrites). **No vulnerability** -- but worth documenting that only one bridge mode change can be pending at a time.

---

## Recommendations Summary (Priority Order)

| Priority | Finding | Action |
|----------|---------|--------|
| **1 (Medium)** | E-01: Swap router approval residual | Add `forceApprove(swapRouter, 0)` after swap execution in `swapAndBridge()` and `forceApprove(privacyBridge, 0)` after conversion in `convertPXOMAndBridge()` |
| **2 (Medium)** | E-02: Admin claim redirect without timelock | Add propose/apply timelock pattern to `redirectStuckClaim()`, consistent with all other admin operations |
| **3 (Informational)** | Observation 1: `notifyDeposit()` callable while paused | Add `whenNotPaused` modifier to prevent misleading event emissions during pause |
| **4 (Informational)** | Observation 4: Single bridge mode proposal slot | Document in NatSpec that only one bridge mode change can be pending at a time |

---

## Conclusion

The UnifiedFeeVault demonstrates strong defensive posture after 7 prior audit rounds. The two medium-severity findings (E-01 and E-02) both require a compromised admin key to exploit, and both have straightforward mitigations:

1. **E-01** is a defense-in-depth improvement -- resetting approvals to zero after external interactions is a well-established best practice that costs minimal gas.
2. **E-02** is a consistency improvement -- adding a timelock to `redirectStuckClaim()` aligns it with every other admin configuration change in the contract.

No critical or high-severity exploits were constructible. The contract's multi-layered defenses (nonReentrant, CEI pattern, timelocks, committed funds tracking, pull-pattern quarantine, ossification) work together effectively. The most significant remaining risk is the centralization of DEFAULT_ADMIN_ROLE/ADMIN_ROLE/BRIDGE_ROLE, which must be mitigated operationally through multi-sig deployment (Gnosis Safe + TimelockController) before mainnet launch.

**Contract Status:** Suitable for mainnet deployment after addressing E-01 and E-02.
