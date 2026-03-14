# Cross-System Adversarial Review: Privacy Attacks

**Date:** 2026-03-13 21:07 UTC
**Auditor:** Claude Opus 4.6 (Round 7 Cross-System Review)
**Scope:** Privacy attack vectors across the OmniBazaar smart contract suite
**Contracts Reviewed:**
- `contracts/PrivateOmniCoin.sol` (pXOM)
- `contracts/PrivateDEX.sol`
- `contracts/privacy/PrivateDEXSettlement.sol`
- `contracts/OmniPrivacyBridge.sol`
- `contracts/privacy/PrivateUSDC.sol`
- `contracts/privacy/PrivateWBTC.sol`
- `contracts/privacy/PrivateWETH.sol`
- `contracts/OmniCoin.sol` (XOM, for cross-contract event analysis)

---

## Executive Summary

The OmniBazaar privacy suite uses COTI V2 MPC (Multi-Party Computation)
garbled circuits to encrypt token balances and transfer amounts on-chain. This
review examines cross-system privacy attack vectors -- how an adversary can
combine information from multiple contracts and on-chain observables to
deanonymize users or infer private transaction details.

**Overall Assessment:** The privacy architecture has been significantly
hardened in prior audit rounds (ATK-H05 through ATK-H08 fixes are visible in
the code). However, several cross-system information leakage vectors remain,
including one critical inconsistency between PrivateOmniCoin and its sibling
wrapped-asset contracts that completely undermines pXOM privacy.

| Severity | Count |
|----------|-------|
| CRITICAL | 1     |
| HIGH     | 3     |
| MEDIUM   | 3     |
| LOW      | 3     |
| INFO     | 3     |

---

## CRITICAL Findings

### PRIV-C01: PrivateOmniCoin `privateDepositLedger` Is Public -- Complete Balance Deanonymization

**Severity:** CRITICAL
**Contracts:** `PrivateOmniCoin.sol` (line 180)
**Status:** CONFIRMED BUG

**Description:**

In `PrivateOmniCoin.sol`, the shadow ledger is declared as:

```solidity
mapping(address => uint256) public privateDepositLedger;  // line 180
```

This mapping is `public`, meaning anyone can query any user's plaintext
deposit total by calling the auto-generated getter
`privateDepositLedger(address)`. Furthermore, the ATK-H08 fix (line 600-614)
updates this ledger on every `privateTransfer()`, meaning it now tracks not
just deposits but also the full running balance for every user who has
received private transfers.

In contrast, the sibling contracts (PrivateUSDC, PrivateWBTC, PrivateWETH)
correctly declare their shadow ledgers as `private` with access-controlled
getters:

```solidity
// PrivateUSDC.sol line 147
mapping(address => uint256) private _shadowLedger;

// PrivateWBTC.sol line 154
mapping(address => uint256) private _shadowLedger;

// PrivateWETH.sol line 153
mapping(address => uint256) private _shadowLedger;
```

These contracts also have `getShadowLedgerBalance()` functions restricted to
the account owner and admin.

**Impact:**

This completely defeats the privacy guarantees of pXOM. Any observer can:
1. Query `privateDepositLedger(userAddress)` to see the user's plaintext
   private balance in scaled (6-decimal) units.
2. Monitor changes to this value over time to track exact transfer amounts.
3. Since ATK-H08 updates the ledger on `privateTransfer()`, both the sender's
   decrease and recipient's increase are visible, revealing transfer amounts
   in the clear.
4. Combined with the `PrivateTransfer(from, to)` event (which already reveals
   the transaction graph), an observer now has **both** the parties and the
   exact amounts -- effectively zero privacy for pXOM.

**Root Cause:**

The `privateDepositLedger` mapping was declared `public` in the original
contract. When the ATK-H08 fix was applied to update the ledger during
`privateTransfer()`, the visibility was not changed to `private`. The sibling
contracts (PrivateUSDC, PrivateWBTC, PrivateWETH) were written later and
correctly used `private` visibility with access-controlled getters.

**Recommendation:**

