#!/usr/bin/env bash
# ABOUTME: Gate probe for G6 (arp-93a): after the old governance stack is removed, the
# ABOUTME: project must still build and its Foundry tests must pass. Emits one JSON object
# ABOUTME: with the forge build exit code and the forge test exit code.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

forge build --offline >/dev/null 2>&1
build_exit_code=$?

forge test --offline >/dev/null 2>&1
test_exit_code=$?

printf '{"build_exit_code": %d, "test_exit_code": %d}\n' "$build_exit_code" "$test_exit_code"
