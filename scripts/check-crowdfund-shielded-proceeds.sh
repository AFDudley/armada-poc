#!/usr/bin/env bash
# ABOUTME: Gate check for G5 (arp-c7a): run the shielded-proceeds test and emit one JSON
# ABOUTME: object combining the test's probe (Safe note, treasury delta, reentrancy,
# ABOUTME: allowance) with the suite pass/fail counts.
set -euo pipefail

target="${1:-test-foundry/CrowdfundShieldedProceeds.t.sol}"

# Run forge with -vv so the test's console.log probe output is captured.
output=$(forge test --match-path "$target" -vv 2>&1) || exit $?

# Extract the probe JSON object (braces included) that the test emitted.
probe=$(printf '%s\n' "$output" | grep -oE '\{"safe_note_count":.*\}' | head -n 1)

# Suite results from the forge summary line ("… test suite …: N tests passed, M failed").
summary=$(printf '%s\n' "$output" | grep -E 'test suite' | head -n 1)
tests_passed=$(printf '%s\n' "$summary" | sed -E 's/.*: ([0-9]+) tests passed.*$/\1/')
tests_failed=$(printf '%s\n' "$summary" | sed -E 's/.*: [0-9]+ tests passed, ([0-9]+) failed.*$/\1/')

# Merge the suite results into the probe object via python3 (safe JSON manipulation).
printf '%s\n' "$probe" | TP="$tests_passed" TF="$tests_failed" python3 -c '
import json, os, sys
d = json.loads(sys.stdin.read())
d["tests_passed"] = int(os.environ["TP"])
d["tests_failed"] = int(os.environ["TF"])
print(json.dumps(d))
'
