#!/usr/bin/env bash
# governance-monitor — ALERT-CLASS watch on OmniCoin governance.
#
# Founder directive 2026-10-31: "Make governance issues ALERT class. I want to
# know about them through the alert system when they happen." Before this, a
# proposal could sit at Succeeded for two days (Sentry NODE-25, proposal 16) or
# reach its timelock with nobody told, because the one notice was hand-emitted.
#
# What it watches, by `OmniGovernance.state(proposalId)`:
#
#   Active    -> gov.proposal.<id>.voting-open   ALERT  (needs votes)
#   Succeeded -> gov.proposal.<id>.queue-due     ALERT  (expires 14 days after voting closed)
#   Queued    -> gov.proposal.<id>.execute-due   ALERT  (only once the timelock ETA has passed)
#   Expired   -> gov.proposal.<id>.expired       ALERT  (window missed; must be re-proposed)
#   Executed  -> gov.proposal.<id>.executed      ALERT  once (follow-through: rebuild + roll)
#   Queued (not yet ready), Defeated, Cancelled  -> info/quiet (nothing to do)
#
# ALERT = `logger -p user.warning`, which the Vector forwarder files as a Sentry
# issue. `executed` is alert-class because it starts work (rebuild + roll), but
# it fires once ever AND only for a proposal this monitor previously saw
# awaiting action — otherwise the first run would page once per historical
# execution. Info = `user.info`, dropped by the forwarder; a self-heal must not
# sit in the issue list forever (memory/alerting_hygiene_2026-10-25.md).
#
# Standing conditions re-emit at most once an hour while they persist, and emit
# one `resolved` info when they clear.
#
# The timelock ETA is read from the timelock controller, never assumed:
# proposal 16's own delay is 7 days (CRITICAL selector — a proxy upgrade), not
# the 48h ROUTINE delay the checklist had written down.
#
# Exit: 0 nothing outstanding, 1 at least one ALERT emitted, 2 the monitor could
# not read governance state (the worst case — silence would look like health).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=governance-lib.sh
source "$HERE/governance-lib.sh"

LOG_TAG="omnibazaar-gov-monitor"
STATE_FILE=${GOV_STATE_FILE:-/home/omnirick/OmniBazaar/Validator/backups/.gov_state}
REEMIT_SECONDS=${GOV_REEMIT_SECONDS:-3600}
# Voting must be open this long before a missing vote is worth a human's
# attention — the auto-voter ticks every 15 minutes, so 45 minutes is three
# missed attempts. Proposal 17 paged 12 seconds after voting opened and 12
# seconds after our own vote landed (2026-11-11T23:59:33Z).
VOTE_GRACE_SECONDS=${GOV_VOTE_GRACE_SECONDS:-2700}
MAX_PROPOSALS=${GOV_MAX_PROPOSALS:-200}

state_keys=()
alerts=0
# GOV_CLOCK_SKEW exists so the alerting path can be verified without waiting for
# a real timelock; it never affects a production run (defaults to 0).
now=$(( $(date +%s) + ${GOV_CLOCK_SKEW:-0} ))
tmp_state=$(mktemp) || exit 2
trap 'rm -f "$tmp_state"' EXIT

emit() { gov_emit "$LOG_TAG" "$@"; }

die() {  # the monitor itself is broken; silence would look like health
    emit "gov.monitor.failed" user.warning "$1"
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') MONITOR FAILED: $1"
    exit 2
}

[[ -x "$CAST" ]] || die "cast not found at $CAST — governance is UNWATCHED until this is fixed"

declare -A emit_at=() once_done=()
if [[ -f "$STATE_FILE" ]]; then
    while IFS='|' read -r k ts mode; do
        [[ -n "${k:-}" ]] || continue
        if [[ "$mode" == "once" ]]; then once_done["$k"]="$ts"; else emit_at["$k"]="$ts"; fi
    done <"$STATE_FILE"
fi

want() {  # want <key> <priority> <message> <once|repeat>
    local key="$1" prio="$2" msg="$3" mode="${4:-repeat}" ts
    state_keys+=("$key|$mode")
    if [[ "$mode" == "once" ]]; then
        [[ -n "${once_done[$key]:-}" ]] && return 0
    else
        ts=${emit_at[$key]:-0}
        (( now - ts < REEMIT_SECONDS )) && return 0
    fi
    emit "$key" "$prio" "$msg"
    (( alerts++ ))
    # Record THIS emission's time. Without it the ledger keeps the original
    # timestamp forever and the hourly guard inverts: once `now - ts` first
    # exceeds REEMIT_SECONDS every later run re-emits (2026-11-12 — proposal
    # 17's voting-open paged every 10 minutes for 13 hours because the ledger
    # still held 23:59).
    if [[ "$mode" != "once" ]]; then emit_at["$key"]="$now"; fi
    return 0
}

