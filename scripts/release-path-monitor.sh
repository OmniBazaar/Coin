#!/usr/bin/env bash
# release-path-monitor.sh — page once when the release registry becomes
# unpublishable, and once when it recovers. Edge-triggered: a state that stays
# broken for two weeks must not page 300 times.
#
# The 2026-11-26 lesson: the publish path broke silently during a key sweep and
# was discovered during a release, costing two weeks of governance. This runs
# hourly so the discovery happens within the hour instead.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE=${RELEASE_PATH_STATE:-/home/omnirick/.omnibazaar-ops/state/release-path.state}
NODE_BIN=${NODE_BIN:-/usr/bin/node}
mkdir -p "$(dirname "$STATE")"

out=$("$NODE_BIN" "$HERE/check-update-registry-health.cjs" --json 2>/dev/null)
rc=$?
now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
prev=$(cat "$STATE" 2>/dev/null | tr -d '\n')

if [ "$rc" = "2" ]; then
  printf '%s could not read the chain\n' "$now" >"$STATE"
  logger -t omnibazaar-release-path -p user.warning \
    "sentryAlert: release.registry.unreadable - cannot read UpdateRegistry; the release path is UNWATCHED"
  exit 1
fi

if [ "$rc" != "0" ]; then
  reason=$(printf '%s' "$out" | "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).reason||"unknown")}catch{console.log("unknown")}})')
  if [[ "$prev" != unpublishable* ]]; then
    printf '%s unpublishable %s\n' "$now" "$reason" >"$STATE"
    logger -t omnibazaar-release-path -p user.warning \
      "sentryAlert: release.registry.unpublishable - $reason"
  else
    printf '%s unpublishable %s\n' "$now" "$reason" >"$STATE"
  fi
  exit 1
fi

if [[ "$prev" == unpublishable* ]]; then
  printf '%s ok\n' "$now" >"$STATE"
  logger -t omnibazaar-release-path -p user.info \
    "sentryAlert: release.registry.publishable - the registry can publish again (recovery)"
else
  printf '%s ok\n' "$now" >"$STATE"
fi
exit 0
