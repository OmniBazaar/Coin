# Governance revision — 2026-10 (marketplace fee + arbitration)

**Status (2026-10-31): DEPLOYED, PROPOSED, VOTED, QUEUED — executes 2026-11-07T18:56Z.**
Read "The four proposal actions" below before trusting the action list or the
"What this fixes" table: the proposal has **two** actions (the arbitration lead
was deliberately removed and delivered by a fresh-proxy deploy instead), and the
node-slice column of the table is **not** delivered by the queued proposal.
Proposal 16: 67,042,665 XOM For / 0 against, queue tx `0xa026f1ce…b7dfa`.

## What this fixes

| Problem today | Fix in this revision |
|---|---|
| Escrow releases take the plain-transfer fallback because the escrow holds no `DEPOSITOR_ROLE`. The 1% lands in the vault and the generic `distribute()` splits it 70/20/10 (ODDAO / staking / treasury). No referrer, listing node or selling node is paid. | Action 1 grants `DEPOSITOR_ROLE` to the new escrow → the 9-way split runs (referral 0.50%: 0.35 / 0.10 / 0.05; listing 0.25%: 0.175 / 0.05 / 0.025; transaction 0.25%: 0.175 / 0.05 / 0.025). |
| The escrow has no node attribution, so even with the role the node slices would go to ODDAO. | `EscrowV2` records `listingNode`/`sellingNode` per escrow and pays them through `EscrowFeeRouter` — **not in the queued proposal**, and inert until L1 settlement migrates off `MinimalEscrow` (which passes zero node addresses by design). |
| `canBeListingNode` required no KYC while `canBeServiceNode` required KYC tier 2 — two different bars for the same role family. | Both now score ≥ 25 **and** KYC tier 2, and both honour the pioneer founder allowlist like `canBeValidator`. |
| Arbitrators needed validator-grade qualification (score ≥ 50 + KYC 3), keeping the panel below the three judges it needs. | Arbitrators use the node standard. |
| `createDispute` took a non-refundable 5% fee and could then fail to seat a panel — fee trapped, escrow frozen. | Refuses before taking the fee unless 3 judges are seatable; `cancelDispute` refunds the fee payer and unfreezes the escrow if selection still fails. |
| `triggerDefaultResolution` would default a **cancelled** dispute (deadline 0) into a full buyer refund. | Only an `Active` dispute may default. |

## Timeline (governance, not code)

1. Deploy implementations — `scripts/deploy-revision-2026-10.cjs`
2. Submit proposal — `scripts/governance/propose-revision-2026-10.cjs`
3. Voting delay **48 h** → voting period **7 days** → timelock **48 h**
   (≈ 9–10 days total). Proposal threshold: 1.7M XOM of voting power.
   🛑 **Measured reality for proposal 16: the timelock was 7 DAYS, not 48 h.**
   It was proposed as CRITICAL (`propose(1, …)`) and carries
   `upgradeToAndCall`, so `OmniTimelockController` applied the critical delay;
   `timelock.getTimestamp(id) = 1794077782` → ready 2026-11-07T18:56Z, 18 days
   end to end. Assume 7 days for anything that upgrades a contract.

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

🛑 **SUPERSEDED 2026-10-20 — read this before believing the list below.**

Proposal 16 as submitted and queued has **TWO** actions, not four, and that is
deliberate (founder decision 1, 2026-10-20, recorded verbatim in
`scripts/governance/propose-revision-2026-10.cjs`):

1. `UnifiedFeeVault.grantRole(DEPOSITOR_ROLE, MinimalEscrow)` — the escrow the
   Validator actually uses takes the referral-aware vault split instead of the
   plain-transfer fallback. **MinimalEscrow, not EscrowV2:** the 2026-10-20
   decoupling removed the vault dependency from EscrowV2 entirely (it now pays
   through `EscrowFeeRouter.collectMarketplaceFee`), so a role grant to EscrowV2
   would do nothing.
2. `OmniParticipation.upgradeToAndCall(newImpl, 0x)`.

