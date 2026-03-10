# Cross-System Adversarial Review: Privacy Attack Paths

**Date:** 2026-03-10
**Audit Phase:** Phase 2 -- Pre-Mainnet Cross-Contract Privacy Analysis
**Audited by:** Claude Code Audit Agent
**Scope:** All privacy-touching contracts in the OmniCoin protocol
**Contracts Analyzed:**
- `PrivateOmniCoin.sol` (968 lines) -- Privacy-enabled XOM token (COTI V2 MPC)
- `OmniPrivacyBridge.sol` (706 lines) -- XOM-to-pXOM bridge with 0.5% fee
- `PrivateDEX.sol` (1,209 lines) -- Privacy-preserving order matching
- `PrivateDEXSettlement.sol` (1,084 lines) -- Privacy DEX settlement with encrypted fees
- `PrivateUSDC.sol` (668 lines) -- Privacy-wrapped USDC
- `PrivateWBTC.sol` (722 lines) -- Privacy-wrapped WBTC
- `PrivateWETH.sol` (720 lines) -- Privacy-wrapped WETH
- `OmniCoin.sol` (293 lines) -- Public XOM ERC20 token
- `OmniBridge.sol` (1,003 lines) -- Cross-chain bridge (Avalanche Warp Messaging)
- `MinimalEscrow.sol` (1,228 lines) -- 2-of-3 multisig escrow with privacy support
**Prior Audits Referenced:** Round 6 individual contract audits (2026-03-10)
**Total Lines Analyzed:** ~8,601

---

## Executive Summary

This report presents a systematic adversarial analysis of cross-contract privacy attack paths in the OmniCoin protocol. While individual contract audits (Round 6) evaluated each contract in isolation, this review focuses exclusively on **interactions between contracts** that could deanonymize users, correlate private transactions, or exploit inconsistent privacy guarantees across the system.

**Key Findings Summary:**

| ID | Attack Path | Severity | Feasibility |
|----|------------|----------|-------------|
| ATK-01 | Bridge Event Amount Correlation (OmniPrivacyBridge) | **High** | High |
| ATK-02 | PrivateOmniCoin PrivateLedgerUpdated Plaintext Leakage | **High** | High |
| ATK-03 | MinimalEscrow Private Escrow Plaintext Amount Storage | **High** | High |
| ATK-04 | Cross-Bridge Privacy Downgrade (OmniBridge + OmniPrivacyBridge) | **Medium** | Medium |
| ATK-05 | Wrapper Contract Inconsistency Exploitation | **Medium** | Medium |
| ATK-06 | PrivateDEXSettlement Phantom Collateral | **Medium** | Medium |
| ATK-07 | MPC Compromise Blast Radius | **Critical (Architectural)** | Low |
| ATK-08 | Selective Reveal via Admin Privacy Disable | **Medium** | Low |
| ATK-09 | PrivateDEX Metadata Leakage for Trade Deanonymization | **Medium** | High |
| ATK-10 | Cross-Chain Privacy Leakage via OmniBridge | **Medium** | Medium |
| ATK-11 | Front-Running Privacy Conversions | **Low** | Medium |
| ATK-12 | Compliance vs Privacy -- Forced Deanonymization | **Medium** | Medium |

**Overall Assessment:** The protocol's privacy architecture has a fundamental tension: COTI V2 MPC provides strong computational privacy for encrypted values, but the surrounding smart contract infrastructure leaks substantial metadata through events, plaintext storage, and cross-contract interactions. An observer with access to on-chain events and transaction data can reconstruct significant information about "private" transactions, particularly bridge conversions, escrow amounts, and DEX trading patterns.

---

## Post-Audit Remediation Status (2026-03-10)

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| ATK-07 | Critical | MPC compromise blast radius | **ACKNOWLEDGED** -- Architectural risk; ZK proof-based fallback recommended for future |
| ATK-01 | High | Bridge event amount correlation (OmniPrivacyBridge) | **FIXED** -- OmniPrivacyBridge events stripped of plaintext amounts; now emit only (address indexed user) |
| ATK-02 | High | PrivateOmniCoin PrivateLedgerUpdated plaintext leakage | **RESEARCHED** -- Phase 1 recommendation (make privateDepositLedger private, remove scaledAmount from event) ready; Phase 2 (utUint64 encrypted storage) for COTI L2 deployment |
| ATK-03 | High | MinimalEscrow private escrow plaintext amount storage | **FIXED** -- Private escrow amounts moved to private mapping; public getter returns 0 |
| ATK-04 | Medium | Cross-bridge privacy downgrade (OmniBridge + OmniPrivacyBridge) | **FIXED** |
| ATK-05 | Medium | Wrapper contract inconsistency exploitation | **FIXED** |
| ATK-06 | Medium | PrivateDEXSettlement phantom collateral | **FIXED** |
| ATK-08 | Medium | Selective reveal via admin privacy disable | **FIXED** |
| ATK-09 | Medium | PrivateDEX metadata leakage for trade deanonymization | **FIXED** |
| ATK-10 | Medium | Cross-chain privacy leakage via OmniBridge | **FIXED** |
| ATK-12 | Medium | Compliance vs privacy -- forced deanonymization paths | **FIXED** |

---

## Privacy Architecture Overview

### System Topology

```
                    Public Domain                          Private Domain (MPC)
                    ============                           ====================

  User Wallet -----> OmniCoin.sol (XOM, ERC20)
       |                  |
       |            OmniPrivacyBridge.sol
       |              lock XOM, mint pXOM
       |              (0.5% fee, events expose amounts)
       |                  |
       |            PrivateOmniCoin.sol (pXOM)
       |              |-- convertToPrivate() -----> MPC Encrypted Balances
       |              |-- privateTransfer() -----> MPC garbled transfer
       |              |-- convertToPublic()  <----- MPC decryption
       |                  |
       |            PrivateDEX.sol
       |              |-- submitPrivateOrder() --> MPC encrypted order
       |              |-- canOrdersMatch()     --> MPC price comparison
       |              |-- executePrivateTrade() -> MPC fill computation
       |                  |
       |            PrivateDEXSettlement.sol
       |              |-- settlePrivateTrade() --> MPC fee computation
       |              |-- claimFees()          <-- MPC decryption
       |
       +-----------> PrivateUSDC.sol / PrivateWBTC.sol / PrivateWETH.sol
       |              |-- bridgeMint() ---------> custody real tokens
       |              |-- convertToPrivate() ---> MPC encrypted
       |              |-- privateTransfer() ----> MPC garbled
       |
       +-----------> MinimalEscrow.sol
       |              |-- createPrivateEscrow() -> DECRYPTS amount (!)
       |
       +-----------> OmniBridge.sol
                      |-- initiateTransfer() ---> Warp message (plaintext)
```

### Privacy Guarantees (As Designed)

