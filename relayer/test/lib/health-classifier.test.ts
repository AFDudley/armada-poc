// ABOUTME: Tests for the pure /health classifier. Pins the severity ordering, the multipliers, and
// ABOUTME: the rollup "worst-wins" behaviour. WHY: the classifier is the only thing standing between
// ABOUTME: "scanner ticked 10 minutes ago" and an operator paging — a wrong threshold or a missing
// ABOUTME: severity rung silently masks real failures, which is exactly the silent-stall class that
// ABOUTME: Phase 1–2B closed for everything BUT operator visibility. These tests are the operator's
// ABOUTME: contract that "unhealthy" means unhealthy.

import { expect } from "chai";
import { classifyChainHealth, rollupStatus } from "../../lib/health-classifier";

const POLL = 30_000; // 30s — typical iris-relay cadence
const NOW = 1_700_000_000_000;

function input(
  overrides: Partial<Parameters<typeof classifyChainHealth>[0]> = {},
) {
  return {
    lastError: null,
    lastScanAt: NOW - 5_000,
    pollIntervalMs: POLL,
    lagBlocks: 0,
    now: NOW,
    ...overrides,
  };
}

describe("classifyChainHealth", function () {
  describe("healthy baseline", function () {
    it("returns 'healthy' when scan recent, no error, no lag", function () {
      expect(classifyChainHealth(input())).to.equal("healthy");
    });

    it("returns 'healthy' at the stale boundary (sinceLastScan = 3× pollInterval - 1ms)", function () {
      // WHY: pin the exact threshold. A regression that flipped the comparator to `>=`
      // would degrade a perfectly healthy scanner that's poll-bound right at the edge.
      expect(
        classifyChainHealth(input({ lastScanAt: NOW - (3 * POLL - 1) })),
      ).to.equal("healthy");
    });
  });

  describe("unhealthy — never scanned", function () {
    it("returns 'unhealthy' when lastScanAt === 0 (cold start that's never produced a good tick)", function () {
      // WHY: a relayer that boots, fails to scan, and gives no positive signal is operationally
      // worse than one that ticked once and stalled — at least the latter has a known last-good
      // state. The classifier MUST escalate this case past 'stale' to 'unhealthy' so monitoring
      // pages immediately rather than waiting for the stale-threshold window to elapse.
      expect(classifyChainHealth(input({ lastScanAt: 0 }))).to.equal(
        "unhealthy",
      );
    });

    it("returns 'unhealthy' even if lastError is null when never scanned", function () {
      // Defensive: the cold-start case should not be masked by error-presence checks downstream
      // of it. Order-of-checks regression guard.
      expect(
        classifyChainHealth(input({ lastScanAt: 0, lastError: null })),
      ).to.equal("unhealthy");
    });
  });

  describe("unhealthy — long-stale", function () {
    it("returns 'unhealthy' when sinceLastScan > 10× pollInterval", function () {
      expect(
        classifyChainHealth(input({ lastScanAt: NOW - (10 * POLL + 1) })),
      ).to.equal("unhealthy");
    });

    it("unhealthy wins over 'degraded' from lastError when both apply", function () {
      // WHY: severity ordering invariant. A long-dead scanner that ALSO has an error in its
      // last attempt is unhealthy, not degraded — operators need the strongest signal.
      expect(
        classifyChainHealth(
          input({
            lastScanAt: NOW - (10 * POLL + 1),
            lastError: { message: "boom", at: NOW - (10 * POLL + 1) },
          }),
        ),
      ).to.equal("unhealthy");
    });
  });

  describe("stale", function () {
    it("returns 'stale' at sinceLastScan = 3× pollInterval + 1ms", function () {
      expect(
        classifyChainHealth(input({ lastScanAt: NOW - (3 * POLL + 1) })),
      ).to.equal("stale");
    });

    it("returns 'stale' anywhere in (3×, 10×] pollInterval window", function () {
      expect(
        classifyChainHealth(input({ lastScanAt: NOW - 5 * POLL })),
      ).to.equal("stale");
    });

    it("stale wins over degraded from lastError", function () {
      // Same severity-ordering invariant as the unhealthy case — stale > degraded.
      expect(
        classifyChainHealth(
          input({
            lastScanAt: NOW - 5 * POLL,
            lastError: { message: "boom", at: NOW - 5 * POLL },
          }),
        ),
      ).to.equal("stale");
    });
  });

  describe("degraded", function () {
    it("returns 'degraded' when lastError is set and scan recent", function () {
      // WHY: a recent tick that failed is the canonical degraded case — scanner alive,
      // last attempt errored, will retry. Operator-visible but not paged.
      expect(
        classifyChainHealth(
          input({ lastError: { message: "RPC 500", at: NOW - 1_000 } }),
        ),
      ).to.equal("degraded");
    });

    it("returns 'degraded' when lagBlocks > 100", function () {
      // WHY: cursor is falling behind chain head — the bisecting getLogs WILL catch up,
      // but until then anything depending on cursor freshness (UIs polling for events) is
      // showing stale data. Operators want to know.
      expect(classifyChainHealth(input({ lagBlocks: 101 }))).to.equal(
        "degraded",
      );
    });

    it("does NOT flag degraded at lagBlocks = 100 (boundary)", function () {
      expect(classifyChainHealth(input({ lagBlocks: 100 }))).to.equal(
        "healthy",
      );
    });
  });
});

describe("rollupStatus", function () {
  it("returns 'healthy' when all chains are healthy", function () {
    expect(rollupStatus(["healthy", "healthy", "healthy"])).to.equal("healthy");
  });

  it("returns 'unhealthy' on an empty list (no chains == nothing useful to report)", function () {
    // WHY: silently returning 'healthy' for an empty input would mask configuration bugs
    // (e.g. CHAINS env var typo wiping the chain list). Loud 'unhealthy' surfaces it.
    expect(rollupStatus([])).to.equal("unhealthy");
  });

  it("worst-wins: 'unhealthy' beats 'degraded' beats 'healthy'", function () {
    expect(rollupStatus(["healthy", "degraded", "unhealthy"])).to.equal(
      "unhealthy",
    );
    expect(rollupStatus(["healthy", "degraded"])).to.equal("degraded");
    expect(rollupStatus(["healthy", "stale"])).to.equal("stale");
  });

  it("severity ordering: unhealthy > stale > degraded > healthy", function () {
    // Exhaustive: every adjacent-severity pair to lock the ordering invariant.
    expect(rollupStatus(["unhealthy", "stale"])).to.equal("unhealthy");
    expect(rollupStatus(["stale", "degraded"])).to.equal("stale");
    expect(rollupStatus(["degraded", "healthy"])).to.equal("degraded");
  });
});
