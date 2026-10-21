#!/usr/bin/env bash
# ABOUTME: Acceptance-oracle check for arp-ef0. The branch must not modify any
# ABOUTME: Solidity file under contracts/.
set -uo pipefail
cd "$(dirname "$0")/.."
BASE_SHA="${BASE_SHA:-6d18bb1140f2b433589713cd600627e8deb1df"
changed=$(git diff --name-only "$BASE_SHA" HEAD -- contracts/ | grep -c '\.sol$')
echo "{\"changed_sol_files\": ${changed:-0}"
exit 0
