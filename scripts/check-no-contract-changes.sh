#!/usr/bin/env bash
# ABOUTME: Counts Solidity files under contracts/ changed against the base branch. The arp-ef0
# ABOUTME: dedup changes no contract, so this must report zero. Emits JSON {changed_sol_files} and
# ABOUTME: exits non-zero when any contract .sol changed.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

BASE="${BASE_REF:-integrated}"
if git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1; then
  base_commit="$(git merge-base HEAD "${BASE}" 2>/dev/null || echo "${BASE}")"
else
  base_commit="HEAD"
fi

changed="$(git diff --name-only --diff-filter=ACMR "${base_commit}" HEAD -- contracts/ \
  | grep -cE '\.sol$' || true)"

echo "{\"changed_sol_files\": ${changed}}"
[ "${changed}" -eq 0 ]