1. Change the mapping visibility from `public` to `private`:

```solidity
mapping(address => uint256) private privateDepositLedger;
```

2. Add an access-controlled getter matching the sibling pattern:

```solidity
function getShadowLedgerBalance(
    address account
) external view returns (uint256) {
    if (
        msg.sender != account &&
        !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)
    ) {
        revert OnlyAccountOwner();
    }
    return privateDepositLedger[account];
}
```

3. **IMPORTANT:** Because this is a UUPS upgradeable proxy, changing a
   `public` mapping to `private` does NOT change the storage layout -- it
   only removes the auto-generated getter from the ABI. However, the storage
   slot values remain readable via `eth_getStorageAt()` by anyone who knows
   the slot computation. This is an inherent limitation: on a public
   blockchain, **no storage is truly private**. The access-controlled getter
   prevents casual querying but determined adversaries with direct RPC access
   can still compute the storage slot and read the value.

4. **Longer-term mitigation:** Consider encrypting the shadow ledger values
   themselves using a simple symmetric key held by the contract admin, or
   move emergency recovery entirely off-chain (signed attestations from
   validators about MPC state).

**Note on storage-level observability:** Even with `private` visibility, the
`privateDepositLedger` values in PrivateOmniCoin and the `_shadowLedger`
values in PrivateUSDC/PrivateWBTC/PrivateWETH are all readable via direct
storage slot access (`eth_getStorageAt`). This applies equally to all four
contracts. The `private` keyword only removes the auto-generated Solidity
getter; it does not encrypt on-chain storage. This is noted as INFO-01 below.

---

## HIGH Findings

### PRIV-H01: Wrapped Asset Contracts Use Unchecked `MpcCore.sub()` Instead of `checkedSub()`

**Severity:** HIGH
**Contracts:** `PrivateUSDC.sol` (lines 432, 486), `PrivateWBTC.sol` (lines
472, 544), `PrivateWETH.sol` (lines 471, 543)
**Status:** CONFIRMED BUG

**Description:**

PrivateOmniCoin uses `MpcCore.checkedSub()` for all balance subtraction
operations (the M-01 audit fix). However, the three wrapped asset contracts
all use the unchecked `MpcCore.sub()`:

```solidity
// PrivateUSDC.sol convertToPublic() line 432
gtUint64 gtNew = MpcCore.sub(gtBalance, encryptedAmount);

// PrivateUSDC.sol privateTransfer() line 486
gtUint64 gtNewSender = MpcCore.sub(gtSender, encryptedAmount);

// PrivateWBTC.sol convertToPublic() line 472
gtUint64 gtNew = MpcCore.sub(gtBalance, encryptedAmount);

// PrivateWBTC.sol privateTransfer() line 544
gtUint64 gtNewSender = MpcCore.sub(gtSender, encryptedAmount);

// PrivateWETH.sol convertToPublic() line 471
gtUint64 gtNew = MpcCore.sub(gtBalance, encryptedAmount);

// PrivateWETH.sol privateTransfer() line 543
gtUint64 gtNewSender = MpcCore.sub(gtSender, encryptedAmount);
```

While each call site is preceded by a `MpcCore.ge()` balance-sufficiency
check followed by a `MpcCore.decrypt()` of the boolean result, the unchecked
`sub()` still creates a defense-in-depth gap. If there is any discrepancy
between the `ge()` check and the `sub()` operation (e.g., due to MPC race
conditions, garbled circuit failures, or future COTI runtime bugs), the
unchecked `sub()` will silently wrap around instead of reverting, potentially
creating phantom balances.

**Privacy relevance:** An adversary who can trigger a wrapping underflow on a
user's encrypted balance could force the user's balance to a predictable high
value (near uint64.max), making the ciphertext distinguishable and enabling
balance inference attacks.

**Impact:**
- Defense-in-depth failure: PrivateOmniCoin fixed this in M-01; the wrapped
  assets did not receive the same fix.
- Potential phantom balance creation in edge cases.
- Inconsistency between contracts of the same family creates confusion for
  auditors and future maintainers.

