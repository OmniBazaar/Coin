# Governance monitoring and execution (2026-10-31)

Founder directive: **governance issues are ALERT class** — they must reach the
alert system (journald `sentryAlert:` → Vector → Sentry) when they happen, not sit
in a markdown file until someone reads it. Two units implement that:

| Unit | What it does |
|---|---|
| `omnibazaar-gov-monitor.timer` → `governance-monitor.sh` | Every 10 min: reads `OmniGovernance.state(id)` for every proposal and **pages** on any state that needs a human. |
| `omnibazaar-gov-execute-16.timer` → `execute-proposal.sh 16` | Every 15 min: performs the one legal step for proposal 16, and only when the on-chain timelock says it is legal. Disarms itself after success. |

Both run as `omnirick`, use absolute paths (`cast` lives in
`~/.foundry/bin`; a bare `cast` under cron silently resolved to nothing once —
TODO 13a7).

## What pages, and what does not

| State | Key | Class |
|---|---|---|
| Active | `gov.proposal.<id>.voting-open` | **ALERT** (needs votes) |
| Succeeded | `gov.proposal.<id>.queue-due` | **ALERT** (expires 14 days after voting closed) |
| Queued, timelock elapsed | `gov.proposal.<id>.execute-due` | **ALERT** |
| Expired | `gov.proposal.<id>.expired` | **ALERT** (the vote is lost) |
| Executed | `gov.proposal.<id>.executed` | **ALERT, once ever** — follow-through is work (rebuild + roll) |
| Queued, timelock pending | — | journald line only |
| Defeated / Cancelled | — | journald line only (nothing to do) |
| Monitor cannot read state | `gov.monitor.failed` | **ALERT** — silence must never look like health |

ALERT = `logger -p user.warning` (files a Sentry issue). Recovery (`…resolved`)
and one-off success notices are `user.info`, which the forwarder drops: a
self-heal must not sit in the issue list forever
(`memory/alerting_hygiene_2026-10-25.md`).

Standing conditions re-emit at most once an hour while they persist. `executed`
fires once, and only for a proposal the monitor previously saw awaiting action —
otherwise the first run pages once per historical execution (it did, 2026-10-31:
six issues for proposals 10–15, all ignored afterwards).

## The timelock is read, never assumed

`gov_timelock_ready_at(id)` computes the operation id exactly as
`OmniGovernance._getTimelockId` does —

```
salt = keccak256(abi.encodePacked("OmniGov", proposalId))
id   = keccak256(abi.encode(targets, values, calldatas, bytes32(0), salt))
```

— then asks the timelock controller for `getTimestamp(id)`. Verified against the
live `ProposalQueued` log for proposal 16.

🛑 **Proposal 16's delay is 7 days, not 48 hours.** The contract classifies the
proposal's selectors, and `upgradeToAndCall` (participation-proxy upgrade) is a
CRITICAL selector, so `OmniTimelockController` applied the 7-day critical delay.
Two documents carried the 48-hour ROUTINE figure; the measured ETA is
**2026-11-07T18:56Z**. Executing before then reverts (`operation is not ready`).

## Verifying the alert path without waiting for a timelock

```
GOV_DRY_RUN=1 GOV_CLOCK_SKEW=864000 GOV_STATE_FILE=/tmp/govstate \
  Coin/scripts/governance/governance-monitor.sh
```

prints what would be sent, including `gov.proposal.16.execute-due`, and the
second run is suppressed by the hourly hysteresis. `GOV_CLOCK_SKEW` is test-only;
production runs never set it.

## Adding a proposal to the executor

`omnibazaar-gov-execute-16.{service,timer}` are deliberately proposal-specific:
auto-executing arbitrary governance actions is a policy decision, not a default.
For another proposal, copy the pair with the new id in `ExecStart`, set
`GOV_EXEC_DISARM_UNIT` to the new timer, and `systemctl daemon-reload && enable
--now`. The monitor pages for it either way.
