# Governance revision — 2026-10 (marketplace fee + arbitration)

**Status:** code complete, audited (two rounds), **not deployed**, **not
proposed**. Nothing in this document has been broadcast.

## What this fixes

| Problem today | Fix in this revision |
|---|---|
| Escrow releases take the plain-transfer fallback because the escrow holds no `DEPOSITOR_ROLE`. The 1% lands in the vault and the generic `distribute()` splits it 70/20/10 (ODDAO / staking / treasury). No referrer, listing node or selling node is paid. | Action 1 grants `DEPOSITOR_ROLE` to the new escrow → the 9-way split runs (referral 0.50%: 0.35 / 0.10 / 0.05; listing 0.25%: 0.175 / 0.05 / 0.025; transaction 0.25%: 0.175 / 0.05 / 0.025). |
| The escrow has no node attribution, so even with the role the node slices would go to ODDAO. | New `EscrowV2` records `listingNode`/`sellingNode` per escrow and passes them into the split. |
| `canBeListingNode` required no KYC while `canBeServiceNode` required KYC tier 2 — two different bars for the same role family. | Both now score ≥ 25 **and** KYC tier 2, and both honour the pioneer founder allowlist like `canBeValidator`. |
| Arbitrators needed validator-grade qualification (score ≥ 50 + KYC 3), keeping the panel below the three judges it needs. | Arbitrators use the node standard. |
| `createDispute` took a non-refundable 5% fee and could then fail to seat a panel — fee trapped, escrow frozen. | Refuses before taking the fee unless 3 judges are seatable; `cancelDispute` refunds the fee payer and unfreezes the escrow if selection still fails. |
| `triggerDefaultResolution` would default a **cancelled** dispute (deadline 0) into a full buyer refund. | Only an `Active` dispute may default. |

## Timeline (governance, not code)

1. Deploy implementations — `scripts/deploy-revision-2026-10.cjs`
2. Submit proposal — `scripts/governance/propose-revision-2026-10.cjs`
3. Voting delay **48 h** → voting period **7 days** → timelock **48 h**
   (≈ 9–10 days total). Proposal threshold: 1.7M XOM of voting power.
4. Execute (permissionless once the timelock matures).
5. Deployer wiring — `scripts/post-revision-wiring.cjs`
6. Record the new addresses: copy `escrowV2`, `escrowFeeRouter`,
   `escrowPrivacyOps` from `deployments/revision-2026-10.json` into
   `deployments/mainnet.json` (`contracts.EscrowV2`, plus two new keys for the
   libraries), then run `node scripts/sync-contract-addresses.js mainnet` from
   the repo root so `omnicoin-integration.ts` (and its three copies) match.
   The libraries are deployed once and shared; never redeploy them for an
   escrow change.
7. Verify with a real sale (§Verification).

## The four proposal actions

Executed atomically by the timelock:

1. `UnifiedFeeVault.grantRole(DEPOSITOR_ROLE, <newEscrow>)`
2. `OmniParticipation.upgradeToAndCall(<newImpl>, 0x)`
3. `OmniArbitration.upgradeToAndCall(<newImpl>, 0x)`
4. `OmniArbitration.updateContracts(<participationProxy>, <newEscrow>)`

`EscrowV2.setArbitrationContract` and `addArbitrator` are deployer-admin calls
and are deliberately **not** in the proposal (they need no vote).

## Why a new escrow contract, not an upgrade

`EscrowV2` is not a proxy. The node-attribution fields and
`unmarkDisputed` change the bytecode, so this is a fresh deployment. Old
escrows stay at the old address; they are all test data (v1 has
`escrowCounter = 2`, zero balance, zero claimable — verified).

## Preconditions checked before proposing

- **Zero live disputes.** `nextDisputeId == 1` on the arbitration proxy — no
  dispute has ever been created, so the `Dispute` struct change (added
  `feePayer`) and the new `Cancelled` status have no migration.
- **Judge pool — corrected 2026-10-20.** The earlier note here said "do not
  propose before a third judge is registered". That ordering is **impossible**
  and must not be used as a gate. Verified on chain 2026-10-20: the *deployed*
  `OmniParticipation.canBeServiceNode` returns **false** for `omnirick`,
  `rickcrites` **and** `omnibazaar_marketing` — the live gate does not honour
  the pioneer founder allowlist (only `canBeValidator` does, which is how the
  first two registered under the older arbitration build). Since
  `OmniArbitration.registerArbitrator` calls `canBeServiceNode`, **no one** can
  register until this proposal executes action 2 (the Participation upgrade
  that adds the bypass). Sequence therefore:
  1. propose and execute (the pool stays at 2 during the vote);
  2. `omnibazaar_marketing` (`0x824b…2683`, holds 100,000 XOM, allowlisted)
     calls `registerArbitrator(10000e18)` — see
     `INSTRUCTION_CHRIS_ARBITRATOR_REGISTRATION_2026-10-20.md`;
  3. only then can `createDispute` seat a panel.
  Between execution and step 2 every `createDispute` reverts
  `ArbitrationPoolNotSeated` — fail-closed, no fee taken. That window is
  expected and must be announced, not treated as a defect.
  The two existing judges' stakes survive the upgrade; `_seatableJudges`
  filters on `canBeServiceNode`, which becomes true for all three allowlisted
  accounts the moment action 2 lands.
- **Escrow pointer.** The arbitration proxy currently points at
  `0x246Da6DF…`, a different escrow build. Action 4 repoints it.
- **Vault admin.** `DEFAULT_ADMIN_ROLE` on the vault is the timelock; the
  deployer cannot grant the role directly, which is why this needs a vote.

## Verification after execution

1. `hasRole(DEPOSITOR_ROLE, newEscrow) == true`.
2. `OmniParticipation.canBeListingNode(<no-KYC account>) == false`,
   `canBeServiceNode(<allowlisted account>) == true`.
3. `OmniArbitration.MIN_PANEL_SIZE() == 3`, `cancelDispute` exists,
   `arbitratorPoolSize() >= 3` after the third judge registers.
4. `OmniArbitration.escrow() == newEscrow`, and
   `newEscrow.arbitrationContract() == OmniArbitration`.
5. **Real sale:** create a listing, buy through escrow (physical item), release
   it, then read the vault's `pendingClaims` for the referrer and both nodes —
   each must be non-zero. This is the proof that the 1% is split correctly.

## Residual risks recorded by the audit (not fixed here)

- **Panel capture.** A 2-of-3 panel with no bond, no slashing and no appeal can
  be captured by two colluding judges (20,000 XOM, refundable). Lowering the
  qualification bar reduces the cost of manufacturing those identities. A real
  fix needs a bond sized to the disputed amount, a delay on stake withdrawal,
  and/or an appeal tier — a product decision, not part of this revision.
- **Silent-panel default.** `triggerDefaultResolution` still refunds the buyer
  when no judge votes; a judge is paid whether or not they vote. Also a
  product decision (pay only voters, or default to the status quo).
- **Payer-asserted attribution.** The buyer supplies referrers and node
  addresses; up to 0.675% of the sale price can be redirected to accomplices.
  The validator must fill these from the signed listing row, not from request
  body input.
