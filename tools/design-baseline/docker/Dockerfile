# ABOUTME: Isolated runner image for the interactive committer baseline — Foundry's `anvil`
# ABOUTME: layered onto node:22-bookworm with Playwright's Chromium OS deps preinstalled.
#
# Why a custom image rather than --network host + the repo's own Anvil: the host already has
# port 8545 (and 8546) bound by an unrelated, concurrently-running fixturenet container. Any
# process that dials "localhost:8545" from the host network namespace reaches THAT chain, not
# ours — a previous agent's Hardhat deploy did exactly this when Anvil silently failed to bind.
# Everything that touches "localhost:8545" in this pipeline (anvil itself, Hardhat deploys, vite
# preview's same-origin fetch, and the Playwright-launched Chromium's injected wallet) runs
# INSIDE a container on Docker's default bridge network, where "localhost:8545" resolves to the
# container's own loopback — i.e. ALWAYS our own Anvil, never the host's. The container never
# publishes a port and never runs with --network host, so there is no path from this pipeline to
# the host's 8545/8546 at all (structural isolation, not a promise).
#
# anvil binary is copied from the upstream Foundry image (no network fetch / curl-to-root needed
# at build time beyond apt, and pins the exact Foundry build named in the task brief).
FROM ghcr.io/foundry-rs/foundry:v1.8.3 AS foundry

FROM node:22-bookworm AS runner

COPY --from=foundry /usr/local/bin/anvil /usr/local/bin/anvil

# Playwright's own Chromium OS dependency installer — the actual Chromium binary is NOT baked
# into the image; it's bind-mounted from the host's ~/.cache/ms-playwright at `docker run` time
# (already downloaded there for the existing showcase/committer baseline captures), so no browser
# download happens at image-build OR container-run time.
RUN npx -y playwright@1.63.0 install-deps chromium \
  && rm -rf /var/lib/apt/lists/*

# This container's /etc/hosts resolves "localhost" to ::1 only (no IPv4 loopback entry) and glibc's
# getaddrinfo address-selection (RFC 6724) prefers that IPv6 result — `vite preview` binds whatever
# "localhost" resolves to when no --host is given, so without this every 127.0.0.1 request this
# pipeline makes against it (proc.ts's own readiness probe, every Playwright `page.goto`) would get
# connection-refused. Forcing Node's DNS result order fixes it for every Node process in the
# container (vite preview, Hardhat, the tsx orchestrator) without touching any reused tool source.
ENV NODE_OPTIONS=--dns-result-order=ipv4first

# Baked into the image (not read from the bind-mounted worktree) so ENTRYPOINT doesn't depend on
# where docker/run.sh happens to mount the worktree on a given host.
COPY tools/design-baseline/docker/entrypoint.sh /usr/local/bin/design-baseline-entrypoint.sh
RUN chmod +x /usr/local/bin/design-baseline-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/design-baseline-entrypoint.sh"]