**Recommendation:**

Replace all `MpcCore.sub()` calls with `MpcCore.checkedSub()` in
PrivateUSDC, PrivateWBTC, and PrivateWETH, matching the PrivateOmniCoin M-01
fix:

```solidity
gtUint64 gtNew = MpcCore.checkedSub(gtBalance, encryptedAmount);
```

---

### PRIV-H02: Wrapped Asset Contracts Emit Plaintext Amounts in ConvertedToPrivate/ConvertedToPublic Events

**Severity:** HIGH
**Contracts:** `PrivateUSDC.sol` (lines 406, 451), `PrivateWBTC.sol` (lines
448, 495), `PrivateWETH.sol` (lines 447, 494)
**Status:** CONFIRMED DESIGN INCONSISTENCY

**Description:**

The wrapped asset contracts emit plaintext amounts in their conversion
events:

```solidity
// PrivateUSDC.sol
emit ConvertedToPrivate(msg.sender, amount);       // line 406
emit ConvertedToPublic(msg.sender, publicAmount);  // line 451

// PrivateWBTC.sol
emit ConvertedToPrivate(msg.sender, usedAmount);   // line 448
emit ConvertedToPublic(msg.sender, publicAmount);  // line 495

// PrivateWETH.sol
emit ConvertedToPrivate(msg.sender, usedAmount);   // line 447
emit ConvertedToPublic(msg.sender, publicAmount);  // line 494
```

Meanwhile, OmniPrivacyBridge deliberately omits amounts from its events:

```solidity
// OmniPrivacyBridge.sol
/// @dev Amount details intentionally omitted to protect user privacy.
event ConvertedToPrivate(address indexed user);     // No amount
event ConvertedToPublic(address indexed user);      // No amount
```

PrivateOmniCoin itself also emits amounts in `ConvertedToPrivate` and
`ConvertedToPublic` (lines 464, 538), though the Round 6 audit fixed the
`PrivateLedgerUpdated` event to remove plaintext amounts (PRIV-ATK-02 fix at
line 285-293).

**Impact:**

Any on-chain observer or block explorer can see the exact amounts users are
converting between public and private modes for USDC, WBTC, and WETH. This
reveals:
- The user's privacy-seeking behavior and the exact size of their private
  position.
- When combined with `PrivateTransfer(from, to)` events and timing
  correlation, this allows inference of private transfer amounts (e.g., if
  Alice converts 100 USDC to private, then a PrivateTransfer from Alice to
  Bob occurs, then Bob converts 95 USDC to public, the transfer amount is
  approximately 95 USDC).

**Recommendation:**

Remove the `amount` parameter from `ConvertedToPrivate` and
`ConvertedToPublic` events in PrivateUSDC, PrivateWBTC, and PrivateWETH,
matching the OmniPrivacyBridge pattern:

```solidity
event ConvertedToPrivate(address indexed user);
event ConvertedToPublic(address indexed user);
```

Similarly, consider removing amounts from `BridgeMint` and `BridgeBurn`
events, as these also reveal the exact amounts entering/leaving the privacy
system.

---

### PRIV-H03: ERC20 Transfer Events From _burn/_mint in PrivateOmniCoin Leak Bridge Amounts

**Severity:** HIGH
**Contracts:** `PrivateOmniCoin.sol`, `OmniPrivacyBridge.sol`,
`OmniCoin.sol`

**Description:**

The XOM-to-pXOM conversion flow traverses multiple contracts, each of which
emits ERC20 Transfer events with plaintext amounts:

**Step 1 -- OmniPrivacyBridge.convertXOMtoPXOM():**
- Calls `omniCoin.safeTransferFrom(caller, address(this), amount)`.
- OmniCoin (OpenZeppelin ERC20) emits `Transfer(caller, bridgeAddress, amount)`.
- Bridge emits `ConvertedToPrivate(caller)` -- no amount, good.

**Step 2 -- Bridge mints pXOM:**
- Calls `privateOmniCoin.mint(caller, amountAfterFee)`.
- PrivateOmniCoin (ERC20Upgradeable) emits `Transfer(address(0), caller, amountAfterFee)`.

