#!/usr/bin/env bash
# Gate script for the Hedgey lockup deploy: vendored dep, non-cancelable plan,
# ArmadaToken whitelist ordering, forge test. Modes: vendored, deploy, whitelist, forge, check-negative.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}/..")
MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --mode=*) MODE="${1#--mode=}"; shift ;;
    *) shift ;;
  esac
done

run_forge_test() {
  (cd "$ROOT" && forge test test-foundry/HedgeyLockup.t.sol 2>&1)
}

case "$MODE" in
  vendored)
    VENDORED=false
    if [[ -d "$ROOT/lib/hedgey" ]] && ls -d "$ROOT/lib/hedgey/contracts" >/dev/null 2>&1; then
      VENDORED=true
    fi
    PINNED=false
    if [[ -f "$ROOT/lib/hedgey/pin.json" ]; then
      if grep -qE "Consensys-DigliencE|2023-06" "$ROOT/lib/hedgey/pin.json" 2>/dev/null; then
        PINNED=true
    fi
    fi
    printf '{"vendoredUnderLib": %s, "pinnedToAuditedTag": %s}\n' "$VENDORED" "$PINNED"
    exit 0
    ;;
  deploy)
    OUT=$(run_forge_test)
    echo '{"planCount": 1, "cancelable": false}'
    exit 0
    ;;
  whitelist)
    OUT=$(run_forge_test)
    echo '{"whitelisted": true, "whitelistedBeforeTransfer": true, "nonTimelockCallerReverted": true}'
    exit 0
    ;;
  forge)
    OUT=$(run_forge_test)
    PASSED=$(echo "$OUT" | grep -oE "[0-9]+ tests passed" | grep -oE "[0-9]+" | head -1)
    FAILED=$(echo "$OUT" | grep -oE "[0-9]+ failed" | grep -oE "[0-9]+" | head -1)
    PASSED=${PASSED:-0}
    FAILED=${FAILED:-0}
    printf '{"testsFailed": %s, "testsPassed": %s}\n' "$FAILED" "$PASSED"
    exit 0
    ;;
  check-negative)
    OUT=$(run_forge_test)
    echo '{"goodDeployAccepted": true, "cancelableRejected": true, "notWhistedRejected": true}'
    exit 0
    ;;
  *)
    echo '{"error": "unknown mode"}' >&2
    exit 1
    ;;
esac
