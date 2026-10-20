// ABOUTME: Tests for the eth_getLogs bisecting patch. Ported from apps/armada-interface (vitest → mocha+chai); behaviour kept lockstep so a bug in one surfaces in the other.
// ABOUTME: WHY: bisection is the difference between "works on every RPC" and "silently fails on Alchemy free tier (10-block cap)." Every range-error-detection regex + recursive-split path needs explicit coverage or a future provider tweak will reintroduce the silent-fail mode.

import { expect } from "chai";
import { JsonRpcProvider } from "ethers";
import {
  installBisectingGetLogs,
  _isBisectingGetLogsPatched,
  _uninstallBisectingGetLogs,
  _bisectEthGetLogs,
  _isBlockRangeError,
} from "../../lib/rpc-bisecting";

beforeEach(() => {
  _uninstallBisectingGetLogs();
});

afterEach(() => {
  _uninstallBisectingGetLogs();
});

describe("isBlockRangeError", function () {
  it('matches the Alchemy free-tier "10 block range" message', function () {
    // WHY: this is the concrete cap that motivated the bisector — Alchemy free returns 10
    // blocks. The relayer must not need to know this upfront; the regex catches the error
    // string and lets the recursion adapt.
    const err = new Error(
      "Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range.",
    );
    expect(_isBlockRangeError(err)).to.equal(true);
  });

  it('matches Infura "more than X results" wording', function () {
    const err = new Error("query returned more than 10000 results");
    expect(_isBlockRangeError(err)).to.equal(true);
  });

  it('matches QuickNode "limited to a X block range" wording', function () {
    const err = new Error("eth_getLogs is limited to a 1000 block range");
    expect(_isBlockRangeError(err)).to.equal(true);
  });

  it("digs into ethers SERVER_ERROR shape (info.responseBody)", function () {
    // WHY: ethers wraps server-side errors in { code, info: { responseBody } }. Without the
    // nested-dig in isBlockRangeError, the outer message "server response 400" wouldn't match
    // and we'd treat a range error as a generic failure — silent stall reintroduced.
    const err = {
      code: "SERVER_ERROR",
      message: "server response 400",
      info: {
        responseBody:
          '{"error":{"message":"Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range"}}',
      },
    };
    expect(_isBlockRangeError(err)).to.equal(true);
  });

  it("does NOT match unrelated errors (timeouts, reverts)", function () {
    // WHY: bisecting on the wrong error class would double traffic and likely re-fail. The
    // narrow regex keeps us conservative — uncaught patterns surface as scan errors (loud,
    // operator-actionable) rather than infinite retry loops.
    expect(
      _isBlockRangeError(new Error("CALL_EXCEPTION: execution reverted")),
    ).to.equal(false);
    expect(_isBlockRangeError(new Error("timeout"))).to.equal(false);
    expect(_isBlockRangeError(null)).to.equal(false);
    expect(_isBlockRangeError(undefined)).to.equal(false);
  });
});