1. **Computational Privacy:** COTI V2 MPC garbled circuits encrypt balances and arithmetic operations. On-chain storage contains `ctUint64` ciphertext values that cannot be decrypted without MPC node cooperation.

2. **Transfer Privacy:** `privateTransfer()` moves encrypted amounts between users. The transfer amount is a garbled value (`gtUint64`) that is never stored in plaintext... **except** in PrivateOmniCoin (ATK-H08 shadow ledger update) and in emitted events (M-01 PrivateLedgerUpdated).

3. **Trade Privacy:** PrivateDEX stores order amounts and prices as encrypted `ctUint64`. Matching uses MPC comparisons. Fill amounts are computed within MPC.

4. **Precision Boundary:** All MPC values are `uint64`, limiting encrypted amounts to 18,446,744,073,709,551,615 (scaled by 1e12 for 18-decimal tokens, yielding ~18.44 units maximum per address).

### Privacy Guarantees (As Actually Implemented)

The gap between design and implementation is substantial. This report documents each gap.

---

## Attack Path Analysis

### ATK-01: Bridge Event Amount Correlation (OmniPrivacyBridge)

**Severity:** HIGH
**Contracts:** `OmniPrivacyBridge.sol`, `PrivateOmniCoin.sol`
**Feasibility:** HIGH -- requires only on-chain event monitoring

#### Description

The OmniPrivacyBridge emits events that expose the exact conversion amounts in plaintext, enabling deterministic correlation between public XOM deposits and private pXOM balances.

**Step-by-step exploit:**

1. Adversary monitors `ConvertedToPrivate` events on OmniPrivacyBridge:
   ```solidity
   // OmniPrivacyBridge.sol, line 343-345
   emit ConvertedToPrivate(
       caller, amount, amountAfterFee, fee
   );
   ```
   This emits: `(user_address, xom_amount_in, pxom_amount_out, fee_amount)`.

2. Adversary also monitors `ConvertedToPublic` events:
   ```solidity
   // OmniPrivacyBridge.sol (convertPXOMtoXOM function)
   emit ConvertedToPublic(caller, amount, amountOut);
   ```
   This emits: `(user_address, pxom_amount_in, xom_amount_out)`.

3. The fee is deterministic: `fee = amount * 50 / 10000` (0.5%). Given any `amountAfterFee`, the original `amount` can be computed: `amount = amountAfterFee * 10000 / 9950`.

4. When the user later converts pXOM back via `convertPXOMtoXOM`, the `amountOut` directly reveals how much pXOM they held at that point.

**Privacy Impact:**

- **Complete amount deanonymization** for bridge conversions. Any observer knows exactly how much XOM each address converted to pXOM and when.
- **Timing correlation:** If Alice converts 10,000 XOM to pXOM at block N, and Bob receives a `privateTransfer` at block N+1, and then Bob converts 9,950 pXOM back to XOM at block N+5, an observer can correlate Alice's deposit with Bob's withdrawal (matching the 0.5% fee deduction).
- **Balance inference:** By tracking all `ConvertedToPrivate` and `ConvertedToPublic` events for an address, an observer can reconstruct the user's minimum pXOM balance over time (deposits minus withdrawals).

**Existing Protections:**

- Daily volume limits on conversions (aggregated, not per-user).
- Per-transaction limits (`maxConversionLimit`).
- These do not prevent amount correlation; they limit the rate of exploitation.

**Severity Justification:** HIGH. The events completely undermine the privacy bridge's purpose. A user who converts XOM to pXOM for privacy gains no amount privacy at the bridge boundary. The only privacy obtained is *within* the pXOM ecosystem (private transfers between users), but entry and exit points are fully transparent.

---

### ATK-02: PrivateOmniCoin PrivateLedgerUpdated Plaintext Leakage

**Severity:** HIGH
**Contracts:** `PrivateOmniCoin.sol`
**Feasibility:** HIGH -- requires only on-chain event monitoring

#### Description

PrivateOmniCoin's `privateTransfer()` function decrypts the transfer amount and emits it in plaintext via the `PrivateLedgerUpdated` event. This was added as the ATK-H08 fix to maintain shadow ledger accuracy for emergency recovery, but it completely negates MPC transfer privacy.

**Specific code path:**

```solidity
// PrivateOmniCoin.sol, lines 592-607
uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
uint256 transferAmount = uint256(plainAmount);

if (privateDepositLedger[msg.sender] >= transferAmount) {
    privateDepositLedger[msg.sender] -= transferAmount;
} else {
    privateDepositLedger[msg.sender] = 0;
}
privateDepositLedger[to] += transferAmount;

emit PrivateLedgerUpdated(
    msg.sender, to, transferAmount  // <-- PLAINTEXT AMOUNT
);
emit PrivateTransfer(msg.sender, to);  // <-- No amount (private)
```

**Step-by-step exploit:**

1. Adversary monitors `PrivateLedgerUpdated(address indexed from, address indexed to, uint256 scaledAmount)` events.
2. Every private transfer reveals: sender address, recipient address, and exact transfer amount (in 6-decimal scaled units).
3. The `PrivateTransfer(from, to)` event (without amount) is redundant -- the `PrivateLedgerUpdated` event already provides all the same information plus the amount.

**Privacy Impact:**

- **Complete deanonymization of all private XOM transfers.** The MPC encryption of transfer amounts provides zero privacy because the decrypted amount is immediately emitted in an event.
- Combined with ATK-01 (bridge amount correlation), an adversary can trace the complete lifecycle: XOM deposit -> pXOM conversion -> private transfer (with amount) -> pXOM-to-XOM withdrawal.
- The shadow ledger itself (`privateDepositLedger`) is a public mapping that anyone can read via `getPrivateDepositBalance()`, providing real-time plaintext balance tracking.

**Existing Protections:**

- The `PrivateTransfer` event (line 608) does not include the amount -- but this is moot since `PrivateLedgerUpdated` (line 605-607) does.
- The shadow ledger is documented as a trade-off for emergency recovery reliability.

**Severity Justification:** HIGH. This finding was identified as M-01 in the Round 6 PrivateOmniCoin audit but its cross-contract impact is amplified here. Combined with ATK-01, the entire pXOM privacy chain is transparent.

**Recommendation:** The `PrivateLedgerUpdated` event should NOT emit `scaledAmount`. The shadow ledger can be updated silently (the storage writes are sufficient for emergency recovery; the event is for convenience, not correctness). If an event is desired, emit only the addresses:

```solidity
emit PrivateLedgerUpdated(msg.sender, to);
// Remove the third parameter (scaledAmount)
```

---

### ATK-03: MinimalEscrow Private Escrow Plaintext Amount Storage

**Severity:** HIGH
**Contracts:** `MinimalEscrow.sol`, `PrivateOmniCoin.sol`
**Feasibility:** HIGH -- requires only on-chain state inspection

#### Description

