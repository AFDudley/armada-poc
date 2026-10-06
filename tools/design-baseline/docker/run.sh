#!/usr/bin/env bash
# ABOUTME: Single entry point for the isolated interactive-baseline pipeline — builds the runner
# ABOUTME: image and runs it with ONLY the worktree (+ its main repo clone, for git) and the
# ABOUTME: host's Playwright browser cache bind-mounted. No host networking, no published ports:
# ABOUTME: "localhost:8545" inside the container is this container's own loopback, never the
# ABOUTME: host's (which is already owned by an unrelated fixturenet — see tools/design-baseline/README.md).
#
# Usage:
#   tools/design-baseline/docker/run.sh                         # full pipeline, writes design-baseline/
#   tools/design-baseline/docker/run.sh --out=/tmp/run2          # alternate output dir (determinism proof)
#   tools/design-baseline/docker/run.sh --scenario=main          # one scenario only (debugging)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# This worktree's `.git` is a FILE ("gitdir: <main-repo>/.git/worktrees/<name>") rather than a
# directory — resolve the main repo clone's `.git` DIRECTORY it points at and mount ONLY that
# (objects/refs/worktrees metadata), never the main repo's checked-out WORKING TREE files. A
# plain (non-worktree) checkout has `.git` as a directory itself, in which case there's only one
# path to mount — the worktree dir IS the main repo in that case.
if [[ -f "$WORKTREE_DIR/.git" ]]; then
  GITDIR_PATH="$(sed -n 's/^gitdir: //p' "$WORKTREE_DIR/.git")"
  MAIN_REPO_GIT_DIR="${GITDIR_PATH%/worktrees/*}"
else
  MAIN_REPO_GIT_DIR=""
fi

IMAGE="design-baseline-runner:local"
docker build -t "$IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$WORKTREE_DIR"

MOUNT_ARGS=(-v "$WORKTREE_DIR:$WORKTREE_DIR")
if [[ -n "$MAIN_REPO_GIT_DIR" ]]; then
  MOUNT_ARGS+=(-v "$MAIN_REPO_GIT_DIR:$MAIN_REPO_GIT_DIR")
fi
# Playwright's Chromium binary (already downloaded on the host for the existing showcase/committer
# baseline) is bind-mounted read-only rather than redownloaded — the container only installs
# Chromium's OS-level shared libraries at image-build time (see Dockerfile).
if [[ -d "$HOME/.cache/ms-playwright" ]]; then
  MOUNT_ARGS+=(-v "$HOME/.cache/ms-playwright:/root/.cache/ms-playwright:ro")
fi

exec docker run --rm \
  --network bridge \
  "${MOUNT_ARGS[@]}" \
  -e WORKTREE_DIR="$WORKTREE_DIR" \
  -w "$WORKTREE_DIR" \
  "$IMAGE" "$@"