for (( id = 1; id <= MAX_PROPOSALS; id++ )); do
    st=$(gov_prop_state "$id")
    case "$st" in
        NOTFOUND) break ;;
        ERROR) die "could not read state($id) from $GOV — governance is UNWATCHED until this is fixed" ;;
    esac

    # Remember every proposal ever seen awaiting action, so a later `executed`
    # is a transition WE witnessed rather than a backfill of history. Without
    # this the first run pages once per historically executed proposal.
    if [[ "$st" == "1" || "$st" == "3" || "$st" == "4" ]]; then
        once_done["gov.proposal.${id}.watched"]="${once_done[gov.proposal.${id}.watched]:-$now}"
    fi

    case "$st" in
        1) # Active. Only page when a human can still change the outcome:
           # once the governance-weight account has voted there is no human
           # action left, and the auto-voter deserves a grace window before a
           # still-missing vote is called a problem. Proposal 17 on 2026-11-12
           # paged "cast a vote" for 14 hours AFTER the vote landed.
           if [[ "$(gov_has_voted "$id")" == "true" ]]; then
               echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') proposal $id open for voting; vote already cast by $GOV_VOTER — no action needed"
           else
               started=$(gov_vote_start "$id")
               if [[ -n "$started" ]] && (( now - started < VOTE_GRACE_SECONDS )); then
                   echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') proposal $id open for voting, no vote yet — inside the $(date -u -d "@$(( started + VOTE_GRACE_SECONDS ))" '+%Y-%m-%dT%H:%MZ') grace window, leaving it to the auto-voter"
               else
                   want "gov.proposal.${id}.voting-open" user.warning \
                       "proposal $id is OPEN FOR VOTING and still has no vote from $GOV_VOTER — cast a vote before it closes"
               fi
           fi
           ;;
        3) want "gov.proposal.${id}.queue-due" user.warning \
               "proposal $id has PASSED and is waiting to be QUEUED — it expires 14 days after voting closed" ;;
        4) eta=$(gov_timelock_ready_at "$id")
           if [[ -z "$eta" ]]; then
               die "proposal $id is Queued but its timelock ETA could not be read — governance is UNWATCHED until this is fixed"
           fi
           if (( eta <= now )); then
               want "gov.proposal.${id}.execute-due" user.warning \
                   "proposal $id timelock EXPIRED at $(date -u -d "@$eta" '+%Y-%m-%dT%H:%MZ') — EXECUTE IT (no further delay)"
           else
               echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') proposal $id queued; timelock expires $(date -u -d "@$eta" '+%Y-%m-%dT%H:%MZ')"
           fi
           ;;
        5) [[ -n "${once_done[gov.proposal.${id}.watched]:-}" ]] && want "gov.proposal.${id}.executed" user.warning \
               "proposal $id EXECUTED — follow-through: rebuild + roll the five gateways (post-revision-wiring.cjs if this revision needs it)" once ;;
        7) want "gov.proposal.${id}.expired" user.warning \
               "proposal $id EXPIRED unqueued — the vote is lost and must be re-proposed" ;;
        2) echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') proposal $id defeated (no action)" ;;
        6) echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') proposal $id cancelled (no action)" ;;
        *) : ;;
    esac
done

# Rewrite the ledger: surviving repeat keys keep their original emit time (so
# the hourly clock is not reset), one-shot memory is kept forever.
declare -A keep_repeat=() keep_once=()
for entry in ${state_keys[@]+"${state_keys[@]}"}; do
    k=${entry%%|*}
    mode=${entry##*|}
    if [[ "$mode" == "once" ]]; then
        keep_once["$k"]="${once_done[$k]:-$now}"
    else
        keep_repeat["$k"]="${emit_at[$k]:-$now}"
    fi
done

{
    for k in "${!keep_repeat[@]}"; do echo "$k|${keep_repeat[$k]}|repeat"; done
    for k in "${!keep_once[@]}"; do echo "$k|${keep_once[$k]}|once"; done
    for k in "${!once_done[@]}"; do
        [[ -n "${keep_once[$k]:-}" ]] || echo "$k|${once_done[$k]}|once"
    done
} >"$tmp_state" || exit 2
mv -f "$tmp_state" "$STATE_FILE" 2>/dev/null || exit 2

# A condition that no longer holds is a recovery notice, not an error.
for k in "${!emit_at[@]}"; do
    [[ -n "${keep_repeat[$k]:-}" ]] || emit "${k}.resolved" user.info "no longer true (governance monitor)"
done

if (( alerts > 0 )); then
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') GOVERNANCE ALERT (${alerts} key(s) emitted)"
    exit 1
fi
echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') OK — no governance action outstanding"
exit 0
