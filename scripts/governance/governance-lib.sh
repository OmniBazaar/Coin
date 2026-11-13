#!/usr/bin/env bash
# Shared helpers for the OmniCoin governance scripts. Sourced, never executed.
#
# Both the monitor (which pages) and the executor (which acts) must agree on
# what "ready" means, and on how a timelock id is derived. One copy, so they
# cannot drift.

CAST=${CAST_BIN:-/home/omnirick/.foundry/bin/cast}
RPC=${GOV_RPC:-https://rpc.omnicoin.net}
GOV=${GOVERNOR:-0xa812904860c615FeCE377F17F87670EcA0E0899c}
TIMELOCK=${TIMELOCK_CONTROLLER:-0x4f78386cA05E333639151fe0508b21D893CaD222}
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
# The governance-weight account (iceberg-omnibazaar.pk). The deployer EOA holds
# zero voting power, so this is the only address whose vote matters.
GOV_VOTER=${GOV_VOTER_ADDRESS:-0x0d7a2C153979d095AbB4AE3ed7fCF5429A5cdd71}
# AlreadyVoted() — the node reports the selector, not the name.
SEL_ALREADY_VOTED=0x7c9a1cf9

gov_emit() {  # gov_emit <tag> <key> <logger-priority> <message>
    local tag="$1" key="$2" prio="$3" msg="$4"
    if [[ "${GOV_DRY_RUN:-0}" == "1" ]]; then
        echo "DRY[$prio] $key - $msg"
        return 0
    fi
    logger -t "$tag" -p "$prio" "sentryAlert: $key - $msg" 2>/dev/null || true
}

gov_prop_state() {  # gov_prop_state <id> -> decimal state, NOTFOUND, or ERROR
    local out
    if ! out=$("$CAST" call "$GOV" "state(uint256)(uint8)" "$1" --rpc-url "$RPC" 2>&1); then
        # state() reverts only for a proposal that does not exist (L-01 in the
        # contract). The node reports the custom-error SELECTOR, not its name,
        # so match both: 0x635e8737 == ProposalNotFound().
        if grep -qE "ProposalNotFound|0x635e8737" <<<"$out"; then echo NOTFOUND; else echo ERROR; fi
        return
    fi
    echo "${out%% *}"
}

gov_prop_state_name() {  # gov_prop_state_name <decimal>
    case "$1" in
        0) echo Pending ;; 1) echo Active ;; 2) echo Defeated ;; 3) echo Succeeded ;;
        4) echo Queued ;; 5) echo Executed ;; 6) echo Cancelled ;; 7) echo Expired ;;
        *) echo "Unknown($1)" ;;
    esac
}

gov_has_voted() {  # gov_has_voted <proposalId> [voter] -> true|false|unknown
    local id="$1" voter="${2:-$GOV_VOTER}" out
    if ! out=$("$CAST" call "$GOV" "hasVoted(uint256,address)(bool)" \
            "$id" "$voter" --rpc-url "$RPC" 2>/dev/null); then
        echo unknown
        return
    fi
    case "${out%% *}" in
        true) echo true ;;
        false) echo false ;;
        *) echo unknown ;;
    esac
}

gov_is_already_voted_error() {  # recognise AlreadyVoted however the tool phrases it
    grep -qiE "already voted|has voted|AlreadyVoted|${SEL_ALREADY_VOTED}" <<<"$1"
}

gov_vote_start() {  # gov_vote_start <id> -> unix seconds voting opened, or ""
    local id="$1" out line start
    out=$("$CAST" call "$GOV" \
        "proposals(uint256)(address,uint8,bool,bool,bool,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)" \
        "$id" --rpc-url "$RPC" 2>/dev/null) || {
        echo ""
        return
    }
    # cast prints one tuple field per line; voteStart is the 9th. A uint256 may
    # carry a human-readable suffix ("1794441331 [1.794e9]") — take the first
    # token, and refuse anything that is not plain digits.
    line=$(sed -n '9p' <<<"$out")
    start="${line%% *}"
    [[ "$start" =~ ^[0-9]+$ ]] && echo "$start"
}

# The unix time at which a Queued proposal may be executed, computed exactly as
# OmniGovernance._getTimelockId does:
#   salt = keccak256(abi.encodePacked("OmniGov", proposalId))
#   id   = keccak256(abi.encode(targets, values, calldatas, bytes32(0), salt))
# then read from the timelock controller. Prints "" if it cannot be determined —
# callers must treat that as a fault, not as "ready".
gov_timelock_ready_at() {  # gov_timelock_ready_at <id>
    local id="$1" actions targets values calldatas salt enc tid eta
    actions=$("$CAST" call "$GOV" "getActions(uint256)(address[],uint256[],bytes[])" "$id" --rpc-url "$RPC" 2>/dev/null) || {
        echo ""
        return
    }
    targets=$(sed -n '1p' <<<"$actions")
    values=$(sed -n '2p' <<<"$actions")
    calldatas=$(sed -n '3p' <<<"$actions")
    [[ -n "$targets" && -n "$values" && -n "$calldatas" ]] || {
        echo ""
        return
    }

    salt=$("$CAST" keccak "$("$CAST" concat-hex "$("$CAST" from-utf8 'OmniGov')" "$(printf '0x%064x' "$id")")" 2>/dev/null) || {
        echo ""
        return
    }
    enc=$("$CAST" abi-encode "f(address[],uint256[],bytes[],bytes32,bytes32)" \
        "$targets" "$values" "$calldatas" "$ZERO32" "$salt" 2>/dev/null) || {
        echo ""
        return
    }
    tid=$("$CAST" keccak "$enc" 2>/dev/null) || {
        echo ""
        return
    }
    eta=$("$CAST" call "$TIMELOCK" "getTimestamp(bytes32)(uint256)" "$tid" --rpc-url "$RPC" 2>/dev/null) || {
        echo ""
        return
    }
    echo "${eta%% *}"
}
