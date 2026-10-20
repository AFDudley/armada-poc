/**
 * ABOUTME: RPC call wrappers that prevent the relayer from hanging on stuck connections — every
 * provider call should pass through withTimeout so a wedged TCP socket can't pin the poll loop.
 * ABOUTME: WHY: ethers' default behaviour is to retry indefinitely; combined with the prior
 * silent-error swallow, a single dead provider could freeze the entire CCTP scanner. Loud
 * timeout > silent hang.
 */

/**
 * Typed error thrown by `withTimeout`. Callers can `instanceof RpcTimeoutError` to distinguish
 * timeout from the underlying call's own errors — useful for backoff decisions (timeout =
 * possibly recoverable, malformed response = probably config error).
 */
export class RpcTimeoutError extends Error {
  constructor(
    public readonly label: string,
    public readonly timeoutMs: number,
  ) {
    super(`RPC timeout after ${timeoutMs}ms: ${label}`);
    this.name = "RpcTimeoutError";
  }
}

/**
 * Race `promise` against a timeout. Resolves with the promise's value if it settles in time;
 * throws `RpcTimeoutError` otherwise. Crucially clears the internal timer once the promise
 * settles so we don't leak timers into long-running poll loops.
 *
 * The `label` argument flows into the error message — pass something descriptive
 * (`'getLogs hub blocks 100-600'`) so logs are actionable when timeouts surface.
 *
 * NOTE: this does not cancel the underlying promise (no AbortSignal here — most ethers v6
 * provider calls don't accept one). The provider keeps working; we just stop waiting. The
 * lingering work eventually errors or completes and is discarded. Acceptable cost for the
 * simplicity gain.
 */
export async function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
  label: string,
): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(new RpcTimeoutError(label, timeoutMs)),
      timeoutMs,
    );
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}