MinimalEscrow's `createPrivateEscrow()` function accepts an encrypted amount but immediately decrypts it and stores the plaintext value on-chain. This completely defeats the purpose of "private" escrows.

**Specific code path:**

```solidity
// MinimalEscrow.sol, line 899
uint64 plainAmount = MpcCore.decrypt(encryptedAmount);

// ... later at line 916:
escrows[escrowId] = Escrow({
    buyer: caller,
    seller: seller,
    amount: uint256(plainAmount),  // <-- PLAINTEXT STORED ON-CHAIN
    token: address(PRIVATE_OMNI_COIN),
    expiry: block.timestamp + duration,
    // ...
});
```

**Step-by-step exploit:**

1. User creates a "private" escrow, believing the amount is encrypted.
2. Any observer calls `getEscrow(escrowId)` or reads storage slot directly.
3. `escrow.amount` returns the plaintext amount in 6-decimal scaled units.
4. The `PrivateEscrowCreated` event correctly omits the amount, but the on-chain storage exposes it.

**Privacy Impact:**

- **Complete amount exposure** for all private escrows. The "privacy" label is misleading.
- Marketplace transaction amounts are fully visible despite using the privacy path.
- The `MarketplaceFeeCollected` event (emitted during private escrow release) also reveals the fee amount, from which the original escrow amount can be reverse-computed: `originalAmount = feeAmount * 10000 / MARKETPLACE_FEE_BPS`.

**Additional Cross-Contract Impact:**

When a buyer creates a private escrow, the flow is:
1. Buyer converts XOM to pXOM via OmniPrivacyBridge (ATK-01: amount exposed in event).
2. Buyer converts pXOM to encrypted balance via PrivateOmniCoin.convertToPrivate().
3. Buyer creates private escrow via MinimalEscrow.createPrivateEscrow() (ATK-03: amount stored in plaintext).
4. The entire chain is transparent: bridge deposit amount -> escrow amount -> fee amount.

**Existing Protections:**

- `PrivateEscrowCreated` event does not include the amount (correct).
- `PrivateEscrowResolved` event does not include the amount (correct).
- But the on-chain `escrow.amount` field stores plaintext (defeats the purpose).

**Severity Justification:** HIGH. Users selecting "private escrow" expect amount confidentiality. The plaintext storage completely violates this expectation.

**Recommendation:** For private escrows, store only the encrypted amount and do not decrypt. All fee calculations and disbursements should use MPC arithmetic. If plaintext is needed for the token transfer, decrypt only at resolution time (in `_resolvePrivateEscrow()`) and do not store the plaintext in the struct:

```solidity
// In createPrivateEscrow():
escrows[escrowId] = Escrow({
    // ...
    amount: 0,  // Amount is encrypted, stored in encryptedEscrowAmounts
    // ...
});
encryptedEscrowAmounts[escrowId] = MpcCore.offBoard(encryptedAmount);
```

---

### ATK-04: Cross-Bridge Privacy Downgrade (OmniBridge + OmniPrivacyBridge)

**Severity:** MEDIUM
**Contracts:** `OmniBridge.sol`, `OmniPrivacyBridge.sol`, `PrivateOmniCoin.sol`
**Feasibility:** MEDIUM -- requires cross-chain event monitoring

#### Description

A user who bridges tokens cross-chain via OmniBridge and then converts to privacy via OmniPrivacyBridge creates a multi-step trail where each step exposes amounts in plaintext events.

**Step-by-step attack scenario:**

1. **Chain A (source):** User calls `OmniBridge.initiateTransfer(recipient, 100000e18, chainB, false)`.
   - `TransferInitiated` event: `(transferId, sender, recipient, netAmount=99500e18, targetChainId, fee=500e18)` -- **ALL PLAINTEXT**.

2. **Chain B (destination):** Warp message processed, `TransferCompleted` event: `(transferId, recipient, 99500e18)` -- **PLAINTEXT**.

3. **Chain B:** Recipient calls `OmniPrivacyBridge.convertXOMtoPXOM(99500e18)`.
   - `ConvertedToPrivate` event: `(recipient, 99500e18, 99002.5e18, 497.5e18)` -- **PLAINTEXT**.

4. **Chain B:** Recipient calls `PrivateOmniCoin.convertToPrivate(99002.5e18)`.
   - No amount in event (good), but `PrivateLedgerUpdated` from any subsequent `privateTransfer` will leak amounts (ATK-02).

**Privacy Impact:**

- The cross-chain bridge creates an indelible public record linking the source-chain address to the destination-chain address with exact amounts.
- Privacy conversions on the destination chain cannot retroactively hide the bridge trail.
- An adversary correlating cross-chain events can determine that a specific "private" balance originated from a specific public address on another chain.

**Additional Privacy Leak -- OmniBridge `usePrivateToken` flag:**

```solidity
// OmniBridge.sol, line 468
transferUsePrivacy[transferId] = usePrivateToken;
```

The `usePrivateToken` boolean in the bridge transfer indicates the user's intent to use privacy. Even the Warp message payload (line 801-807) includes this flag. This metadata reveals which bridge users are privacy-seeking, potentially marking them for enhanced surveillance.

**Existing Protections:**

- Daily volume limits on both OmniBridge and OmniPrivacyBridge.
- These are rate limiters, not privacy protections.

**Severity Justification:** MEDIUM. The privacy downgrade is a natural consequence of transparent bridge operations. Users can mitigate by waiting and mixing after bridge receipt, but this requires sophisticated operational security that most users will not practice.

---

### ATK-05: Wrapper Contract Inconsistency Exploitation

**Severity:** MEDIUM
**Contracts:** `PrivateUSDC.sol`, `PrivateWBTC.sol`, `PrivateWETH.sol` vs `PrivateOmniCoin.sol`
**Feasibility:** MEDIUM -- requires understanding of contract differences

#### Description

The three privacy wrapper contracts (PrivateUSDC, PrivateWBTC, PrivateWETH) have materially weaker privacy protections compared to PrivateOmniCoin. An adversary can exploit these inconsistencies.

**Inconsistency Matrix:**

| Feature | PrivateOmniCoin | PrivateUSDC/WBTC/WETH |
|---------|----------------|----------------------|
| Privacy disable timelock | 7-day delay (propose/execute/cancel) | **INSTANT** (admin calls `setPrivacyEnabled(false)`) |
| Shadow ledger in privateTransfer | Updated (ATK-H08) with decryption | **NOT updated** (documented limitation) |
| MPC subtraction | `MpcCore.checkedSub()` | `MpcCore.sub()` with prior `ge` check |
| Admin balance visibility | Owner only | Owner **or admin** |
| Dust accounting | Stays in public balance automatically | `dustBalances` + `claimDust()` (**has double-counting bug**) |

**Attack Scenario 1: Instant Privacy Disable on Wrappers**

A compromised admin (or a governance attacker who gains `DEFAULT_ADMIN_ROLE`) can:

