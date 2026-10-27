# EscrowV2 arbitration revision — security audit (2026-10-27)

Scope: `contracts/EscrowV2.sol`, `contracts/libraries/EscrowFeeRouter.sol`,
`contracts/libraries/EscrowSignatureLib.sol`, `contracts/interfaces/EscrowV2Types.sol`.

Cycle: 4 independent semantic passes (OWASP/SC Top 10, OmniBazaar business logic,
access control, adversarial red team with executed proofs of concept), static
analysis, remediation, then a focused re-audit of the remediation diff.

Verdict: **one Critical and three High findings were raised against the 2026-10
revision. All were remediated before any deployment.** Two residual risks remain
and are accepted below with reasons.

## Findings and disposition

| # | Severity | Finding | Disposition |
|---|---|---|---|
| C-01 | Critical | The verdict roster is instant and caps at three, so a compromised admin can remove the honest signers and seat two colluding ones in one batch, then execute a verdict over any frozen escrow. | **Fixed** — judge REMOVAL is delayed 48 h (`JUDGE_REMOVAL_DELAY`, `acceptJudgeRemoval`); adds stay immediate, bounded by the cap of three, so a fresh deployment can be rostered without waiting. Substitution now takes two days and is visible in `JudgeRemovalProposed`. |
| H-01 | High | `pause` gated every seller-payout path (release, verdict, expired release) while refunds and the timeout stayed live. A pause across the verdict window converted a decided case into a default refund, and a delivered, undisputed escrow had **no** exit at all. | **Fixed** — `pause` now stops creation only. Resolution is never pausable. |
| H-02 | High | `setArbitrationFee(500, 1)` made every `openDispute` revert, and `setMinArbitrationFee` was unbounded: one transaction could turn arbitration off (and a huge floor could panic on overflow). | **Fixed** — the setter now requires `maxFeeOfAmountBps >= feeBps`; the floor is bounded to `uint128`; `fee * BASIS_POINTS` is guarded by the uint128 bound so it cannot overflow. |
| H-03 | High | The trusted EIP-2771 forwarder is an unverified impersonation oracle over every `_msgSender()` gate (buyer release, refund, delivery, dispute filing, claimable withdrawal). | **Accepted, pre-existing** — immutability is deliberate (OZ default) and the forwarder must be a non-upgradeable audited contract. Admin functions use `msg.sender` and are unaffected. Recorded as a deployment precondition: verify the forwarder's code and that it is not a proxy. |
| M-01 | Medium | The arbitration SPLIT was read live at settlement, so a parameter change could zero the judges on a case they had already signed. | **Fixed** — the split and the ODDAO sink are snapshotted on the escrow at filing (`arbSplit`, `arbOddao`) exactly as the fee amount already was. |
| M-02 | Medium | `proposeBeneficiaries` was missing the constructor's `address(this)` rejection: a sink pointing at the escrow could never withdraw, yet counted as owed, permanently blocking `recoverERC20` for that amount. | **Fixed** — the setter rejects `address(this)` for all three sinks; `cancelBeneficiaries` added so a stale proposal cannot be inherited by a later admin. |
| M-03 | Medium | The submitter share is captured by whoever submits first; the bundle is public, so a searcher can take it. The submitter also chooses how many signatures to present, which changes the schedule. | **Accepted** — the relayer is the intended submitter and the Validator always bundles every known signature. The residual is a keeper bounty of 9–10 % of the arbitration fee (cents on a small sale), paid to whoever spends the gas. Documented, not fixed. |
| M-04 | Medium | `openDispute` had no time gate, so a filing after `expiry + VERDICT_WINDOW` could never carry an executable verdict and burned panel time. | **Fixed** — `VerdictWindowClosed` refuses it. |
| M-05 | Medium | A zero-rounded arbitration fee let a verdict execute while paying the judges nothing. | **Fixed** — `openDispute` refuses a zero fee; `disputeFee` is bounded to `uint128` before the cast. |
| M-06 | Medium | `_resolve` reverted when the fee reached the payout. Because the fee is snapshotted, a revert would strand that escrow's principal behind a permanently unexecutable verdict. | **Fixed** — the fee is clamped to `recipientAmount - 1` instead. |
| M-07 | Medium | A judge who signed both directions made the whole bundle revert, so the case fell to the timeout despite a valid majority. | **Fixed** — a repeated signer is counted and paid once; the winning direction counts if either copy was on it. |
| M-08 | Medium | The marketplace 25/50/25 split used `/4` and `/2`; two independent truncations pushed the whole remainder into the listing slice, so a one-unit fee paid the transaction and referral recipients nothing. | **Fixed** — exact `*2500/BPS` and `*5000/BPS` fractions. |
| L-01 | Low | The first-sale record was skipped on disputed releases, so a buyer could deny a seller their bonus by freezing. | **Fixed** — `_recordFirstSale` runs on a disputed release. |
| L-02 | Low | Verification of the linked library's return value is missing on the money path: a mis-linked library makes the seller's payout zero while the escrow still resolves. | **Accepted** — mitigated by the deployment checklist (both libraries verified on chain per chain, plus `verify-escrow-chains.cjs`). A code-side invariant check is noted for the next revision. |
| L-03 | Low | Fee-on-transfer behaviour on outbound transfers is unchecked. | **Accepted** — inbound transfers already reject such tokens (`_pullExact`), and adding the outbound check costs bytecode we chose not to spend. |

