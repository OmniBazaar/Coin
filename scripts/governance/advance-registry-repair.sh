#!/usr/bin/env bash
# advance-registry-repair.sh — queue and execute the registry-repair proposal
# once it is legal, with the local gas key.
#
# Both steps are permissionless: OmniGovernance.queue checks only that the state
# is Succeeded and inside the queue deadline, and execute checks only that the
# state is Queued. So this never needs the cold treasury key, and it deliberately
# cannot vote or propose — those need the treasury's weight and happen on the
# founder's machine.
#
# The proposal is found by DESCRIPTION HASH, not by a local state file: the
# founder proposes from Windows, this box never sees his state file, and a
# hardcoded id would break the first time anything else is proposed.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CAST=${CAST_BIN:-/home/omnirick/.foundry/bin/cast}
RPC=${GOV_RPC:-https://rpc.omnicoin.net}
GOV=${GOVERNOR:-0xa812904860c615FeCE377F17F87670EcA0E0899c}
# keccak256 of the DESCRIPTION constant in registry-repair.mjs
DESC_HASH=${REGISTRY_REPAIR_DESC_HASH:-0x23a1ee03427b4b73250155b9a8f118177e6300aa8c9f2c2db275e2073971db9a}
# Proposals below this id predate the repair.
SCAN_FROM=${REGISTRY_REPAIR_SCAN_FROM:-20}

COUNT=$("$CAST" call "$GOV" "proposalCount()(uint256)" --rpc-url "$RPC" 2>/dev/null | head -1) || {
  echo "could not read proposalCount"; exit 2; }
COUNT=${COUNT%% *}

FOUND=""
for id in $(seq "$SCAN_FROM" "$COUNT"); do
  # proposals(id) → proposer, proposalType, executed, cancelled, queued,
  #                 descriptionHash, snapshotBlock, ...
  H=$("$CAST" call "$GOV" \
      "proposals(uint256)(address,uint8,bool,bool,bool,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)" \
      "$id" --rpc-url "$RPC" 2>/dev/null | sed -n 6p) || continue
  if [ "${H,,}" = "${DESC_HASH,,}" ]; then FOUND=$id; break; fi
done

if [ -z "$FOUND" ]; then
  echo "registry-repair proposal not proposed yet (scanned $SCAN_FROM..$COUNT) — nothing to do"
  exit 0
fi

ST=$("$CAST" call "$GOV" "state(uint256)(uint8)" "$FOUND" --rpc-url "$RPC" 2>/dev/null | head -1)
case "$ST" in
  3|4) exec "$HERE/execute-proposal.sh" "$FOUND" ;;
  5)   echo "proposal $FOUND already executed" ;;
  *)   echo "proposal $FOUND state $ST — no permissionless action needed yet" ;;
esac