**Step 3 -- User converts pXOM to encrypted:**
- Calls `PrivateOmniCoin.convertToPrivate(amountAfterFee)`.
- `_burn` emits `Transfer(caller, address(0), actualBurnAmount)`.
- Contract emits `ConvertedToPrivate(caller, actualBurnAmount)`.

All three steps produce ERC20 Transfer events with exact plaintext amounts.
The bridge's deliberate event privacy is completely undermined because the
underlying ERC20 Transfer events expose the same data.

**Impact:**

- Any block explorer, analytics service, or monitoring script can reconstruct
  every privacy conversion with full amount detail by monitoring standard
  ERC20 Transfer events.
- Users who believe their conversion amounts are private are operating under a
  false assumption.
- The OmniPrivacyBridge's event privacy design is rendered meaningless.

**Recommendation:**

This is a fundamental limitation of ERC20 composability -- Transfer events
cannot be suppressed without breaking the ERC20 standard. The project
documentation should explicitly state that **deposit/withdrawal amounts are
always public** and that privacy only applies to **encrypted balances and
private transfers** after conversion.

Possible architectural mitigations:
1. **Relayer service:** Users send XOM to a relayer contract that batches
   conversions, breaking the direct address link.
2. **Fixed-denomination deposits:** Allow only specific denomination sizes
   (e.g., 100, 1000, 10000 XOM) to create a larger anonymity set.
3. **Single-step conversion:** The bridge could call `convertToPrivate`
   internally, reducing the number of separate observable transactions.

---

## MEDIUM Findings

### PRIV-M01: Cross-Contract Timing Correlation Between Bridge and Privacy Conversions

**Severity:** MEDIUM
**Contracts:** `OmniPrivacyBridge.sol`, `PrivateOmniCoin.sol`,
`PrivateUSDC.sol`, `PrivateWBTC.sol`, `PrivateWETH.sol`

**Description:**

The XOM-to-pXOM privacy flow requires two sequential transactions:
1. `OmniPrivacyBridge.convertXOMtoPXOM(amount)` -- Locks XOM, mints public
   pXOM (publicly visible amount in ERC20 Transfer events).
2. `PrivateOmniCoin.convertToPrivate(amount)` -- Burns public pXOM, creates
   encrypted balance.

An adversary monitoring the mempool or block events can correlate these two
transactions by:
- **Timing:** Both transactions come from the same `msg.sender` within a
  short time window.
- **Amount matching:** The `ConvertedToPrivate` event in PrivateOmniCoin
  emits `actualBurnAmount` (line 464), which matches `amountAfterFee` from
  the bridge operation.
- **Cumulative state changes:** The bridge's `totalConvertedToPrivate`
  counter increments by the exact pre-fee amount, and the pXOM public
  balance changes are visible on-chain.

This same pattern applies to the wrapped tokens: PrivateUSDC/WBTC/WETH have
a similar two-step flow (bridgeMint -> convertToPrivate) that is trivially
correlatable.

**Impact:**

Even though the bridge deliberately omits amounts from its events, the amount
is recoverable from:
- The PrivateOmniCoin `ConvertedToPrivate(user, actualBurnAmount)` event.
- The bridge's `totalConvertedToPrivate` state variable (diff between
  successive reads).
- ERC20 `Transfer` events from the underlying XOM token during
  `safeTransferFrom`.

**Recommendation:**

1. Remove the amount from PrivateOmniCoin's `ConvertedToPrivate` event.
2. Consider a single-transaction flow where the bridge calls
   `convertToPrivate` internally, reducing the timing correlation window.
3. Implement a batching/delay service at the Validator layer to aggregate
   multiple users' conversions.

---

### PRIV-M02: PrivateDEX Order Metadata Reveals Trading Patterns and Identity

**Severity:** MEDIUM
**Contracts:** `PrivateDEX.sol`

**Description:**

While order amounts and prices are encrypted, the following order metadata is
publicly visible:

