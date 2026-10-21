#!/usr/bin/env bash
# ABOUTME: Gate probe for arp-63a.4 (c7): after the crowdfund constructor takes the
# ABOUTME: window duration argument, the Foundry build, the Hardhat compile, and a
# ABOUTME: TypeScript typecheck of the tests, scripts, and tasks must all finish without
# ABOUTME: errors. Emits one JSON object with the three exit codes.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

# c7: the Foundry build (all forge tests + harnesses still compile against the new
# constructor signature).
forge build >/dev/null 2>&1
forge_build_exit=$?

# c7: the Hardhat compile (Solidity artifacts + TS task/scripts type).
hardhat_compile_exit=0
npx hardhat compile >/dev/null 2>&1
hardhat_compile_exit=$?

# c7: the TypeScript typecheck over the tests, scripts, and tasks (the new constructor
# argument must be passed at every TS caller).
typescript_typecheck_exit=0
npx tsc -p tsconfig.json --noEmit >/dev/null 2>&1
typescript_typecheck_exit=$?

printf '{"forge_build_exit": %d, "hardhat_compile_exit": %d, "typescript_typecheck_exit": %d}\n' \
    "$forge_build_exit" "$hardhat_compile_exit" "$typescript_typecheck_exit"
