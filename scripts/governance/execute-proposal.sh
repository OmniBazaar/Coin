#!/usr/bin/env bash
# execute-proposal.sh <proposalId> — perform the ONE legal governance step, gated
# on the on-chain timelock.
#
# Founder directive 2026-10-31: execute proposal 16 once its timelock expires.
# This script is what the armed timer runs; it is safe to run at any time because
# it reads the state first and refuses to act early:
#
#   Executed  -> nothing to do, alert once (info), disarm the timer
#   Succeeded -> queue it (idempotent; the 14-day QUEUE_DEADLINE is running)
#   Queued    -> only if `timelock.getTimestamp(id) <= now`, execute; otherwise
#                exit quietly and let the interval come round again
#   Expired   -> alert (the vote is lost) and disarm
#   else      -> quiet exit
#
# The ETA is read from the timelock controller — never assumed from a checklist.
# Proposal 16's delay is 7 days (CRITICAL selector: a proxy upgrade), so the
# 48-hour figure that two documents carried would have produced a revert loop.
#
# Environment:
#   GOV_EXEC_DISARM_UNIT   systemd timer to disable after success (optional)
#   GOV_DRY_RUN=1          print instead of logging / instead of broadcasting
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=governance-lib.sh
source "$HERE/governance-lib.sh"

ID=${1:?usage: execute-proposal.sh <proposalId>}
LOG_TAG="omnibazaar-gov-executor"
COIN_DIR=${COIN_DIR:-/home/omnirick/OmniBazaar/Coin}
FINALIZER=${GOV_FINALIZER:-scripts/governance/finalize-revision-2026-10.cjs}
# 🛑 Repointed 2026-11-18. The old default was iceberg-omnibazaar.pk, the retired
# treasury key that the intruder copied on 2026-11-15. The treasury successor key
# never touches this host (it is cold), so there is deliberately no default path:
# set GOV_KEY_FILE to the successor key's location on the machine that runs this.
#
# 🛑 2026-11-21 — this was an unconditional `${GOV_KEY_FILE:?}` expansion, which
# killed the script on EVERY tick before it had read the proposal state. Once
# proposal 17 reached Succeeded (2026-11-18T23:55Z) that turned
# omnibazaar-gov-advance-17.service into a permanent silent failure: 253 failed
# runs, no page, no reason, and `systemctl status` showed only a bare shell error
# while the monitor separately paged `queue-due` with no hint that the executor
# could never act. A key is now required only by the branches that broadcast, and
# a missing key pages through emit_failure with the step that is stuck.
KEY_FILE="${GOV_KEY_FILE:-}"
ERR_STATE=${GOV_EXEC_ERR_STATE:-/tmp/.gov-exec-last-error}
# Which key signs the EXECUTE step.
#
# 🛑 execute(uint256) is PERMISSIONLESS — Coin/contracts/OmniGovernance.sol:700
# checks only that the state is Queued — so the signer of an execute carries no
# authority whatsoever; it pays gas and nothing else. Vote and queue are the
# opposite: they need the treasury's weight and admin role respectively, so they
# stay on GOV_KEY_FILE.
#
# Founder decision 2026-11-23, after proposal 17 sat past its timelock for four
# hours paging key-missing while a permissionless execute had nothing to wait
# for: the execute step signs with a local gas key so a queued proposal can never
# stall on a cold key again. Verified that day by executing proposal 17 with this
# key (tx 0xb4a26e98…b55c, block 3311430) — the recorder authorization landed.
#
# The default is the node gas faucet: it is dedicated, always funded, and already
# holds no special privilege anywhere.
GAS_KEY_FILE=${GOV_EXEC_GAS_KEY_FILE:-/home/omnirick/.omnibazaar-keys/node-gas-faucet.pk}
now=$(date +%s)

emit() { gov_emit "$LOG_TAG" "$@"; }

emit_failure() {  # emit_failure <key> <message-body>
    # One page per DISTINCT failure, then at most hourly while it persists, so a
    # fault that the next tick cannot fix does not become a drumbeat. The timer
    # ticks every 15 minutes; on 2026-11-12 the un-deduplicated vote path paged
    # 54 times in 13 hours.
    local key="$1" body="$2" last
    last=$(cat "$ERR_STATE" 2>/dev/null || true)
    if [[ "$key|$body" != "${last#*|}" ]] || (( now - ${last%%|*} > 3600 )); then
        printf '%s|%s|%s\n' "$now" "$key" "$body" >"$ERR_STATE"
        emit "$key" user.warning "$body"
    else
        echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') $key unchanged and already paged within the hour; not paging again"
    fi
}

