// ABOUTME: Tests for withTimeout — verifies happy path, timeout firing, original-error pass-through, and timer cleanup.
// ABOUTME: WHY: the silent-hang failure mode is the inverse of the silent-error one — both lose user money. Without explicit timer-cleanup verification, a leak in the loser branch of Promise.race would eventually OOM a long-running relayer.

import { expect } from "chai";
import { RpcTimeoutError, withTimeout } from "../../lib/rpc-utils";

describe("withTimeout", function () {
  it("resolves with the promise value when it settles inside the timeout", async function () {
    const value = await withTimeout(Promise.resolve("ok"), 1000, "test");
    expect(value).to.equal("ok");
  });

  it("rejects with RpcTimeoutError when the timeout fires first", async function () {
    // WHY: the canonical "wedged RPC connection" case — provider never returns. Without the
    // timeout, the poll loop pins forever waiting on a dead socket.
    const slow = new Promise<string>((resolve) =>
      setTimeout(() => resolve("late"), 100),
    );
    try {
      await withTimeout(slow, 10, "test-slow-rpc");
      expect.fail("should have thrown");
    } catch (err) {
      expect(err).to.be.instanceOf(RpcTimeoutError);
      expect((err as RpcTimeoutError).label).to.equal("test-slow-rpc");
      expect((err as RpcTimeoutError).timeoutMs).to.equal(10);
    }
  });

  it("propagates the original error when the promise rejects in time", async function () {
    // WHY: the timeout must not mask real errors. If the provider rejects with a meaningful
    // "block range too large" error and we wrap THAT as RpcTimeoutError, we lose the diagnostic
    // signal that motivates a backoff strategy.
    const original = new Error("real RPC error: block range too large");
    try {
      await withTimeout(Promise.reject(original), 1000, "test");
      expect.fail("should have thrown");
    } catch (err) {
      expect(err).to.equal(original);
      expect(err).to.not.be.instanceOf(RpcTimeoutError);
    }
  });

  it("clears the internal timer when the promise resolves first (no leak in long-running loops)", async function () {
    // WHY: this helper is called every poll tick (every few seconds). A leaked setTimeout per
    // tick would accumulate thousands of timers per hour. We can't easily observe handle
    // counts in user-land Node, so this test pins the cleanup invariant via active handle
    // counting against the process — the count after N withTimeout calls should not grow.
    const initial =
      (
        process as NodeJS.Process & { _getActiveHandles?: () => unknown[] }
      )._getActiveHandles?.()?.length ?? 0;
    for (let i = 0; i < 50; i++) {
      await withTimeout(Promise.resolve(i), 5000, "loop");
    }
    const after =
      (
        process as NodeJS.Process & { _getActiveHandles?: () => unknown[] }
      )._getActiveHandles?.()?.length ?? 0;
    // Allow small slack for mocha's own timers; the key is the count doesn't grow proportionally
    // to iterations (50). If the cleanup is broken we'd see ~50 lingering Timeouts.
    expect(after - initial).to.be.lessThan(10);
  });

  it("RpcTimeoutError preserves the label for log-friendly messages", async function () {
    // WHY: the label appears in operator logs. A bare "RPC timeout" tells you nothing — the
    // label should identify which call timed out (which chain, which method).
    try {
      await withTimeout(new Promise(() => {}), 5, "getLogs hub blocks 100-600");
      expect.fail("should have thrown");
    } catch (err) {
      expect((err as Error).message).to.include("getLogs hub blocks 100-600");
      expect((err as Error).message).to.include("5ms");
    }
  });
});