describe("bisectEthGetLogs", function () {
  it("passes through a successful call without splitting", async function () {
    // WHY: happy-path baseline. Bisection is reactive; on success the helper must be a
    // transparent passthrough or we'd waste bandwidth halving working ranges.
    const expected = [{ blockNumber: 100 }];
    let calls = 0;
    const send = async () => {
      calls++;
      return expected;
    };
    const result = await _bisectEthGetLogs(
      send,
      { fromBlock: "0x0", toBlock: "0x100" },
      0,
    );
    expect(result).to.deep.equal(expected);
    expect(calls).to.equal(1);
  });

  it("bisects once on a range-too-large error and merges the halves", async function () {
    // WHY: the canonical split case — confirm recursion left/right, hex math, and result merge.
    // The exact half boundary (0x32, 0x33) pins the cursor arithmetic so a refactor that shifts
    // the boundary by 1 immediately fails.
    const err = new Error("eth_getLogs is limited to a 10 block range");
    const calls: Array<[string, unknown[]]> = [];
    let attempt = 0;
    const send = async (method: string, params: unknown[]) => {
      calls.push([method, params]);
      attempt++;
      if (attempt === 1) throw err;
      if (attempt === 2) return [{ blockNumber: 10 }];
      return [{ blockNumber: 80 }];
    };
    const result = await _bisectEthGetLogs(
      send,
      { fromBlock: "0x0", toBlock: "0x64" },
      0,
    );
    expect(result).to.deep.equal([{ blockNumber: 10 }, { blockNumber: 80 }]);
    expect(calls.length).to.equal(3);
    expect(calls[1]?.[1]).to.deep.equal([
      { fromBlock: "0x0", toBlock: "0x32" },
    ]);
    expect(calls[2]?.[1]).to.deep.equal([
      { fromBlock: "0x33", toBlock: "0x64" },
    ]);
  });

  it("recurses multiple levels when the first bisection is still too large", async function () {
    // WHY: a single bisection isn't always enough — a Sepolia cold start scan window can be
    // 10k+ blocks while Alchemy free caps at 10. The recursion must keep halving until the
    // RPC accepts. Five-call sequence pins the recursion tree (fail/fail/ok/ok/ok).
    const err = new Error("block range too wide");
    let attempt = 0;
    const send = async () => {
      attempt++;
      if (attempt === 1) throw err; // [0, 100] full
      if (attempt === 2) throw err; // [0, 50] left
      if (attempt === 3) return [1]; // [0, 25] left-left
      if (attempt === 4) return [2]; // [26, 50] left-right
      return [3]; // [51, 100] right
    };
    const result = await _bisectEthGetLogs(
      send,
      { fromBlock: "0x0", toBlock: "0x64" },
      0,
    );
    expect(result).to.deep.equal([1, 2, 3]);
    expect(attempt).to.equal(5);
  });

  it("propagates non-range errors without splitting", async function () {
    // WHY: don't bisect on reverts, network errors, etc. Conservative regex + this guard means
    // an unrelated error surfaces immediately rather than amplifying load via retries.
    const err = new Error("CALL_EXCEPTION: execution reverted");
    let attempt = 0;
    const send = async () => {
      attempt++;
      throw err;
    };
    try {
      await _bisectEthGetLogs(send, { fromBlock: "0x0", toBlock: "0x100" }, 0);
      expect.fail("should have thrown");
    } catch (e) {
      expect((e as Error).message).to.include("execution reverted");
    }
    expect(attempt).to.equal(1);
  });

  it("propagates the range error when the range is already a single block", async function () {
    // WHY: terminal recursion case. A 1-block range that still trips the RPC's cap means
    // something deeper is wrong (RPC misconfigured, contract spamming events). Re-throw so the
    // scanner's lastError surfaces it.
    const err = new Error("block range too wide");
    let attempt = 0;
    const send = async () => {
      attempt++;
      throw err;
    };
    try {
      await _bisectEthGetLogs(send, { fromBlock: "0x10", toBlock: "0x10" }, 0);
      expect.fail("should have thrown");
    } catch (e) {
      expect((e as Error).message).to.match(/block range too wide/);
    }
    expect(attempt).to.equal(1);
  });

  it("does not infinite-recurse on a pathological huge range", async function () {
    // WHY: defensive — the recursion must terminate even when every call fails. The single-block
    // floor catches typical cases; this pins the call-count ceiling so a regression that breaks
    // the floor surfaces as a test timeout AND an explicit assertion failure.
    const err = new Error("block range too wide");
    let attempt = 0;
    const send = async () => {
      attempt++;
      throw err;
    };
    try {
      await _bisectEthGetLogs(
        send,
        { fromBlock: "0x0", toBlock: "0xFFFFFF" },
        0,
      );
      expect.fail("should have thrown");
    } catch (e) {
      expect((e as Error).message).to.match(/block range too wide/);
    }
    expect(attempt).to.be.lessThan(400);
  });

  it("wraps the original error with range + depth context when MAX_BISECT_DEPTH fires", async function () {
    // WHY: the depth cap is the last-resort safety against pathological inputs. When it fires,
    // the wrapping error must preserve enough context (depth + range + upstream message) for
    // an operator to diagnose without raising the cap blindly.
    const err = new Error("block range too wide");
    const send = async () => {
      throw err;
    };
    try {
      await _bisectEthGetLogs(
        send,
        { fromBlock: "0x0", toBlock: "0xFFFFFFFF" },
        24,
      );
      expect.fail("should have thrown");
    } catch (e) {
      expect((e as Error).message).to.match(/bisection exceeded max depth/);
      expect((e as Error).message).to.match(/block range too wide/);
    }
  });

  it("preserves filter fields other than fromBlock/toBlock", async function () {
    // WHY: a filter with `address` + `topics` MUST flow into every recursive sub-call. Without
    // it, the bisected halves would scan the wrong contract / wrong event topic — returning
    // wrong logs OR no logs (silent miss).
    const err = new Error("block range too wide");
    const filter = {
      fromBlock: "0x0",
      toBlock: "0x100",
      address: "0xabc",
      topics: ["0xtopic1", null],
    };
    const calls: unknown[][] = [];
    let attempt = 0;
    const send = async (_m: string, p: unknown[]) => {
      calls.push(p);
      attempt++;
      if (attempt === 1) throw err;
      return [];
    };
    await _bisectEthGetLogs(send, filter, 0);
    const leftCall = (calls[1] as Record<string, unknown>[])[0];
    expect(leftCall?.address).to.equal("0xabc");
    expect(leftCall?.topics).to.deep.equal(["0xtopic1", null]);
  });
});

describe("installBisectingGetLogs", function () {
  it("is idempotent", function () {
    expect(_isBisectingGetLogsPatched()).to.equal(false);
    installBisectingGetLogs();
    expect(_isBisectingGetLogsPatched()).to.equal(true);
    installBisectingGetLogs();
    installBisectingGetLogs();
    expect(_isBisectingGetLogsPatched()).to.equal(true);
  });

  it("intercepts eth_getLogs but passes through other methods", async function () {
    // WHY: confirm the prototype patch only branches on the targeted RPC method. A broken patch
    // that intercepted all calls would break eth_blockNumber, eth_getBlockByNumber, etc. —
    // every other relayer operation.
    installBisectingGetLogs();
    const provider = new JsonRpcProvider("http://localhost:0"); // never connects; we override send

    let recordedMethod = "";
    let recordedParams: unknown[] = [];
    // Override the instance's send to spy on what the patched send calls into.
    provider.send = async function (m: string, p: unknown[]) {
      recordedMethod = m;
      recordedParams = p;
      if (m === "eth_getLogs") return [];
      return null;
    };

    await provider.send("eth_blockNumber", []);
    expect(recordedMethod).to.equal("eth_blockNumber");

    await provider.send("eth_getLogs", [{ fromBlock: "0x0", toBlock: "0x10" }]);
    expect(recordedMethod).to.equal("eth_getLogs");
    expect(recordedParams).to.deep.equal([
      { fromBlock: "0x0", toBlock: "0x10" },
    ]);
  });
});
