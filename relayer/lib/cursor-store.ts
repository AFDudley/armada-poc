/**
 * ABOUTME: Per-chain scan cursor persistence — atomic JSON write so a restart resumes from the
 * last successfully-scanned block instead of jumping to the chain head and silently dropping any
 * MessageSent events in the gap.
 * ABOUTME: Thin wrapper over JsonStateStore — the atomic-write + schema-version machinery lives
 * there. This file just defines the cursor's shape + validation.
 */

import { JsonStateStore } from "./json-state-store";

/** Schema version. Bump and add a migration in the JsonStateStore call below when the shape changes. */
const CURSOR_SCHEMA_VERSION = 1 as const;

export interface CursorData {
  /** Block number we have FULLY scanned and processed (inclusive). Next poll starts at +1. */
  lastProcessedBlock: number;
  /** Unix ms when this cursor was last written. For health endpoint + staleness alerts. */
  updatedAt: number;
  /** Schema version — for future migrations. */
  version: typeof CURSOR_SCHEMA_VERSION;
}

/**
 * Filesystem-backed per-chain cursor store. Delegates to `JsonStateStore` for atomic writes +
 * schema versioning; supplies cursor-specific validation. See JsonStateStore for the on-disk
 * layout, atomic-rename behaviour, and ENOENT-as-null read contract.
 */
export class CursorStore {
  private readonly inner: JsonStateStore<CursorData>;

  constructor(baseDir: string) {
    this.inner = new JsonStateStore<CursorData>({
      baseDir,
      filenamePrefix: "cursor",
      expectedVersion: CURSOR_SCHEMA_VERSION,
      validate,
    });
  }

  async read(chainName: string): Promise<CursorData | null> {
    return this.inner.read(chainName);
  }

  async write(
    chainName: string,
    data: Omit<CursorData, "version">,
  ): Promise<void> {
    // Inner store stamps version automatically — caller supplies just the payload fields.
    return this.inner.write(chainName, {
      ...data,
      version: CURSOR_SCHEMA_VERSION,
    });
  }
}

// JsonStateStore's validator signature uses `key`; we name it `chainName` here because the
// cursor-store's only consumers are per-chain — the semantic name reads better in error
// messages. Same position, same type — just contextual naming.
function validate(
  parsed: unknown,
  chainName: string,
  path: string,
): CursorData {
  const candidate = parsed as {
    lastProcessedBlock?: unknown;
    updatedAt?: unknown;
  };
  if (typeof candidate.lastProcessedBlock !== "number") {
    throw new Error(
      `cursor-store: malformed cursor file for chain '${chainName}' at ${path}. Missing or non-numeric lastProcessedBlock. Delete it to reset to lookback boot.`,
    );
  }
  if (typeof candidate.updatedAt !== "number") {
    throw new Error(
      `cursor-store: malformed cursor file for chain '${chainName}' at ${path}. Missing or non-numeric updatedAt. Delete it to reset.`,
    );
  }
  // Range checks. The typeof guard above accepts -Infinity, NaN, Infinity, fractional numbers —
  // none of which are valid block numbers or timestamps. Catch them here so they don't reach
  // the scanner's `Number(...)` casts and turn into silent NaN propagations downstream.
  if (
    !Number.isInteger(candidate.lastProcessedBlock) ||
    candidate.lastProcessedBlock < 0
  ) {
    throw new Error(
      `cursor-store: invalid lastProcessedBlock (${candidate.lastProcessedBlock}) for chain '${chainName}' at ${path}. Expected a non-negative integer. Delete to reset.`,
    );
  }
  if (!Number.isInteger(candidate.updatedAt) || candidate.updatedAt < 0) {
    throw new Error(
      `cursor-store: invalid updatedAt (${candidate.updatedAt}) for chain '${chainName}' at ${path}. Expected a non-negative integer (Unix ms). Delete to reset.`,
    );
  }
  return {
    lastProcessedBlock: candidate.lastProcessedBlock,
    updatedAt: candidate.updatedAt,
    version: CURSOR_SCHEMA_VERSION,
  };
}
