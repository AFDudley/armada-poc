# armada-poc commit-boundary gate image (D49, ADR
# exophial/docs/decisions/2026-10-14-gate-runs-in-a-container-built-from-the-judged-commit.md).
#
# gate_container.build_gate_image builds this image from the judged commit's
# own tree: a tar of the working tree (with .git and .scratch excluded)
# streamed to `docker build --quiet -f .exophial/gate/Dockerfile -`.
# gate_container.run_in_container then runs the configured gate.command as the
# sole process: `docker run --rm -i --privileged`, NO -v, NO -e. The image's
# own ENV / HOME / WORKDIR are all the container sees (D49.5/D49.6).
#
# The gate.command (.exophial/config.yaml) is, in order:
#   npm ci --legacy-peer-deps --offline --no-audit --no-fund
#   pre-commit run --all-files
#   ./scripts/check-anvil-addresses.sh
#   npm run compile          (hardhat compile)
#   npm run check:sizes      (node scripts/check-contract-sizes.js)
#   npx tsc --noEmit --project tsconfig.ci.json
#   forge test --offline
#
# So every toolchain those steps invoke is IMAGE CONTENT, pinned to the
# versions the host runs today:
#   python 3.12 + uv + git + the exophial wheel  -> from exophial-e2e-base
#       (the local hooks claude-md-coverage and reroute-main-commit call the
#        console scripts exophial-check-claude-md, exophial-reroute-main-commit)
#   node 24.18.0 + npm 11.16.0                    -> npm ci, eslint, prettier,
#                                                    hardhat compile, tsc
#   foundry forge/cast/anvil v1.8.3               -> forge fmt, forge test
#   the npm cache                                 -> npm ci --offline
#   the hardhat solc 0.8.17 + 0.8.20 cache        -> hardhat compile offline
#   the forge svm solc 0.8.17 + 0.8.20 cache      -> forge test --offline
#   the pre-commit hook environments              -> pre-commit run --all-files
#
# armada-poc carries NO git submodules (no .gitmodules, no foundry.lock): lib/*
# is tracked as plain files in the judged tree, so no submodule fetch step runs
# at build and forge reads the committed lib/* sources directly.
FROM exophial-e2e-base

USER root
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl xz-utils ca-certificates build-essential pkg-config git \
    && rm -rf /var/lib/apt/lists/*

# --- Node 24.18.0 + npm 11.16.0 (the host's versions) ---
RUN curl -fsSL https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-x64.tar.xz \
        | tar -xJ -C /usr/local --strip-components=1 \
    && npm install -g npm@11.16.0

# --- Foundry forge/cast/anvil v1.8.3 (the official pinned image's binaries) ---
COPY --from=ghcr.io/foundry-rs/foundry:v1.8.3 \
        /usr/local/bin/forge /usr/local/bin/cast /usr/local/bin/anvil \
        /usr/local/bin/

# --- pre-commit 4.5.1 (the host's version) on PATH via uv tool, alongside the
#     exophial console scripts the base already installs
#     (exophial-check-claude-md, exophial-reroute-main-commit) that the local
#     hooks call. ---
RUN uv tool install pre-commit==4.5.1

WORKDIR /gate
COPY . .

# `docker build --quiet` (what gate_container.build_gate_image runs) is BuildKit
# `-q` on this host (Docker 28). A RUN step that streams a large volume to the
# build-step pipe under `-q` dies mid-write (npm ci exited 146 that way). So each
# heavy step below writes its own output to a log file, never to the step pipe,
# and prints the log tail only on failure. This makes the build deterministic
# under the exact `--quiet` invocation the gate uses.

# --- npm cache + node_modules so the gate's own `npm ci --offline` resolves.
#     npm ci writes every fetched tarball into the image's ~/.npm cache, which
#     the offline ci at gate time then restores from. ---
RUN npm ci --legacy-peer-deps --no-audit --no-fund --loglevel=error \
        > /tmp/npm-ci.log 2>&1 || { tail -c 40000 /tmp/npm-ci.log; exit 1; }

# --- hardhat solc 0.8.17 + 0.8.20 cache. `hardhat compile` downloads the
#     pinned solc builds into ~/.cache/hardhat-nodejs here, where the build has
#     network; the gate run's `npm run compile` is then offline. ---
RUN npm run compile > /tmp/compile.log 2>&1 \
        || { tail -c 40000 /tmp/compile.log; exit 1; }

# --- forge svm solc 0.8.17 + 0.8.20 cache. `forge build` compiles contracts/,
#     test-foundry/ and script/ and downloads the pinned solc builds into
#     ~/.svm here; the gate run's `forge test --offline` is then offline.
#     lint_on_build = false (foundry.toml) keeps forge build on its pre-lint
#     behavior, the same as the host. ---
RUN forge build > /tmp/forge-build.log 2>&1 \
        || { tail -c 40000 /tmp/forge-build.log; exit 1; }

# --- A throwaway git history (the judged tree carries no .git, D49.4/D49.5)
#     gives pre-commit a repo. `git add -A` honors .gitignore, so node_modules,
#     artifacts/, cache/, forge-out/ and out/ stay untracked, exactly the file
#     set `pre-commit run --all-files` sees on the host.
#     pre-commit install-hooks materializes every hook's env offline.
#     install-hooks (not install) registers no git hook, so this build-time
#     commit fires none. The history is on a NON-main branch: the gate run's
#     `pre-commit run --all-files` runs reroute-main-commit, which refuses a
#     commit on main/master, so the throwaway branch must not be one. ---
RUN { git init -q -b gate-tree \
        && git add -A \
        && git -c user.email=gate@armada-poc -c user.name=gate \
               commit -qm "gate tree" \
        && pre-commit install-hooks --config .pre-commit-config.yaml ; } \
        > /tmp/precommit.log 2>&1 || { tail -c 40000 /tmp/precommit.log; exit 1; }

# No ENTRYPOINT: run_in_container passes the gate.command directly, and it runs
# in WORKDIR /gate with this image's PATH.