**The arbitration action is GONE, and it was delivered another way.** The
hardened panel ships as a **fresh proxy**
(`scripts/deploy-arbitration-panel.cjs`) rather than as an upgrade of a proxy
whose OpenZeppelin manifest record diverges; the production escrow is pointed at
it by its own deployer-admin `setArbitrationContract`
(`scripts/post-revision-wiring.cjs`). Verified live on 2026-10-31:

| Check | Value |
|---|---|
| `OmniArbitration` (new proxy) | `0x73d0Ea976850D2E8C0262255f1955B05973C0C38`, impl `0x3847B2aD…` |
| `MinimalEscrow.arbitrationContract()` | `0x73d0…0C38` — already pointed at the new panel |
| `panel.escrow()` / `panel.participation()` | production escrow `0xf53c…16D0` / participation proxy `0xcd54…F84F9` |
| `panel.registration()` | `0x2B05cbA7…` (= `contracts.OmniRegistration`) |
| founder arbitrators allowlisted | 3/3 (`0x2134…c193`, `0xB475…B94d`, `0x824b…2683`) |
| `escrow.isRegisteredArbitrator` | 3/3 (private pXOM path) |
| `panel.arbitratorPoolSize` / `escrow.arbitratorCount` | 3 / 3 |
| apps' `omnicoin-integration.ts` | all four point at `0x73d0…0C38`; legacy kept as `OmniArbitrationLegacy` |

So nothing about arbitration is missing from governance — it never needed a vote,
because the deployer is the sole admin of the fresh proxy in the Pioneer phase.

⚠️ **What proposal 16 does NOT deliver, despite the table at the top of this
file:** listing-node and selling-node slices. `MinimalEscrow._collectMarketplaceFee`
calls `depositMarketplaceFee(token, amount, referrer, referrer2, address(0),
address(0))` — the node parameters are hardcoded zero and route to ODDAO by the
vault's documented zero-address path, because MinimalEscrow is immutable and has
no node attribution. After execution the honest description is: **referrers get
paid (0.50% → 0.35/0.10/0.05); listing (0.25%) and transaction (0.25%) go
vault-internal 70/20/10.** Node attribution exists only in `EscrowV2`
(`0x4602…f84D`, which records `listingNode`/`sellingNode` and pays through
`EscrowFeeRouter`) and lands when L1 settlement migrates off MinimalEscrow —
a client/validator change, not a governance action.

### The superseded four-action plan (kept for the record)

Executed atomically by the timelock:

1. `UnifiedFeeVault.grantRole(DEPOSITOR_ROLE, <newEscrow>)`
2. `OmniParticipation.upgradeToAndCall(<newImpl>, 0x)`
3. `OmniArbitration.upgradeToAndCall(<newImpl>, 0x)`  ← dropped, replaced by the fresh-proxy deploy
4. `OmniArbitration.updateContracts(<participationProxy>, <newEscrow>)`  ← dropped, deploy-time wiring

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

0. **Source verification and gas**, both affected by the two libraries and the
   `runs: 1` / `bytecodeHash: none` override:
   - verify with the library addresses supplied, or the bytecode will not match:
     `npx hardhat verify --network mainnet --libraries
     contracts/libraries/EscrowFeeRouter.sol:EscrowFeeRouter=<addr>
     --libraries contracts/libraries/EscrowPrivacyOps.sol:EscrowPrivacyOps=<addr>
     <escrowAddr> <omniCoin> <pXom> <registry> <vault> 100 <forwarder>`;
   - `runs: 1` costs roughly 10–15% more gas per call than `runs: 200`. Re-check
     every client-side hard-coded `gasLimit` on escrow calls (`releaseFunds`,
     `commitDispute`, `resolveDispute`) against a live estimate before the
     client rollout.
1. **Generation check.** `EscrowV2` is **23,867** bytes deployed and **25,954**
   init code. If a rebuild reports anything else, the build settings drifted —
   stop, do not deploy.

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