1. Call `setPrivacyEnabled(false)` on PrivateUSDC -- **instant**, no timelock.
2. Call `emergencyRecoverPrivateBalance(user)` for target users, crediting their `publicBalances` from the shadow ledger.
3. The shadow ledger is incomplete (does not track privateTransfer), so recovery amounts may be incorrect.
4. Users who received USDC via `privateTransfer()` lose those funds entirely (shadow ledger shows zero for received amounts).

Compare with PrivateOmniCoin: the 7-day timelock gives users a week to call `convertToPublic()` and exit their private positions before admin-initiated recovery.

**Attack Scenario 2: Admin Balance Inspection on Wrappers**

```solidity
// PrivateUSDC.sol, lines 568-574
function privateBalanceOf(address account) external view
    returns (ctUint64)
{
    if (msg.sender != account &&
        !hasRole(DEFAULT_ADMIN_ROLE, msg.sender))
    {
        revert Unauthorized();
    }
    return encryptedBalances[account];
}
```

The wrapper contracts allow **admin** to read encrypted balances. While `ctUint64` values are ciphertext that cannot be directly read, they CAN be used in MPC operations by the admin if the admin also holds other roles (e.g., BRIDGE_ROLE). In contrast, PrivateOmniCoin restricts `privateBalanceOf` to the account owner only (ATK-H05 fix).

**Attack Scenario 3: Dust Double-Counting for WBTC/WETH**

As documented in the Round 6 audits for PrivateWBTC (M-03) and PrivateWETH (M-03), the `claimDust()` function adds dust to `publicBalances` that was never removed, creating inflated balances. This is an accounting bug, not a privacy bug, but it could be exploited to extract more underlying tokens than a user deposited.

For WBTC: up to 99 satoshi per conversion (~$0.09).
For WETH: up to ~1e12 wei per conversion (~$0.002).
Cumulative impact over millions of conversions: potentially 1 BTC or 1 ETH of unbacked balances.

**Privacy Impact:**

- Users may rationally choose PrivateUSDC/WBTC/WETH for privacy, not knowing these contracts have weaker protections than PrivateOmniCoin.
- The instant privacy disable on wrappers creates a "rug pull" vector for privacy, even if it is never used maliciously -- the threat itself reduces the credibility of the privacy guarantee.
- Shadow ledger incompleteness means emergency recovery on wrappers is unreliable, potentially causing fund loss.

**Severity Justification:** MEDIUM. The inconsistencies are individually documented in each contract's Round 6 audit, but the cross-contract view reveals a systemic pattern of weaker privacy for non-XOM tokens that users may not be aware of.

**Recommendation:**

1. Implement the 7-day privacy disable timelock on all wrapper contracts (matching PrivateOmniCoin).
2. Implement the ATK-H08 shadow ledger transfer tracking on all wrapper contracts.
3. Restrict `privateBalanceOf` to owner-only on all wrapper contracts.
4. Fix the dust double-counting bug before deployment.

---

### ATK-06: PrivateDEXSettlement Phantom Collateral

**Severity:** MEDIUM
**Contracts:** `PrivateDEXSettlement.sol`, `PrivateDEX.sol`, `PrivateOmniCoin.sol`
**Feasibility:** MEDIUM -- requires SETTLER_ROLE compromise

#### Description

PrivateDEXSettlement implements a "phantom collateral" model where no actual tokens are escrowed during trade settlement. All accounting is done in MPC-encrypted values, with the SETTLER (off-chain validator) controlling the encrypted amounts and settlement flow.

**Architecture:**

```solidity
// PrivateDEXSettlement.sol -- settlePrivateTrade()
// 1. Reads trader encrypted balances from PrivateOmniCoin
// 2. Performs MPC arithmetic to compute fill amounts and fees
// 3. Updates PrivateOmniCoin encrypted balances
// 4. No actual token transfer occurs -- just encrypted balance adjustments
```

**Step-by-step attack scenario (compromised SETTLER):**

1. SETTLER calls `settlePrivateTrade()` with fabricated settlement parameters.
2. EIP-191 signatures from both traders are required (H-02/H-03 fix), but traders sign a commitment hash that includes `orderId` and `pairHash`, NOT the actual amounts. The amounts are controlled by the SETTLER:

   ```solidity
   // Traders sign: keccak256(orderId, pairHash, nonce)
   // They do NOT sign: settlement amounts
   ```

3. SETTLER provides encrypted amounts for the settlement. While MPC internal validation (C-01, C-02 fixes) ensures the fill amount does not exceed the order amount, the SETTLER controls:
   - Which orders to settle and in what sequence.
   - The `solver` address that receives settlement outputs.
   - The timing of settlement.

4. Fee computation is entirely MPC-internal: 0.2% trading fee split 70/20/10. The SETTLER cannot fabricate fee amounts (MPC arithmetic is trustworthy), but it can choose WHICH trades to settle and when.

**Privacy Impact:**

- The phantom collateral model means there is no on-chain escrow to verify solvency. Users trust the SETTLER to correctly compute and apply settlement amounts.
- If the SETTLER is compromised, it can selectively settle trades to favor certain parties, delay settlements to manipulate markets, or front-run by observing encrypted order parameters (see ATK-09).
- The `TradeSettled` event emits `(buyer, seller, pair, orderId1, orderId2)` but NOT amounts -- good for privacy but bad for verifiability.

**Severity Justification:** MEDIUM. The phantom collateral design is an acknowledged architectural choice documented in the Round 6 PrivateDEXSettlement audit (H-01). It provides privacy at the cost of verifiability. The EIP-191 trader signatures provide consent verification but not amount verification.

**Recommendation:**

1. Consider adding an on-chain solvency check that verifies total encrypted balances are conserved after settlement (sum of inputs equals sum of outputs plus fees).
2. Add trader-verifiable settlement receipts: after settlement, emit an event or update state that allows each trader to verify their own balance changed by the expected amount (via MPC decryption of their own balance delta).
3. Implement SETTLER rotation or multi-SETTLER consensus for settlement authorization.

---

### ATK-07: MPC Compromise Blast Radius

**Severity:** CRITICAL (Architectural)
**Contracts:** All privacy contracts
**Feasibility:** LOW -- requires compromising COTI V2 MPC infrastructure
**Impact if exploited:** TOTAL PRIVACY LOSS

#### Description

All privacy in the OmniCoin protocol depends on a single trust assumption: the COTI V2 MPC network correctly executes garbled circuit computations without revealing intermediate values. If this assumption fails, the blast radius is total.

**What is encrypted by MPC:**

| Contract | Encrypted Values | Blast Radius |
|----------|-----------------|--------------|
| PrivateOmniCoin | All pXOM balances, all transfer amounts | All pXOM holder balances exposed |
| PrivateUSDC | All private USDC balances, transfer amounts | All private USDC exposed |
| PrivateWBTC | All private WBTC balances, transfer amounts | All private WBTC exposed |
| PrivateWETH | All private WETH balances, transfer amounts | All private WETH exposed |
| PrivateDEX | All order amounts, prices, fill levels | All open order book exposed |
| PrivateDEXSettlement | All settlement amounts, fee computations | All settlement history exposed |

