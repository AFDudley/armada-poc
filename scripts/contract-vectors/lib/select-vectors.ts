// ABOUTME: Picks which golden vectors replay-check replays, from positional args and the
// ABOUTME: REPLAY_ALL / REPLAY_IDS / REPLAY_GENESIS env vars (Hardhat does not forward `--` args).

export interface VectorSelection {
  ids: string[];
  genesis: boolean;
}

/**
 * Resolve the replay selection.
 *
 * - `REPLAY_ALL=1` (or `--all`, or nothing selected) replays every vector in manifest order.
 * - `REPLAY_IDS=a,b,c` (or positional ids) replays only those vectors, in the given order.
 * - `REPLAY_GENESIS=1` (or `--genesis`) also performs the capture-time genesis setup.
 *
 * Throws if any selected id is not in the manifest, so a typo cannot pass as a clean run.
 */
export function selectVectors(
  argv: string[],
  env: Record<string, string | undefined>,
  manifestIds: string[],
): VectorSelection {
  const args = argv.filter((a) => a !== "--");
  const all = args.includes("--all") || env.REPLAY_ALL === "1";
  const genesis = args.includes("--genesis") || env.REPLAY_GENESIS === "1";

  const requested = [
    ...args.filter((a) => !a.startsWith("--")),
    ...(env.REPLAY_IDS ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  ];

  if (all || requested.length === 0) {
    return { ids: manifestIds, genesis };
  }

  const known = new Set(manifestIds);
  const unknown = requested.filter((id) => !known.has(id));
  if (unknown.length > 0) {
    throw new Error(
      `replay-check: unknown vector id(s): ${unknown.join(", ")}`,
    );
  }
  return { ids: requested, genesis };
}