1. **Trader address** (`order.trader`) -- public.
2. **Trading pair** (`order.pair`) -- public string (e.g., "pXOM-USDC").
3. **Buy/Sell direction** (`order.isBuy`) -- public boolean.
4. **Timestamps** (`order.timestamp`, `order.expiry`) -- public.
5. **Order status** (`order.status`) -- public enum.
6. **Active order count** (`activeOrderCount[trader]`) -- public mapping.

Combined with the `PrivateOrderSubmitted(orderId, trader, pair)` and
`PrivateOrderMatched(buyOrderId, sellOrderId, tradeId)` events, an adversary
can construct a detailed trading profile:

- Which pairs a user trades.
- Whether they are buying or selling.
- When they are active (timing patterns).
- How many open orders they maintain.
- Which specific orders match with which counterparties (linking buyer and
  seller identities for every trade).

The `PrivateOrderMatched` event is particularly damaging because it links the
`buyOrderId` and `sellOrderId` together, and the corresponding orders contain
the public `trader` addresses. This means **every matched trade reveals the
exact buyer-seller pair**.

**Impact:**

While amounts and prices remain hidden, the transaction graph (who trades
with whom, in which direction, at what times) is fully public. For assets
with limited liquidity, this is often sufficient to infer approximate amounts
from the order flow context.

**Recommendation:**

1. Consider encrypting the `isBuy` field (make it a ctBool if COTI supports
   encrypted booleans in storage).
2. Use a relayer/aggregator pattern for order submission so the
   `PrivateOrderSubmitted` event shows the relayer address, not the trader.
3. Acknowledge in documentation that PrivateDEX provides **amount and price
   privacy** but NOT **identity or activity privacy**.

---

### PRIV-M03: MPC Node Collusion Breaks All Privacy Guarantees (Trust Model)

**Severity:** MEDIUM (architectural/trust model)
**Contracts:** All contracts using `MpcCore`

**Description:**

COTI V2's MPC garbled circuits operate as a network-level feature. The
security depends on the **honest majority assumption** among MPC nodes. If a
sufficient threshold of MPC nodes collude:

1. **All encrypted balances become readable:** Colluding nodes can
   reconstruct the encryption keys and decrypt every `ctUint64` value
   in every contract.
2. **All private transfers become traceable:** Transfer amounts, currently
   hidden, become visible.
3. **DEX order book fully exposed:** Encrypted prices and amounts in
   PrivateDEX become readable, enabling front-running.
4. **PrivateDEXSettlement collateral revealed:** Encrypted trader and
   solver collateral amounts become visible.
5. **Retroactive exposure:** Unlike zero-knowledge proofs, garbled circuits
   do not provide forward secrecy. Compromised keys allow decryption of all
   past transactions.

**Key Concerns:**

- OmniBazaar validators serve as the computation/gateway infrastructure. If
  a single entity operates multiple validators (or bribes operators), the MPC
  threshold could be compromised.
- The COTI network's own MPC nodes are a separate trust domain. The project
  implicitly trusts COTI's node network integrity.
- Users cannot detect that their privacy has been compromised.

**Existing Mitigations:**
- The 7-day privacy disable timelock (ATK-H07) gives users time to exit if
  MPC compromise is suspected.
- Validator staking requirements provide economic disincentive against
  collusion.

**Recommendation:**

1. Document the MPC trust model explicitly in user-facing documentation.
2. Implement monitoring for MPC node health and integrity (partially in
   Validator/src/services/PrivacyService.ts).
3. Consider adding ZK-SNARK proofs for critical operations as a
   defense-in-depth layer.
4. Ensure MPC node operators are geographically and jurisdictionally
   distributed.

---

## LOW Findings

### PRIV-L01: OmniPrivacyBridge Cumulative State Variables Enable Volume Analysis

**Severity:** LOW
**Contracts:** `OmniPrivacyBridge.sol`

**Description:**