**MPC Compromise Scenarios:**

1. **Passive Key Compromise:** An attacker who obtains MPC key shares can decrypt all `ctUint64` values on-chain. This reveals every encrypted balance, every historical transfer amount (stored in ciphertext), and every open DEX order's price and size. The attacker gains a God-view of the entire private economy without any on-chain interaction.

2. **Active MPC Manipulation:** An attacker who controls MPC computation can:
   - Return incorrect results from `MpcCore.decrypt()`, causing `convertToPublic()` to mint arbitrary public balances.
   - Return `true` from `MpcCore.ge()` comparisons, causing `canOrdersMatch()` to match incompatible orders.
   - Return fabricated values from `MpcCore.checkedAdd()`, inflating encrypted balances.
   - Bypass the `uint64` overflow check in `checkedAdd()`, creating unlimited encrypted balances.

3. **Selective Revelation:** An attacker with partial MPC access can selectively decrypt specific users' balances without decrypting others, enabling targeted surveillance while maintaining plausible deniability.

**Cross-Contract Amplification:**

Because all privacy contracts use the same COTI V2 MPC infrastructure, a single compromise exposes:
- Total pXOM economy (PrivateOmniCoin)
- All private DEX trading activity (PrivateDEX + PrivateDEXSettlement)
- All private wrapped asset positions (PrivateUSDC/WBTC/WETH)
- All private escrow amounts (MinimalEscrow, already in plaintext per ATK-03)

**Existing Protections:**

- Shadow ledger emergency recovery (PrivateOmniCoin only -- wrappers have incomplete shadow ledgers per ATK-05).
- `privacyEnabled` toggle for graceful degradation (instant on wrappers, 7-day timelock on PrivateOmniCoin).
- Contract pausability on all privacy contracts.

**Severity Justification:** CRITICAL (Architectural). This is not a bug but a fundamental trust assumption. If COTI V2 MPC is compromised, there is no on-chain fallback for privacy. The blast radius encompasses every encrypted value in the system.

**Recommendation:**

1. **Document the trust model explicitly** in user-facing documentation: "Privacy guarantees depend entirely on the integrity of the COTI V2 MPC network. If the MPC infrastructure is compromised, all encrypted values become readable."
2. **Implement defense-in-depth:** Consider using zero-knowledge proofs for critical operations (balance conservation, overflow checks) that can be verified independently of MPC.
3. **Monitor MPC health:** Implement on-chain or off-chain health checks that detect anomalous MPC behavior (e.g., unusually fast decryption responses, which could indicate key material leakage).
4. **Emergency response plan:** Document a playbook for MPC compromise: pause all privacy contracts, disable privacy on all wrappers (7-day timelock means PrivateOmniCoin has a delay), trigger emergency recovery.

---

### ATK-08: Selective Reveal via Admin Privacy Disable

**Severity:** MEDIUM
**Contracts:** `PrivateUSDC.sol`, `PrivateWBTC.sol`, `PrivateWETH.sol`, `PrivateOmniCoin.sol`
**Feasibility:** LOW -- requires admin key compromise

#### Description

An adversary who compromises the admin key can selectively disable privacy on specific wrapper contracts while leaving others enabled. This creates an asymmetric information advantage.

**Step-by-step attack:**

1. Adversary compromises `DEFAULT_ADMIN_ROLE` for PrivateUSDC.
2. Adversary calls `setPrivacyEnabled(false)` -- **instant** on PrivateUSDC (no timelock).
3. Adversary calls `emergencyRecoverPrivateBalance(targetUser)` to force-reveal the target's private USDC balance (via shadow ledger credit to `publicBalances`).
4. Adversary observes the credited `publicBalances` amount, learning the user's private USDC position.
5. Adversary calls `setPrivacyEnabled(true)` to re-enable privacy, hiding the attack.
6. The attack leaves traces: `PrivacyDisabled` and `PrivacyEnabled` events, `EmergencyRecovery` event. But these could be explained as a legitimate emergency.

**Cross-Contract Dimension:**

The adversary can disable privacy on one wrapper (e.g., PrivateUSDC) while privacy remains enabled on others (PrivateWBTC, PrivateWETH, PrivateOmniCoin). This reveals only the target's USDC position, not their other private holdings. This selective reveal is more powerful than a total privacy failure because it can target specific assets.

**Existing Protections (by contract):**

| Contract | Privacy Disable Mechanism | Timelock | Re-enable? |
|----------|--------------------------|----------|------------|
| PrivateOmniCoin | `proposePrivacyDisable()` -> 7 day wait -> `executePrivacyDisable()` | 7 days | No built-in re-enable |
| PrivateUSDC | `setPrivacyEnabled(false)` | **NONE** | Yes (`setPrivacyEnabled(true)`) |
| PrivateWBTC | `setPrivacyEnabled(false)` | **NONE** | Yes |
| PrivateWETH | `setPrivacyEnabled(false)` | **NONE** | Yes |

PrivateOmniCoin's 7-day timelock prevents this attack (users have a week to notice and exit). The wrapper contracts are fully vulnerable.

**Privacy Impact:**

- Targeted deanonymization of specific users' private positions in specific assets.
- The attack can be performed and reversed quickly, leaving minimal traces.
- Users have no warning and no opportunity to exit before the reveal.

**Severity Justification:** MEDIUM. Requires admin key compromise, which is the highest-privilege attack. But the instant toggle on wrapper contracts (vs 7-day timelock on PrivateOmniCoin) makes this attack practical if admin keys are compromised.

---

### ATK-09: PrivateDEX Metadata Leakage for Trade Deanonymization

**Severity:** MEDIUM
**Contracts:** `PrivateDEX.sol`, `PrivateDEXSettlement.sol`
**Feasibility:** HIGH -- requires only on-chain event and state monitoring

#### Description

While the PrivateDEX encrypts order amounts and prices, it leaks substantial metadata that enables trade pattern analysis and partial deanonymization.

**Leaked metadata per order:**

```solidity
// PrivateDEX.sol -- PrivateOrder struct
struct PrivateOrder {
    bytes32 orderId;     // PUBLIC: unique identifier
    address trader;      // PUBLIC: trader address
    bool isBuy;          // PUBLIC: order direction
    string pair;         // PUBLIC: trading pair (e.g., "XOM/USDC")
    ctUint64 encAmount;  // ENCRYPTED: order amount
    ctUint64 encPrice;   // ENCRYPTED: order price
    uint256 timestamp;   // PUBLIC: submission time
    OrderStatus status;  // PUBLIC: OPEN/FILLED/CANCELLED
    ctUint64 encFilled;  // ENCRYPTED: filled amount
    uint256 expiry;      // PUBLIC: expiration time
    ctUint64 encMinFill; // ENCRYPTED: minimum fill
}
```

