#!/usr/bin/env bash
# ABOUTME: Container entrypoint — installs dependencies fresh inside the image's own Node
# ABOUTME: runtime (native addons must match THIS container's Node ABI, not the host's), then
# ABOUTME: runs the TypeScript orchestrator that drives anvil + Hardhat deploys + Playwright.
set -euo pipefail

# The worktree's `.git` is a FILE pointing at an absolute host path inside the main repo clone's
# `.git/worktrees/<name>` — `run.sh` bind-mounts both the worktree AND the main repo clone at
# their real host paths (not relocated into the container) so that pointer resolves, and
# `safe.directory` is needed because the container's root user doesn't own the bind-mounted files.
git config --global --add safe.directory "*"

cd "$WORKTREE_DIR"

echo "[entrypoint] npm install --legacy-peer-deps (repo root)"
npm install --legacy-peer-deps

echo "[entrypoint] installing optional native build deps (best-effort, --no-save)"
npm install --no-save \
  @rollup/rollup-linux-x64-gnu \
  lightningcss-linux-x64-gnu \
  @tailwindcss/oxide-linux-x64-gnu \
  || echo "[entrypoint] optional native deps install failed/skipped — continuing"

echo "[entrypoint] npm install (tools/design-baseline)"
(cd tools/design-baseline && npm install)

echo "[entrypoint] hardhat compile"
npm run compile

echo "[entrypoint] running orchestrator: $*"
exec npx tsx tools/design-baseline/src/orchestrate.ts "$@"