need_key() {  # need_key <step> — stop, and page, when no signing key is configured
    # The treasury successor key is cold and deliberately absent from this host,
    # so "no key here" is a possible STEADY state, not a crash. Say so loudly and
    # once (emit_failure pages on a changed message, then hourly) instead of dying
    # with a bare shell error nobody sees.
    if [[ -n "$KEY_FILE" && -r "$KEY_FILE" ]]; then
        return 0
    fi
    emit_failure "gov.proposal.${ID}.key-missing" \
        "proposal $ID is $1 and needs a signature, but GOV_KEY_FILE is unset or unreadable — the treasury successor key 0x5169ce02 is cold and deliberately absent from this host; run this step from the machine that holds it: GOV_KEY_FILE=<path to successor key> $0 $ID"
    exit 1
}

exec_signer() {  # print the path of the key that signs EXECUTE; non-zero if none
    # Prefer the treasury key when it happens to be on this host (same outcome,
    # one fewer key in play); otherwise the local gas key, which is all that is
    # needed. Both are optional — a missing key is never fatal here.
    if [[ -n "$KEY_FILE" && -r "$KEY_FILE" ]]; then printf '%s' "$KEY_FILE"; return 0; fi
    if [[ -n "$GAS_KEY_FILE" && -r "$GAS_KEY_FILE" ]]; then printf '%s' "$GAS_KEY_FILE"; return 0; fi
    return 1
}

disarm() {
    local unit="${GOV_EXEC_DISARM_UNIT:-}"
    [[ -n "$unit" ]] || return 0
    if [[ "${GOV_DRY_RUN:-0}" == "1" ]]; then
        echo "DRY: would disable $unit"
        return 0
    fi
    sudo -n systemctl disable --now "$unit" 2>/dev/null || true
}

run_finalizer() {  # run_finalizer [key-file] — stdout+stderr of the hardhat script
    local keyfile="${1:-$KEY_FILE}"
    ( cd "$COIN_DIR" && \
      MAINNET_DEPLOYER_PRIVATE_KEY="$(cat "$keyfile")" PROPOSAL_ID="$ID" \
      timeout 900 npx hardhat run "$FINALIZER" --network mainnet 2>&1 )
}

run_voter() {  # cast a FOR vote once the window opens; non-zero on failure
    ( cd "$COIN_DIR" && \
      MAINNET_DEPLOYER_PRIVATE_KEY="$(cat "$KEY_FILE")" PROPOSAL_ID="$ID" VOTE_SUPPORT=1 \
      timeout 900 npx hardhat run "${GOV_VOTER:-scripts/governance/vote-revision-2026-10.cjs}" \
      --network mainnet 2>&1 )
}

st=$(gov_prop_state "$ID")
name=$(gov_prop_state_name "$st")
echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') proposal $ID state: $name"

