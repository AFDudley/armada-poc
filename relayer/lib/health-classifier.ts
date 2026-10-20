// ABOUTME: Pure classifier — folds (lastError, lastScanAt, pollIntervalMs, lagBlocks) into one of
// ABOUTME: four status buckets used by the /health endpoint. Kept dependency-free + side-effect-free so
// ABOUTME: it's unit-testable without spinning up an iris-relay / cctp-relay module.

import type { ChainHealthStatus } from "../types";

/**
 * Threshold multipliers expressed relative to the chain's configured pollIntervalMs.
 *
 * Why relative to pollInterval rather than absolute ms? Different chains run different poll
 * cadences (mainnet vs L2 testnet, mock-anvil vs real-Sepolia). A fixed 30s "stale" threshold
 * would either be too sensitive on a 60s poller or too forgiving on a 5s poller. Tying the
 * thresholds to N×interval keeps the classifier well-tuned regardless of operator config.
 *
 * Tuning rationale:
 *  - `stale` at 3× allows one missed tick + buffer for the next tick to start — anything
 *    longer than that and the scanner is genuinely stuck (not just slow).
 *  - `unhealthy` at 10× corresponds to ~5 minutes at a 30s poll cadence, the same ballpark
 *    operators expect for "page someone now." Bump if you find this too noisy.
 *
 * `LAG_BLOCKS_DEGRADED` is absolute (not relative) because block production is roughly fixed
 * on each chain — 100 blocks behind on Sepolia (~20 min) is the same operational concern
 * regardless of how often we're polling. Set conservatively; the scanner's chunked getLogs
 * means it WILL catch up, but until it does, anything depending on cursor freshness is lagging.
 */
const STALE_MULTIPLIER = 3;
const UNHEALTHY_MULTIPLIER = 10;
const LAG_BLOCKS_DEGRADED = 100;

export interface ChainHealthInput {
  lastError: { message: string; at: number } | null;
  lastScanAt: number;
  pollIntervalMs: number;
  lagBlocks: number;
  /** Current time in unix ms. Parameterised so tests can be deterministic. */
  now: number;
}

/**
 * Classify a chain's scanner state. Order of checks matters — unhealthy must win over stale must
 * win over degraded, because they're worsening severities and we report the highest one.
 *
 *  1. Never scanned successfully (`lastScanAt === 0`) → `unhealthy`. Cold start that's failed to
 *     produce a single good tick is operationally indistinguishable from a wedge.
 *  2. Time since last good tick > UNHEALTHY_MULTIPLIER × pollInterval → `unhealthy`.
 *  3. Time since last good tick > STALE_MULTIPLIER × pollInterval → `stale`.
 *  4. Most recent tick errored OR lagBlocks > threshold → `degraded`.
 *  5. Otherwise → `healthy`.
 */
export function classifyChainHealth(
  input: ChainHealthInput,
): ChainHealthStatus {
  const { lastError, lastScanAt, pollIntervalMs, lagBlocks, now } = input;

  if (lastScanAt === 0) return "unhealthy";

  const sinceLastScan = now - lastScanAt;
  if (sinceLastScan > UNHEALTHY_MULTIPLIER * pollIntervalMs) return "unhealthy";
  if (sinceLastScan > STALE_MULTIPLIER * pollIntervalMs) return "stale";

  if (lastError !== null) return "degraded";
  if (lagBlocks > LAG_BLOCKS_DEGRADED) return "degraded";

  return "healthy";
}

/**
 * Roll up multiple per-chain statuses into a single overall status. "Worst wins" — if any chain
 * is unhealthy the overall is unhealthy, etc. Empty input array returns `unhealthy` because a
 * relayer with zero chains has nothing useful to report; treating it as healthy would be
 * misleading. (In practice this can't happen — the relayer requires at least one chain to start —
 * but the classifier shouldn't silently mask the empty case.)
 */
export function rollupStatus(statuses: ChainHealthStatus[]): ChainHealthStatus {
  if (statuses.length === 0) return "unhealthy";
  // Severity order (worst → best). Find the worst.
  const severity: ChainHealthStatus[] = [
    "unhealthy",
    "stale",
    "degraded",
    "healthy",
  ];
  for (const level of severity) {
    if (statuses.includes(level)) return level;
  }
  // Unreachable — `statuses` is always a subset of severity values — but TS doesn't know that.
  return "healthy";
}