**What an observer knows per order:**
1. **WHO** is trading (trader address).
2. **WHAT** they are trading (pair string, e.g., "XOM/USDC").
3. **WHICH DIRECTION** (isBuy: true = buying, false = selling).
4. **WHEN** they placed the order (timestamp).
5. **HOW LONG** the order is valid (expiry).
6. **CURRENT STATUS** (OPEN, FILLED, CANCELLED).

**What remains private:**
1. Order amount.
2. Order price.
3. Filled amount.
4. Minimum fill size.

**Attack via pattern analysis:**

1. **User Profiling:** An adversary can build a complete trading profile for any address: which pairs they trade, how frequently, buy/sell ratio, typical order duration (timestamp to cancellation/fill), and trading counterparties (from settlement events).

2. **MATCHER_ROLE Boolean Leakage:** The `canOrdersMatch()` function (line 458) calls MPC comparison and decrypts the boolean result:
   ```solidity
   bool canMatch = MpcCore.decrypt(gtCanMatch);
   ```
   The MATCHER observes which order pairs CAN match (price comparison result). Over many queries, the MATCHER can build a binary search tree to narrow down each order's price range. For example:
   - If Order A (buy) matches Order B (sell), then A's price >= B's price.
   - If Order A does NOT match Order C (sell), then A's price < C's price.
   - With enough comparisons, the MATCHER can bracket each order's price to within a small range.

3. **Settlement Correlation:** `TradeSettled` events from PrivateDEXSettlement reveal `(buyer, seller, pair, orderId1, orderId2)`. Combined with order metadata, this reveals the complete trade graph: who traded with whom, on which pairs, and when.

**Privacy Impact:**

- While amounts and prices remain encrypted, the metadata leakage enables significant trade deanonymization.
- The MATCHER_ROLE has a privileged position: it can perform arbitrary price comparisons to extract price information.
- Combined with external price data (from centralized exchanges), an adversary can estimate order amounts: if a user places a buy order on XOM/USDC that matches against a sell order at the current market price, the amount is likely close to the on-chain balance changes visible in subsequent `convertToPublic` calls.

**Severity Justification:** MEDIUM. Amounts and prices remain encrypted, which is the core privacy guarantee. However, the metadata leakage is substantial enough to enable meaningful trade analysis, especially by the MATCHER.

**Recommendation:**

1. Consider obfuscating the `pair` field (hash instead of plaintext string, with known-pair registry).
2. Limit the number of `canOrdersMatch()` queries per order to prevent binary-search price discovery.
3. Batch settlements to reduce temporal correlation.
4. Consider rotating MATCHER_ROLE to limit the duration any single entity has comparison oracle access.

---

### ATK-10: Cross-Chain Privacy Leakage via OmniBridge

**Severity:** MEDIUM
**Contracts:** `OmniBridge.sol`, `OmniPrivacyBridge.sol`, `PrivateOmniCoin.sol`
**Feasibility:** MEDIUM -- requires cross-chain event correlation

#### Description

The OmniBridge's `initiateTransfer()` includes a `usePrivateToken` parameter that signals whether the transfer involves pXOM (privacy-enabled) or XOM (public). This flag is:

1. Stored on-chain: `transferUsePrivacy[transferId] = usePrivateToken` (line 468).
2. Included in the Warp message payload: line 807 `transferUsePrivacy[transferId]`.
3. Processed on the destination chain: `processWarpMessage()` decodes `usePrivateToken` (line 495).

**Privacy leakage:**

- Any observer can identify which cross-chain transfers involve privacy tokens by checking `transferUsePrivacy[transferId]`.
- This flags privacy-seeking users for enhanced monitoring.
- The `TransferInitiated` event includes the full amount in plaintext (line 458-465), so the observer knows both the amount AND the privacy intent.

**Cross-chain correlation attack:**

1. Observer monitors `TransferInitiated` events on Chain A where `usePrivateToken = true`.
2. Observer monitors `TransferCompleted` events on Chain B.
3. Observer correlates by `transferId` (same ID on both chains via Warp message).
4. Observer now knows: Source address (Chain A), destination address (Chain B), exact amount, and that the user intends to use privacy.
5. Observer monitors destination address for subsequent `convertXOMtoPXOM` (OmniPrivacyBridge) or `convertToPrivate` (PrivateOmniCoin) events.

**Severity Justification:** MEDIUM. The `usePrivateToken` flag is a metadata leak that identifies privacy-seeking users. Combined with the plaintext amounts in bridge events, this creates a complete pre-privacy paper trail.

**Recommendation:**

1. Remove the `usePrivateToken` parameter from the public bridge interface. Instead, always bridge as XOM and let users convert to pXOM on the destination chain independently.
2. If pXOM bridging is needed, consider a separate privacy-specific bridge that does not expose the privacy flag in events.

---

### ATK-11: Front-Running Privacy Conversions

**Severity:** LOW
**Contracts:** `OmniPrivacyBridge.sol`, `PrivateOmniCoin.sol`, `PrivateDEX.sol`
**Feasibility:** MEDIUM -- requires mempool monitoring

#### Description

Privacy conversion transactions in the mempool reveal the user's intent to enter or exit the privacy domain. A front-runner can exploit this information.

**Scenario 1: Front-running `convertXOMtoPXOM`**

1. Adversary monitors the mempool for `convertXOMtoPXOM(amount)` calls.
2. The `amount` parameter is visible in the pending transaction's calldata.
3. Adversary now knows that a specific address is about to convert `amount` XOM to pXOM.
4. If the adversary is also a MATCHER on the PrivateDEX, they can correlate this deposit with subsequent order submissions from the same address.

**Scenario 2: Front-running `convertToPublic`**

1. Adversary monitors for `convertToPublic()` calls on PrivateOmniCoin.
2. The calldata does not include the amount (it is encrypted in MPC), but the adversary knows the user is exiting the privacy domain.
3. Adversary monitors the `ConvertedToPublic` event (which will include the amount) and can immediately front-run any subsequent DEX trades or transfers.

**Scenario 3: Front-running `convertPXOMtoXOM`**

1. Adversary monitors for `convertPXOMtoXOM(amount)` calls on OmniPrivacyBridge.
2. The `amount` parameter is visible in pending calldata.
3. Adversary knows the user is about to receive `amount` XOM.
4. If XOM has an AMM/DEX with public pricing, the adversary can sandwich this conversion.

**Existing Protections:**

- Private mempool / confidential transaction submission (if implemented by validators).
- No on-chain protection against front-running of privacy conversions.

**Severity Justification:** LOW. Front-running privacy conversions is an MEV opportunity but does not directly break privacy. The main risk is information leakage via mempool observation, which is a standard blockchain challenge not specific to this protocol.

---