The bridge exposes several cumulative counters as public state variables:
- `totalLocked` -- Current amount of XOM locked in bridge.
- `totalConvertedToPrivate` -- Cumulative XOM bridged to pXOM.
- `totalConvertedToPublic` -- Cumulative pXOM bridged to XOM.
- `bridgeMintedPXOM` -- Outstanding bridge-minted pXOM.
- `totalFeesCollected` -- Accumulated fees.
- `currentDayVolume` -- Today's volume.

By querying these values before and after a known user's transaction, an
observer can deduce the exact amount converted, even though the events do not
include amounts.

**Impact:**

Undermines the privacy-preserving event design. Any user whose transaction is
the only one in a block (or in a known time window) has their amount fully
revealed via state variable diffs.

**Recommendation:**

Consider making `totalConvertedToPrivate`, `totalConvertedToPublic`, and
`currentDayVolume` internal with admin-only getters. Keep `totalLocked` and
`bridgeMintedPXOM` public for solvency transparency.

---

### PRIV-L02: PrivateDEXSettlement Collateral Records Expose Token Addresses and Participants

**Severity:** LOW
**Contracts:** `PrivateDEXSettlement.sol`

**Description:**

The `PrivateCollateral` struct stores `tokenIn`, `tokenOut`, `trader`, and
`solver` as public fields (lines 121-130). The `getPrivateCollateral()`
function returns the full struct without access control (line 896-899). The
`PrivateCollateralLocked` event also emits `tokenIn` and `tokenOut` (lines
264-271).

Additionally, the `PrivateIntentSettled` event reveals `trader`, `solver`,
and `settlementHash` (lines 278-283).

**Impact:**

An observer can determine:
- Which token pairs a trader is settling privately.
- The trader-solver relationship for every settlement.
- Settlement timing and frequency.

For thinly-traded pairs, this metadata may be sufficient to infer approximate
amounts from market context.

**Recommendation:**

Restrict `getPrivateCollateral()` to the trader, solver, or admin. Consider
whether `tokenIn`/`tokenOut` need to be in the event, or could be replaced
with a hashed identifier.

---

### PRIV-L03: Emergency Recovery Reveals Full Private Balance History

**Severity:** LOW
**Contracts:** All privacy contracts

**Description:**

When emergency recovery is triggered (`emergencyRecoverPrivateBalance`), the
`EmergencyPrivateRecovery(user, publicAmount)` event emits the full
plaintext balance being recovered:

```solidity
// PrivateOmniCoin.sol line 746
emit EmergencyPrivateRecovery(user, publicAmount);

// PrivateUSDC.sol line 609
emit EmergencyPrivateRecovery(user, balance);

// PrivateWBTC.sol line 667
emit EmergencyPrivateRecovery(user, publicAmount);

// PrivateWETH.sol line 666
emit EmergencyPrivateRecovery(user, publicAmount);
```

**Impact:**

If privacy is ever disabled (even temporarily), the emergency recovery
process reveals every recovering user's private balance in plaintext. This is
a retroactive privacy breach. The 7-day timelock (ATK-H07 fix) gives users
time to self-exit, but users who are offline or unaware may not exit in time.

**Recommendation:**

1. Consider allowing users to initiate their own emergency recovery (rather
   than admin-only).
2. Remove the amount from the `EmergencyPrivateRecovery` event.
3. Extend the timelock to 14 or 30 days for high-value contracts.

---

## INFO Findings

### PRIV-INFO-01: All Shadow Ledger Values Are Readable via `eth_getStorageAt`

**Severity:** INFO (Architectural Limitation)
**Contracts:** All privacy contracts

**Description:**

Even with `private` visibility on the `_shadowLedger` mappings in
PrivateUSDC, PrivateWBTC, and PrivateWETH, the values are stored in
unencrypted contract storage. Any user with RPC access can compute the
mapping slot (keccak256(abi.encode(address, slot))) and call
`eth_getStorageAt` to read the plaintext shadow ledger balance.

This is a fundamental limitation of the EVM storage model. The `private`
keyword only removes the Solidity getter from the ABI; it does not encrypt
storage.

**Impact:**

