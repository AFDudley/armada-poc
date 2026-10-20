#!/usr/bin/env bash
# ABOUTME: Gate check for G5-hedgey (arp-bb3): the vendored Hedgey lockup, the
# ABOUTME: non-cancelable plan, and the ArmadaToken whitelist ordering. Every mode
# ABOUTME: derives its JSON from the real forge test output and the real tree; no
# ABOUTME: value is hardcoded. Modes: vendored, deploy, whitelist, forge, check-negative.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_PATH="test-foundry/HedgeyLockup.t.sol"

MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --mode) MODE="$2"; shift 2 ;;
  --mode=*) MODE="${1#--mode=}"; shift ;;
  *) shift ;;
  esac
done

# Run the forge test with -vv so the test's console.log probe line is captured, and
# recover the suite pass/fail counts. On a test failure forge exits non-zero and this
# propagates, so a broken property is never reported as success.
run_forge() {
  (cd "$ROOT" && forge test --match-path "$TEST_PATH" -vv --offline 2>&1)
}

# Emit the mode-specific JSON. $1 is the full forge output.
emit() {
  local output="$1" mode="$2"
  local probe summary tests_passed tests_failed
  probe=$(printf '%s\n' "$output" | grep -oE '\{"cancelable":.*\}' | head -n 1)
  summary=$(printf '%s\n' "$output" | grep -E 'test suite|tests passed' | head -n 1)
  tests_passed=$(printf '%s\n' "$summary" | sed -nE 's/.* ([0-9]+) tests passed.*/\1/p')
  tests_failed=$(printf '%s\n' "$summary" | sed -nE 's/.*tests passed, ([0-9]+) failed.*/\1/p')
  tests_passed=${tests_passed:-0}
  tests_failed=${tests_failed:-0}
  printf '%s\n' "$probe" | MODE="$mode" TP="$tests_passed" TF="$tests_failed" python3 -c '
import json, os, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.stderr.write("no probe JSON emitted by the forge test\n")
    sys.exit(1)
p = json.loads(raw)
mode = os.environ["MODE"]
tp = int(os.environ["TP"]); tf = int(os.environ["TF"])
if mode == "deploy":
    out = {"planCount": p["planCount"], "cancelable": p["cancelable"]}
elif mode == "whitelist":
    out = {
        "whitelisted": p["whitelisted"],
        "whitelistedBeforeTransfer": p["whitelistedBeforeTransfer"],
        "nonTimelockCallerReverted": p["nonTimelockCallerReverted"],
    }
elif mode == "forge":
    out = {"testsFailed": tf, "testsPassed": tp}
elif mode == "check-negative":
    out = {
        "goodDeployAccepted": (p["cancelable"] is False and p["whitelisted"] is True and tf == 0),
        "cancelableRejected": p["cancelableDetected"],
        "notWhitelistedRejected": p["nonWhitelistedDetected"],
    }
else:
    sys.stderr.write("unknown mode\n"); sys.exit(1)
print(json.dumps(out))
'
}

case "$MODE" in
vendored)
  vendored=false
  if [[ -d "$ROOT/lib/hedgey/contracts" ]]; then vendored=true; fi
  pinned=false
  if [[ -f "$ROOT/lib/hedgey/pin.json" ]] \
    && grep -qE 'hedgey-token-plans-audit-2023-06|Consensys-Diligence' "$ROOT/lib/hedgey/pin.json"; then
    pinned=true
  fi
  printf '{"vendoredUnderLib": %s, "pinnedToAuditedTag": %s}\n' "$vendored" "$pinned"
  ;;
deploy | whitelist | forge | check-negative)
  OUT=$(run_forge)
  emit "$OUT" "$MODE"
  ;;
*)
  echo '{"error": "unknown mode"}' >&2
  exit 1
  ;;
esac
