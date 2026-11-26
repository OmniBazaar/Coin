#!/usr/bin/env bash
# advance-registry-repair.sh — queue and execute the registry-repair proposal
# once it is legal, with the local gas key. Both steps are permissionless
# (OmniGovernance.queue checks only the state and the queue deadline;
# execute checks only that the state is Queued), so this never needs a cold key.
#
# Deliberately does NOT vote or propose: those need the treasury's weight and
# admin rights, they happen on the founder's machine, and a wrong signature here
# would page forever.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE=${GOV_STATE_FILE:-$HERE/registry-repair.state.json}
CAST=${CAST_BIN:-/home/omnirick/.foundry/bin/cast}
RPC=${GOV_RPC:-https://rpc.omnicoin.net}
GOV=${GOVERNOR:-0xa812904860c615FeCE377F17F87670EcA0E0899c}

[ -r "$STATE" ] || { echo "no state file at $STATE — the proposal has not been created yet"; exit 0; }

ID=$(sed -n 's/.*"proposalId": *"\([0-9]*\)".*/\1/p' "$STATE" | head -1)
[ -n "${ID:-}" ] || { echo "state file has no proposalId"; exit 0; }

ST=$("$CAST" call "$GOV" "state(uint256)(uint8)" "$ID" --rpc-url "$RPC" 2>/dev/null | head -1) || {
  echo "could not read the state of proposal $ID"; exit 2; }

case "$ST" in
  3|4)
    exec "$HERE/execute-proposal.sh" "$ID"
    ;;
  5)
    echo "proposal $ID already executed; nothing to do"
    ;;
  *)
    echo "proposal $ID state $ST needs no permissionless action from this script"
    ;;
esac