Sophisticated adversaries can read all shadow ledger balances for all
contracts regardless of Solidity visibility modifiers. This reduces the
access-control restrictions on `getShadowLedgerBalance()` to a speedbump
rather than a security boundary.

**Mitigation:**

- On COTI L2, storage may be encrypted by the MPC infrastructure. If so,
  this issue is mitigated when deployed on COTI chains.
- On Avalanche or other public EVM chains, there is no mitigation possible
  at the contract level. The shadow ledger will always leak plaintext
  balances.
- Consider documenting this limitation and advising users that maximum
  privacy requires deployment on the COTI L2.

---

### PRIV-INFO-02: PrivateTransfer Events Always Reveal Transaction Graph

**Severity:** INFO (Documented Limitation)
**Contracts:** `PrivateOmniCoin.sol`, `PrivateUSDC.sol`, `PrivateWBTC.sol`,
`PrivateWETH.sol`

**Description:**

All private transfer functions emit `PrivateTransfer(from, to)` events that
reveal the sender and recipient addresses. PrivateOmniCoin's ATK-H06
documentation (lines 236-248) explicitly acknowledges this limitation and
recommends the relayer service for relationship privacy.

**Impact:**

The transaction graph (who transacts with whom) is fully public across all
privacy contracts. Combined with timing analysis and amount inference from
other leakage vectors, this significantly reduces the effective anonymity set.

**Mitigation:**

Already documented. Use the RelayerSelectionService (off-chain) for
relationship privacy. Future COTI encrypted events will provide additional
protection.

---

### PRIV-INFO-03: PrivateDEX `canOrdersMatch()` and `executePrivateTrade()` Leak Information to MATCHER_ROLE

**Severity:** INFO
**Contracts:** `PrivateDEX.sol`

**Description:**

The `canOrdersMatch()` function (line 460) decrypts the boolean result of
price comparison, and `executePrivateTrade()` (line 640) decrypts multiple
boolean values (price compatibility, overfill checks, fully-filled checks).

While these are restricted to `MATCHER_ROLE` (validators), a compromised or
malicious validator holding `MATCHER_ROLE` can:
1. Probe order prices by attempting matches with known-price orders.
2. Observe which orders can and cannot match, narrowing price ranges.
3. Use the timing of fill/partial-fill status changes to infer order sizes.

**Mitigation:**

This is an inherent limitation of the matcher design. The matcher must know
whether prices are compatible to perform matching. The existing restriction
to `MATCHER_ROLE` limits the attack surface to trusted validators.

---

## Cross-System Attack Scenarios

### Scenario 1: Full Deanonymization via Public Shadow Ledger (PRIV-C01)

**Attacker:** Any on-chain observer.
**Steps:**
1. Call `PrivateOmniCoin.privateDepositLedger(victimAddress)` to get
   plaintext balance.
2. Monitor `PrivateTransfer(from, to)` events for the victim.
3. Query `privateDepositLedger` before and after each event to compute exact
   transfer amounts.
4. Result: Full transaction history with amounts for all pXOM users.

**Mitigation:** Fix PRIV-C01.

### Scenario 2: Bridge Amount Inference via ERC20 Transfer Events (PRIV-H03)

**Attacker:** Any on-chain observer.
**Steps:**
1. Monitor ERC20 Transfer events on OmniCoin contract.
2. When `Transfer(alice, bridgeAddress, 1000e18)` appears, Alice is converting
   1000 XOM to pXOM.
3. Verify via `Transfer(0x0, alice, 995e18)` on PrivateOmniCoin (mint of pXOM
   after 0.5% fee).
4. Watch for `Transfer(alice, 0x0, 995e18)` on PrivateOmniCoin (burn during
   convertToPrivate).
5. Result: Exact conversion amount known despite bridge event omitting amounts.

**Mitigation:** PRIV-H03 -- architectural limitation of ERC20.

### Scenario 3: Wrapped Asset Private Transfer Amount Inference (PRIV-H02)

**Attacker:** Any on-chain observer.
**Steps:**
1. Observe Alice calls `PrivateUSDC.convertToPrivate(1000000)` -- event
   reveals 1,000,000 USDC (6-dec = 1 USDC).
