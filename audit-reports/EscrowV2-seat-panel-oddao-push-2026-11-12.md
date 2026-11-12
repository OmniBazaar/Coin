# EscrowV2 — 3-of-n judge panel and ODDAO push — audit record (2026-11-12)

**Scope.** Two money-path changes, deployed together on all seven escrow chains from one
binary: `contracts/EscrowV2.sol`, `contracts/libraries/EscrowFeeRouter.sol`,
`contracts/libraries/EscrowSignatureLib.sol`, plus `contracts/interfaces/EscrowV2Types.sol`
(unchanged) and the deploy/verify scripts.

**Commit.** `de0d4d9` (source + tests + scripts). Unit tests: `test/EscrowV2.test.ts`,
53 passing. Deployed size 22,018 of 24,576 bytes on every chain.

---

## 1. What changed

### 1.1 The panel is three OF N
Before: `mapping(address => bool) verdictJudge` capped at exactly three addresses, and a
verdict needed any two of them. Growing the roster would have lowered the bar to "any two of
many", so the cap was load-bearing.

After:
- the roster is unbounded (`address[] _verdictJudges` + 1-based index + the original mapping
  and counter, kept for O(1) membership and for the Validator's bytecode generation probe);
- `openDispute` records the opening block in a **separate** `mapping(uint256 => Panel)` and
  refuses to freeze an escrow fewer than three non-party judges could hear;
- `seatPanel(escrowId)` is permissionless, valid from the block after the opening block and
  for 256 blocks (the `BLOCKHASH` horizon), draws three distinct judges from the whole roster
  excluding buyer, seller and the escrow, stores them and emits `PanelSeated`;
- `executeVerdict` verifies two distinct **seated** judges, never the roster;
- seats live outside `struct Escrow`, so `getEscrow` keeps its 16-field shape and no client or
  backend decoder changes generation;
- a judge removed after seating can still sign (the seat set is stored), so a roster change
  cannot brick a live case;
- re-adding a judge cancels a pending removal (it used to be a silent no-op that dropped her
  48 hours later).

### 1.2 ODDAO is paid by transfer
Every ODDAO slice — the transaction 70%, both 10% remainders, all four zero-address
attribution fallbacks, and the arbitration remainder — is aggregated into one `safeTransfer`
per settlement, after all accounting is written. Referrers, nodes, staking and treasury keep
the pull-pattern credit ledger.

The push **does not revert on a short delivery**: it emits `OddaoPaid` with the measured
amount and `OddaoPushShortfall` when the token took a cut. A token that starts charging a
transfer fee after funding must not brick every settlement path, including the delivered
timeout backstop, because the funds are committed to a live escrow and `recoverERC20`
refuses them. A blacklisting or paused token still reverts the transfer; the recovery route
is the escrow's 48-hour beneficiary change.

---

## 2. Findings and dispositions

| # | Source | Severity | Finding | Disposition |
|---|---|---|---|---|
| 1 | audit | high | The push reverted on a short delivery (fee-on-transfer token that starts charging after funding), permanently bricking release, verdict, timeout and delivery-timeout paths with no `recoverERC20` escape. | **FIXED** — measured push, `OddaoPushShortfall`, guarded subtraction for rebasing-down tokens. Regression test: `a fee-on-transfer token settles: the token takes its cut and the shortfall is logged`. |
| 2 | red team | critical | The first version of the fix excluded the four fee-attribution slots from the seat draw. The **seller chooses those slots**, so a seller could name four roster judges and make seating impossible (30-day timeout instead of a verdict) or reweight the draw. | **FIXED** — `_panelExclusions` returns only buyer, seller and the escrow; the draw takes `address[3]`. Regression test: `seats from the whole roster even when every attribution slot names a judge` proves the panel still seats and settles. |
| 3 | audit | medium | `setVerdictJudge(x, true)` on an already-rostered judge was a silent no-op, so a pending removal stayed live and dropped her 48 hours later — which can leave the roster below three and stop new disputes chain-wide. | **FIXED** — the add branch cancels a matching pending removal first, and emits `JudgeRemovalCancelled`. Test: `re-adding a judge with a pending removal cancels the removal`. |
| 4 | red team | medium | A short delivery from a fee-on-transfer token leaves the ODDAO sink underpaid with only an event. | **ACCEPTED** — deliberate: liveness over exactness. The escrow's own ledger stays exact (the money never entered `claimable`). |
| 5 | re-audit | medium | Roster **addition** is instant and unbounded, and the roster size is part of the draw seed, so the admin can, inside the 256-block seating window, add entries and simulate panels until a chosen set is seated. | **ACCEPTED for this build, documented.** Pioneer phase: the deployer EOA is the sole admin of every contract by founder decision, and this is an admin-only vector, not a party-reachable one. Mitigations already in place: seats are drawn once and stored (no re-draw), the Validator seats on the next block, and the timeout still returns funds. The next contract revision should snapshot the roster size at `openDispute` and use append-only tombstones for removals, which closes it without an add delay. |
| 6 | re-audit | medium-low | The arbitration remainder is paid to the ODDAO address **snapshotted at filing** (`e.arbOddao`), while the marketplace split uses the live sink. A blacklisting token at the old sink therefore makes a verdict unexecutable for that case; the 48-hour change only fixes the live path. | **ACCEPTED** — snapshotting the sink is what stops a mid-case parameter change rewriting who is paid; the alternative lets the admin redirect a live case's fee. |
| 7 | audit / re-audit | low | A judge who is also an attribution recipient can be seated and would benefit from a release verdict. | **ACCEPTED** — excluding them is what finding 2 exploited. The roster is admin-curated and two of three seats must agree. |
| 8 | audit | low | Block-proposer grinding on the seat draw. | **ACCEPTED** — the seed is the opening block hash, unknown when the disputing party signs, and `openDispute` is once per escrow; a proposer pays for a vector that only helps if they also control two roster judges. |
| 9 | audit | informational | A dissenting judge's signature over the losing direction is accepted and paid. | **KEPT** — deliberate: a judge who sat and dissented is paid for sitting. |
| 10 | audit | informational | `_beneficiaries()` was dead code. | **REMOVED.** |

Verification of the remediated code: a second, independent audit re-read the final source and
returned **SAFE TO KEEP**, confirming findings 1–3 fixed, with 5 and 6 as the accepted
residuals recorded above.

---

## 3. Deployment

| Chain | EscrowV2 | Deploy tx |
|---|---|---|
| 88008 OmniCoin | `0x7144B011ce241eecA38CD0c4948777B761985864` | `0x48631782…62c2` |
| 43114 Avalanche | `0xbC657fF4a6E27B3ABB8cB5AFa6a659A45CEb6eD1` | `0x81e26a72…f9a5f` |
| 1 Ethereum | `0x10eAB8AB3dF628eDb6bF3B3B0Fff4B3e17e2CdF6` | `0xbaa7f1a4…8c4a` |
| 42161 Arbitrum | `0x9317b5c995271FE5008C8bd295f1D750Ed962664` | `0x6aab4372…75b8` |
| 8453 Base | `0x006B3b87f8340B76576261003Dd716495d401679` | `0x078024b4…2cbe` |
| 137 Polygon | `0x1F57034C41B330014C6560056833B2F9c9cDce51` | `0xe20a393f…542d7` |
| 56 BNB Chain | `0xf97F133b7a135212Dff206ca3CcFEFF72a72643C` | `0xf545e7f7…269c` |

Per chain: settlement coin and USDC allowlisted (USDT too on BSC), the three seated judges
rostered, arbitration floor 2.5 units of the stablecoin, fee defaults 500/2500.
`node scripts/verify-escrow-chains.cjs` → **111/111 PASS, zero SKIP**, including the new
"seat-aware panel revision" check (seats 3, window 256, roster enumerates).

The previous escrow on every chain is preserved under `contracts.escrowV2Superseded` in that
chain's manifest.

---

## 4. Live proofs (real money, 2026-11-12)

`Validator/scripts/escrow-live-test/panel-e2e.cjs` — new runner. Cases:

**USDC on Ethereum — 10/10.** 10 USDC sale, buyer freezes, panel seated (three distinct, none
a party), two seated judges execute a release verdict. Fee was 2.5 USDC: the 2.5-unit floor
bound because 5% of the sale was only 0.5 — the first proof of the floor anywhere, since every
earlier verdict proof was XOM on L1 where the floor is zero. Seller credited 7.4
(= 10 − 0.1 marketplace − 2.5 arbitration), each signing judge 1.0, submitter 0.25, and ODDAO
**received 0.3425 by transfer** (0.0925 marketplace slices + 0.25 arbitration remainder) with
`claimable(oddao) == 0`.

**WAVAX on Avalanche — 9/9.** 0.1 WAVAX sale, refund verdict: buyer credited 0.095
(= 0.1 − 0.005 arbitration), no marketplace fee on a refund, judges 0.002 each, submitter
0.0005, ODDAO received 0.0005 by transfer. Proves a non-stable, non-XOM token end to end.

**USDC on Arbitrum — settled.** A 10 USDC release verdict executed before the runner's
assertions were corrected (the assertions, not the settlement, were wrong: seller +7.4, judges
1.0 each, submitter 0.25, ODDAO +0.3425, floor bound). Recorded for completeness.

Also settled on this build: the two frozen L1 escrows (on the PREVIOUS contract, with the
previous two-of-three roster): #2 1 XOM and #6 2 XOM, both refunded to the buyer, both
transactions on chain (`0xfafbc6e3…` and `0x5ec13923…`). The Avalanche harness escrow zara→bob
(0.25 USDC) was released to the seller before the old contract was superseded.

---

## 5. Operational notes for the next operator

- **Seating is automatic.** The Validator's `PanelSeaterService` follows `EscrowDisputeOpened`
  and calls `seatPanel` on the next block using the verdict-relay key, which is funded on all
  seven chains. `POST /api/v1/escrow/:id/seat-panel` returns calldata for a manual seat if the
  relay key is ever unavailable.
- **🛑 Never compare `provider.getBlockNumber()` with `panel.openBlock`.** On Arbitrum the
  provider reports L2 block numbers while the EVM's `block.number` is the L1 block number, so
  the delta is meaningless there. The seater was written that way for one hour and dropped
  every Arbitrum case as "window closed". It now dry-runs the call and classifies the revert.
- **Attribution consents do not survive a redeploy.** The consent is signed over the escrow's
  EIP-712 domain, so every listing whose seller signed against the previous escrow now routes
  its node and referral slices to ODDAO until the seller re-signs (an edit of the listing or
  its accepted assets re-signs). This is inherent to a fresh contract, and it applies to the
  2026-11-11 redeploy as well.
- **WAVAX had to be allowlisted** on the Avalanche escrow after deploy: the Validator's config
  advertises USDC and WAVAX, but the escrow only seeds its settlement coin and USDC. Add it for
  any chain where the config lists a non-USDC ERC-20.