### ATK-12: Compliance vs Privacy -- Forced Deanonymization Paths

**Severity:** MEDIUM
**Contracts:** All privacy contracts
**Feasibility:** MEDIUM -- requires admin/governance action

#### Description

The privacy architecture includes multiple admin-controlled mechanisms that can be used for forced deanonymization, either for legitimate compliance or for abuse.

**Forced Deanonymization Mechanisms:**

1. **Privacy Disable (PrivateOmniCoin):** `proposePrivacyDisable()` -> 7-day wait -> `executePrivacyDisable()`. After disable, all encrypted balances become recoverable via shadow ledger. The 7-day delay provides warning but also publicly signals that deanonymization is imminent, potentially causing a bank run.

2. **Privacy Disable (Wrappers):** Instant via `setPrivacyEnabled(false)`. No warning period. Admin can deanonymize all positions immediately.

3. **Shadow Ledger Direct Read (PrivateOmniCoin):** `getPrivateDepositBalance(user)` is a public function that returns the shadow ledger balance for any user. This is plaintext and reflects deposits (and transfers, due to ATK-H08). Any observer can read any user's approximate private balance.

4. **Shadow Ledger Read (Wrappers):** `getShadowLedgerBalance(user)` is restricted to owner or admin. Admin can selectively read any user's shadow ledger balance without disabling privacy globally.

5. **Admin Balance Inspection (Wrappers):** `privateBalanceOf(account)` returns `ctUint64` for admin. While this is ciphertext, admin can use it in MPC operations to derive the plaintext via comparison with known values.

6. **Contract Upgrade (UUPS):** Admin can upgrade any privacy contract to a new implementation that removes all privacy features, exposes all storage slots, or adds backdoor functions. The ossification mechanism (`ossify()`) prevents this once invoked, but it must be called proactively.

**Cross-Contract Compliance Scenario:**

A government authority demands the protocol reveal a specific user's total private holdings. The admin can:

1. Read PrivateOmniCoin shadow ledger: `getPrivateDepositBalance(user)` -- public, no role needed.
2. Read PrivateUSDC shadow ledger: `getShadowLedgerBalance(user)` -- admin role needed.
3. Read PrivateWBTC shadow ledger: `getShadowLedgerBalance(user)` -- admin role needed.
4. Read PrivateWETH shadow ledger: `getShadowLedgerBalance(user)` -- admin role needed.
5. Total private holdings across all assets are now known (subject to shadow ledger accuracy).

The user has no notification, no recourse, and no ability to exit before the reveal (for wrappers).

**Severity Justification:** MEDIUM. These mechanisms serve legitimate purposes (emergency recovery, compliance), but they undermine the privacy guarantees marketed to users. The asymmetry between PrivateOmniCoin (7-day timelock, public shadow ledger) and wrappers (instant disable, admin-restricted but readable shadow ledger) creates confusion about actual privacy levels.

**Recommendation:**

1. **Document privacy limitations clearly** for users: "Admin can read shadow ledger balances. Privacy disable can be triggered with [7 days / instant] notice."
2. **Ossify contracts as soon as practical** to remove upgrade-based deanonymization paths.
3. **Consider immutable privacy guarantee:** Once ossified, the privacy features should be irremovable. Current ossification only prevents upgrades; it does not prevent `setPrivacyEnabled(false)` on wrappers.
4. **Add `ossifyPrivacy()` function** that permanently prevents privacy disable, separate from contract ossification.

---

## MPC Trust Boundary Analysis

### Trust Model

```
                    TRUSTED                         UNTRUSTED
                    =======                         =========

    COTI V2 MPC Network                   On-chain Observers
    - Garbled circuit execution            - Event monitoring
    - ctUint64 encryption/decryption       - Storage slot reading
    - Overflow-checked arithmetic          - Mempool inspection
    - Key share management                 - Cross-contract correlation
                                           - Cross-chain correlation
    Admin / Governance
    - DEFAULT_ADMIN_ROLE holders
    - BRIDGE_ROLE holders
    - MATCHER_ROLE holders
    - SETTLER_ROLE holders
    - OPERATOR_ROLE holders
```

### MPC Operations Used Across Contracts

| Operation | Contracts Using It | Privacy Implication |
|-----------|--------------------|---------------------|
| `MpcCore.onBoard(ctUint64)` | All privacy contracts | Loads ciphertext into garbled circuit |
| `MpcCore.offBoard(gtUint64)` | All privacy contracts | Stores garbled value back as ciphertext |
| `MpcCore.setPublic64(uint64)` | PrivateOmniCoin, PrivateDEX, Settlement | Creates garbled value from plaintext -- **amount visible to MPC nodes** |
| `MpcCore.decrypt(gtUint64)` | All privacy contracts | Decrypts to plaintext -- **amount visible to caller and MPC nodes** |
| `MpcCore.checkedAdd(gt, gt)` | All privacy contracts | Overflow-safe addition in garbled domain |
| `MpcCore.checkedSub(gt, gt)` | PrivateOmniCoin only | Overflow-safe subtraction |
| `MpcCore.sub(gt, gt)` | PrivateUSDC/WBTC/WETH | **UNCHECKED subtraction** -- relies on prior `ge` check |
| `MpcCore.checkedMul(gt, gt)` | PrivateDEXSettlement | Overflow-safe multiplication for fee calc |
| `MpcCore.div(gt, gt)` | PrivateDEXSettlement | Division for fee splitting |
| `MpcCore.ge(gt, gt)` | PrivateDEX, Settlement, Wrappers | Greater-or-equal comparison -- **returns garbled bool** |
| `MpcCore.gt(gt, gt)` | PrivateDEX | Greater-than comparison |
| `MpcCore.eq(gt, gt)` | Settlement | Equality check |
| `MpcCore.min(gt, gt)` | PrivateDEX | Minimum of two values |
| `MpcCore.decrypt(gtBool)` | PrivateDEX | Decrypts boolean -- **reveals comparison result to caller** |

### Critical Trust Assumptions

1. **MPC Correctness:** All garbled circuit computations produce correct results. If `checkedAdd` returns a value without reverting, it is assumed the sum did not overflow. If `ge` returns true, it is assumed `a >= b`. There is no on-chain verification of MPC results.

2. **MPC Confidentiality:** MPC nodes do not reveal intermediate values to unauthorized parties. The protocol assumes that even if individual MPC nodes are compromised, the garbled circuit protocol prevents value extraction without a threshold of key shares.

3. **MPC Availability:** If MPC becomes unavailable, the emergency recovery path uses shadow ledgers (PrivateOmniCoin: accurate; wrappers: incomplete). Extended MPC outages could result in fund loss for wrapper contract users who received funds via `privateTransfer`.

4. **setPublic64 Exposure:** When a user calls `convertToPrivate(amount)`, the plaintext amount is passed to `MpcCore.setPublic64(uint64(scaledAmount))`. This means the COTI MPC nodes see the plaintext amount during onboarding. Privacy only exists AFTER the value is in the garbled domain and before it is decrypted.