2. Observe `PrivateTransfer(Alice, Bob)` event shortly after.
3. Observe Bob calls `PrivateUSDC.convertToPublic()` -- event reveals
   950,000 USDC.
4. Infer transfer amount was approximately 950,000 (6-dec USDC units).
5. Result: Private transfer amount inferred from public conversion events.

**Mitigation:** Fix PRIV-H02.

### Scenario 4: DEX Counterparty Identification (PRIV-M02)

**Attacker:** Any on-chain observer.
**Steps:**
1. Monitor `PrivateOrderSubmitted(orderId1, alice, "pXOM-pUSDC")` events.
2. Monitor `PrivateOrderSubmitted(orderId2, bob, "pXOM-pUSDC")` events.
3. When `PrivateOrderMatched(orderId1, orderId2, tradeId)` appears, Alice
   and Bob traded with each other.
4. Check order structs: `orders[orderId1].isBuy == true` means Alice bought,
   Bob sold.
5. Result: Buyer-seller pair identified for every trade.

**Mitigation:** PRIV-M02 -- use relayer for order submission.

### Scenario 5: Complete Multi-Asset Surveillance Chain

**Attacker:** Sophisticated analytics service.
**Steps:**
1. Track XOM Transfer events to identify bridge depositors (PRIV-H03).
2. Query `privateDepositLedger` for pXOM balances (PRIV-C01).
3. Monitor PrivateTransfer events for transaction graph (PRIV-INFO-02).
4. Compute transfer amounts from ledger diffs (PRIV-C01).
5. Track DEX order submissions and matches (PRIV-M02).
6. Monitor pUSDC/pWBTC/pWETH conversion events for amounts (PRIV-H02).
7. Result: Near-complete financial surveillance across all privacy tokens,
   including amounts, counterparties, and timing.

**Mitigation:** Fix PRIV-C01, PRIV-H01, PRIV-H02, PRIV-H03, PRIV-M02.

---

## Summary of Recommendations

### Immediate Action Required (CRITICAL/HIGH)

| ID | Action | Contract |
|----|--------|----------|
| PRIV-C01 | Change `privateDepositLedger` from `public` to `private`, add access-controlled getter | PrivateOmniCoin.sol |
| PRIV-H01 | Replace `MpcCore.sub()` with `MpcCore.checkedSub()` (6 call sites) | PrivateUSDC, PrivateWBTC, PrivateWETH |
| PRIV-H02 | Remove amounts from `ConvertedToPrivate`/`ConvertedToPublic` events | PrivateUSDC, PrivateWBTC, PrivateWETH |
| PRIV-H03 | Document that ERC20 Transfer events always leak bridge amounts; consider relayer/batching | PrivateOmniCoin, OmniPrivacyBridge |

### Should Fix (MEDIUM)

| ID | Action | Contract |
|----|--------|----------|
| PRIV-M01 | Remove amount from PrivateOmniCoin `ConvertedToPrivate` event; consider single-tx bridge flow | PrivateOmniCoin, OmniPrivacyBridge |
| PRIV-M02 | Document that PrivateDEX provides amount/price privacy only, not identity privacy; consider relayer | PrivateDEX |
| PRIV-M03 | Document MPC trust model; ensure node geographic/jurisdictional distribution | All MPC contracts |

### Consider (LOW/INFO)

| ID | Action | Contract |
|----|--------|----------|
| PRIV-L01 | Access-control bridge cumulative counters | OmniPrivacyBridge |
| PRIV-L02 | Access-control `getPrivateCollateral()`; restrict events | PrivateDEXSettlement |
| PRIV-L03 | Remove amounts from emergency recovery events; allow user-initiated recovery | All privacy contracts |
| PRIV-INFO-01 | Document that `private` keyword does not encrypt EVM storage | All |
| PRIV-INFO-02 | Already documented (ATK-H06); use relayer service | All |
| PRIV-INFO-03 | Inherent to matcher design; no code change needed | PrivateDEX |

---

*End of report.*