case "$st" in
    ERROR)
        emit "gov.proposal.${ID}.execute-blocked" user.warning \
            "could not read proposal $ID state — governance is UNWATCHED until this is fixed"
        exit 2
        ;;
    5)
        echo "already executed; disarming"
        disarm
        exit 0
        ;;
    7)
        emit "gov.proposal.${ID}.expired" user.warning \
            "proposal $ID EXPIRED before it was queued — the vote is lost and must be re-proposed"
        disarm
        exit 1
        ;;
    1)
        # Voting is open. Cast the governance-weight FOR vote once. Check the
        # chain FIRST: a repeat run after the vote landed reverts AlreadyVoted
        # (selector 0x7c9a1cf9) and the node's message is a bare "execution
        # reverted", so string-matching the error alone pages a false failure
        # every interval (observed 2026-11-12 on proposal 17).
        voted=$(gov_has_voted "$ID")
        if [[ "$voted" == "true" ]]; then
            echo "vote already cast by $GOV_VOTER; nothing to do"
            exit 0
        fi
        need_key "Active, no vote from $GOV_VOTER"
        out=$(run_voter) && {
            emit "gov.proposal.${ID}.vote-cast" user.info \
                "proposal $ID: FOR vote cast by the governance-weight account"
            exit 0
        }
        if gov_is_already_voted_error "$out"; then
            echo "vote already cast by $GOV_VOTER (revert); nothing to do"
            exit 0
        fi
        emit_failure "gov.proposal.${ID}.vote-failed" \
            "proposal $ID is Active but the vote FAILED — $(tail -3 <<<"$out" | tr '\n' ' ' | cut -c1-300)"
        exit 1
        ;;
    3)
        # 🛑 `queue(uint256)` is PERMISSIONLESS, exactly like execute:
        # Coin/contracts/OmniGovernance.sol:639 checks only that the state is
        # Succeeded and that the QUEUE_DEADLINE has not passed — no role, no
        # caller check. 2026-11-25: this branch used to require the cold treasury
        # key (need_key), which meant a Succeeded proposal could only be queued
        # from the machine that holds 0x5169ce02. That is wrong — the signer
        # carries no authority, it only pays gas. Same treatment as the execute
        # step (founder decision 2026-11-23).
        QUEUE_KEY=$(exec_signer) || {
            emit_failure "gov.proposal.${ID}.key-missing" \
                "proposal $ID is Succeeded, but neither GOV_KEY_FILE nor the local gas key ($GAS_KEY_FILE) is readable — queue is permissionless, so any funded key works; set GOV_EXEC_GAS_KEY_FILE"
            exit 1
        }
        if [[ "$QUEUE_KEY" != "$KEY_FILE" ]]; then
            echo "signing queue with the local gas key $QUEUE_KEY (queue is permissionless; the signer holds no authority, it only pays gas)"
        fi
        out=$(run_finalizer "$QUEUE_KEY") || {
            emit "gov.proposal.${ID}.queue-failed" user.warning \
                "queueing proposal $ID FAILED — $(tail -3 <<<"$out" | tr '\n' ' ' | cut -c1-300)"
            exit 1
        }
        st2=$(gov_prop_state "$ID")
        emit "gov.proposal.${ID}.queued" user.info \
            "proposal $ID queued (state now $(gov_prop_state_name "$st2"))"
        exit 0
        ;;
    4)
        eta=$(gov_timelock_ready_at "$ID")
        if [[ -z "$eta" ]]; then
            emit "gov.proposal.${ID}.execute-blocked" user.warning \
                "proposal $ID is Queued but its timelock ETA could not be read — refusing to broadcast blind"
            exit 2
        fi
        if (( eta > now )); then
            echo "not ready until $(date -u -d "@$eta" '+%Y-%m-%dT%H:%MZ'); nothing to do"
            exit 0
        fi
        echo "timelock expired at $(date -u -d "@$eta" '+%Y-%m-%dT%H:%MZ') — executing"
        EXEC_KEY=$(exec_signer) || {
            emit_failure "gov.proposal.${ID}.key-missing" \
                "proposal $ID is Queued and past its timelock ETA, but neither GOV_KEY_FILE nor the local gas key ($GAS_KEY_FILE) is readable — execute is permissionless, so any funded key works; set GOV_EXEC_GAS_KEY_FILE"
            exit 1
        }
        if [[ "$EXEC_KEY" != "$KEY_FILE" ]]; then
            echo "signing execute with the local gas key $EXEC_KEY (execute is permissionless; the signer holds no authority, it only pays gas)"
        fi
        out=$(run_finalizer "$EXEC_KEY")
        rc=$?
        st2=$(gov_prop_state "$ID")
        if [[ "$st2" == "5" ]]; then
            tx=$(grep -oE '^(executed|queued): 0x[0-9a-fA-F]{64}' <<<"$out" | tail -1)
            emit "gov.proposal.${ID}.executed" user.warning \
                "proposal $ID EXECUTED${tx:+ ($tx)} — follow-through: rebuild + roll the five gateways, then post-revision-wiring.cjs if this revision needs it"
            rm -f "$ERR_STATE"
            disarm
            exit 0
        fi
        # Failed while legally ready. De-duplicate (emit_failure): page when the
        # error changes, and at most once an hour otherwise.
        emit_failure "gov.proposal.${ID}.execute-failed" \
            "proposal $ID is legally ready but execute FAILED (rc=$rc) — $(tail -3 <<<"$out" | tr '\n' ' ' | cut -c1-300)"
        exit 1
        ;;
    *)
        echo "nothing to do in state $name"
        exit 0
        ;;
esac