## Residual risks, accepted

**R-1 — The timeout's default depends on who asserted delivery first (red-team F-01/F-02).**
`claimDisputeTimeout` pays the seller only when delivery was asserted before the
freeze; otherwise the buyer is refunded in full. Either ordering can be abused by
a lying party when the panel fails to decide: a buyer can freeze at creation and
receive goods *and* a refund; a seller can assert a delivery that never happened
and collect via `releaseExpiredToSeller` (which exists independently of the
dispute path and is also unverified). There is no on-chain oracle for delivery, so
any rule trades one party's risk for the other's. **Control:** the judge panel is
the intended decision-maker, and this revision makes it actually work (paid,
notified, independently briefed, automatically submitted). Recorded as a product
risk, not fixed by contract change.

**R-2 — Judge collusion has no economic penalty.**
There are no seat bonds and no slashing (founder decision 2026-10-27: too much
complexity). Two colluding judges can decide any frozen case. The controls are
roster selection (KYC'd, three seats, 48-hour removal delay) and public events.

## Re-audit of the remediation (second round)

A focused pass re-read the four files after remediation. All nine fixes were
confirmed (FIXED), and five new observations were raised and dispositioned:

| New | Severity | Finding | Disposition |
|---|---|---|---|
| N-1 | Low | `setMinArbitrationFee` remains unbounded, so one admin call can still make every filing revert for a token. | **Accepted** — the same effect is available through `pause`, which is already admin-only; the floor is bounded to `uint128` and no longer overflows. |
| N-2 | Medium | A pending judge removal survived an admin handover and could not be cancelled. | **Fixed** — `cancelJudgeRemoval()`, and `acceptAdmin` clears any pending removal. |
| N-3 | Medium | Stake-free filing makes the R-1 timeout attack costless. | **Accepted** — see R-1. Closing it needs a delivery attestation (carrier/oracle); no on-chain rule can decide a disputed fact. |
| N-4 | Low | `releaseFundsViaContract` was still pausable. | **Fixed** — modifier removed, matching the direct release. |
| N-5 | Low | A legal split could zero the judge pool and give the submitter 95 %. | **Fixed** — the panel keeps at least 50 % and the submitter at most 20 %. |
| N-6 | Low | The timeout left `disputeFee`/`arbSplit`/`arbOddao` populated on a resolved escrow. | **Fixed** — cleared. |
| N-8 | Info | `FeeTooLarge` for a zero fee; the judge delay reverted with the beneficiary error; the dispute event's field was still named `stake`. | **Fixed** for the error names and the new `JudgeRemovalDelayActive`; the event field is renamed in the next commit. |

## Verification

- 39 contract tests green, including the new snapshot, filing-gate, roster-delay
  and duplicate-signature cases.
- `EscrowV2` deployed size 19,719 bytes (limit 24,576).
- `verify-escrow-chains.cjs` asserts the judge share is non-zero on every chain.