---

## Mitigations Already Present

| Mitigation | Contracts | Effectiveness |
|-----------|-----------|---------------|
| MPC encryption of balances/amounts | All privacy contracts | HIGH (if MPC is trustworthy) |
| Shadow ledger with ATK-H08 transfer tracking | PrivateOmniCoin only | MEDIUM (enables emergency recovery; leaks amount in event) |
| 7-day privacy disable timelock | PrivateOmniCoin only | HIGH (prevents surprise deanonymization for XOM) |
| `checkedAdd` overflow protection | All privacy contracts | HIGH (prevents silent overflow) |
| `whenNotPaused` on all state-changing functions | All privacy contracts | HIGH (emergency stop capability) |
| `nonReentrant` on all external functions | All privacy contracts | HIGH (prevents reentrancy) |
| UUPS with ossification capability | All privacy contracts | HIGH (immutability commitment available) |
| `PrivateTransfer` event without amount | PrivateOmniCoin | LOW (moot due to `PrivateLedgerUpdated` leaking the amount) |
| `PrivateEscrowCreated` event without amount | MinimalEscrow | LOW (moot due to plaintext `escrow.amount` storage) |
| Daily volume limits on bridge | OmniPrivacyBridge | LOW (rate limiter, not privacy protection) |
| EIP-191 trader signatures | PrivateDEXSettlement | MEDIUM (consent verification, not amount verification) |
| Admin `privateBalanceOf` restriction | PrivateOmniCoin (owner-only) | MEDIUM (wrappers allow admin access) |

---

## Recommended Fixes

### Priority 1 -- Critical Privacy Leaks (Before Mainnet)

| # | Fix | Contracts | Effort | Impact |
|---|-----|-----------|--------|--------|
| 1 | Remove `scaledAmount` from `PrivateLedgerUpdated` event | PrivateOmniCoin | Trivial | Closes ATK-02: stops plaintext transfer amount emission |
| 2 | Do not store plaintext amount for private escrows | MinimalEscrow | Medium | Closes ATK-03: eliminates on-chain amount exposure |
| 3 | Implement 7-day privacy disable timelock on wrappers | PrivateUSDC/WBTC/WETH | Medium | Closes ATK-05 (partial) and ATK-08: prevents instant forced deanonymization |
| 4 | Fix dust double-counting bug in wrappers | PrivateWBTC, PrivateWETH | Low | Closes accounting bug that compounds with emergency recovery |

### Priority 2 -- Significant Privacy Improvements (Before Mainnet)

| # | Fix | Contracts | Effort | Impact |
|---|-----|-----------|--------|--------|
| 5 | Implement shadow ledger transfer tracking (ATK-H08) on wrappers | PrivateUSDC/WBTC/WETH | Medium | Closes ATK-05 (full): reliable emergency recovery for wrapped tokens |
| 6 | Restrict `privateBalanceOf` to owner-only on wrappers | PrivateUSDC/WBTC/WETH | Trivial | Eliminates admin balance inspection vector |
| 7 | Remove `usePrivateToken` flag from OmniBridge events and Warp payload | OmniBridge | Low | Closes ATK-10: stops flagging privacy-seeking users in cross-chain transfers |
| 8 | Add `ossifyPrivacy()` function that permanently prevents privacy disable | All privacy contracts | Medium | Strengthens post-ossification privacy guarantees |

### Priority 3 -- Architectural Improvements (Post-Mainnet)

| # | Fix | Contracts | Effort | Impact |
|---|-----|-----------|--------|--------|
| 9 | Minimize bridge event data (remove plaintext amounts from OmniPrivacyBridge events) | OmniPrivacyBridge | Medium | Reduces ATK-01: makes bridge amount correlation harder |
| 10 | Add rate limiting to MATCHER `canOrdersMatch` queries per order | PrivateDEX | Medium | Reduces ATK-09: limits binary-search price discovery |
| 11 | Add settlement solvency verification (conserved total check) | PrivateDEXSettlement | High | Reduces ATK-06: adds verifiability to phantom collateral model |
| 12 | Consider ZK proofs for balance conservation checks | Cross-system | Very High | Reduces ATK-07: provides MPC-independent verification |

---

## Conclusion

The OmniCoin protocol's privacy architecture relies on COTI V2 MPC for computational privacy, which is sound in isolation. However, the **smart contract layer surrounding MPC** introduces multiple privacy leakages that significantly weaken the system's overall privacy guarantees:

1. **The privacy bridge boundary is fully transparent.** Bridge conversion events (ATK-01) expose exact amounts, fee calculations, and user addresses. An observer can track every XOM-to-pXOM conversion and its inverse.

2. **The shadow ledger fix (ATK-H08) trades recovery for privacy.** PrivateOmniCoin's `PrivateLedgerUpdated` event (ATK-02) emits plaintext transfer amounts, effectively making all pXOM transfers as transparent as public transfers for any event-monitoring adversary.

3. **Private escrows provide no actual amount privacy.** MinimalEscrow's `createPrivateEscrow()` (ATK-03) stores the decrypted amount on-chain in plaintext, making the "private" escrow label misleading.

4. **Privacy protections are inconsistent across token types.** PrivateOmniCoin has materially stronger protections (7-day timelock, shadow ledger tracking, owner-only balance queries) than the wrapper contracts (instant privacy disable, no shadow ledger tracking, admin-accessible balances). Users may not be aware of these differences.

5. **The MPC trust assumption is all-or-nothing.** A single MPC compromise exposes every encrypted value across every privacy contract (ATK-07). There are no defense-in-depth mechanisms (ZK proofs, TEEs, multi-party independent verification) to provide privacy guarantees independent of MPC correctness.

**Bottom Line:** For mainnet deployment, the protocol should prioritize the Priority 1 fixes (remove plaintext from events and storage, add timelock to wrappers, fix dust accounting). These are achievable with moderate effort and significantly improve the privacy posture. The architectural improvements (Priority 3) represent longer-term hardening that should be pursued post-launch.

Users should be clearly informed that the privacy guarantees are:
- **Strong** within the MPC domain (encrypted balances, encrypted arithmetic).
- **Weak** at domain boundaries (bridge conversions, escrow creation, public/private conversions).
- **Absent** for bridge event observers, PrivateLedgerUpdated event consumers, and escrow state readers.
- **Entirely dependent** on COTI V2 MPC infrastructure integrity.

---

*Generated by Claude Code Audit Agent -- Phase 2 Pre-Mainnet Cross-Contract Privacy Analysis*
*Contracts analyzed: 10 contracts, ~8,601 lines of Solidity*
*Audit reports referenced: 10 Round 6 individual audits (2026-03-10)*
*Attack paths documented: 12 cross-system vectors*
*Date: 2026-03-10*
