Chunk P4 · Family F1 · Points 4 · Route Sonnet (pending the circom probe)
Depends on: P1

Repo: `armada-circuits`. Branch: `integrated` (work in a `task/P4` branch cut from `task/P1`, once P1 merges to
`integrated`).

## A fact to verify before anything else
The Phase-2 ceremony tooling — `scripts/ceremony/{init,contribute,finalize,verify,test-e2e,lib}.sh`,
`ceremony/manifest.json`, `ceremony/README.md`, `docs/CEREMONY.md` — exists on this repo's `fork/feat/public-
ceremony` branch (and `fork/ceremony/1x2-0001-iskay`), not on `integrated` (`80d8552`). `integrated` has no
`ceremony/` directory and no `scripts/ceremony/`. Confirm this with `git -C
~/code/git_puller/repos/armada-circuits log --oneline integrated..fork/feat/public-ceremony | head` before starting.
If it is false (the tooling has since merged to `integrated`), skip S1 and say so in the report.

Read, on `fork/feat/public-ceremony`: `scripts/ceremony/lib.sh` (the `SHAPES` array, the ptau pinning, `zkey_for`),
`scripts/ceremony/init.sh`, `scripts/ceremony/contribute.sh`, `scripts/ceremony/test-e2e.sh`, `docs/CEREMONY.md`,
`ceremony/manifest.json`. Read, on `integrated`: P1's three new entry points (`src/main/main_1x1_owned.circom`,
`main_1x2_owned.circom`, `main_1x3_owned.circom`) and `scripts/compile.sh`'s updated `SHAPES` array (P1's S3). Read
the armada-laconic lab book `labbook/2026-10-18-contract-owned-notes-and-zk-channel-apps.md` §3 decision 6 ("a new
Groth16 ceremony is triggered by any circuit change ... the contract-owned variant adds shapes to the Phase-2
ceremony that Armada already runs, so it adds no new ceremony kind") and ADR-0003 D3.4 ("Phase-2 is re-run only
when circuits change").

## Goal
The three owned shapes P1 added get a Phase-2 setup and a coordinator contribution in the same ceremony format the
plain shapes use, so `armada-env-verify` (armada-nitro's gate, `docs/ENVIRONMENT.md` §7) can later read a real
verifying key for them the same way it reads the plain shapes' keys, with no second ceremony kind (decision 6).

## Deliver
- **S1 · Bring the ceremony tooling onto this branch.** Cherry-pick or merge `fork/feat/public-ceremony`'s
  `scripts/ceremony/`, `ceremony/README.md`, `docs/CEREMONY.md` into `task/P4` (not `ceremony/manifest.json` — S2
  regenerates it fresh against `integrated`'s current shape set, which differs from `public-ceremony`'s). State
  which git operation was used (cherry-pick of which commits, or a file-by-file copy) and why, in the report.
- **S2 · Add the owned shapes to the shape list.** In the brought-in `scripts/ceremony/lib.sh`'s `DEFAULT_SHAPES`
  array, add `"1x1_owned" "1x2_owned" "1x3_owned"` (matching P1's S3 naming in `scripts/compile.sh`). Run
  `bash scripts/compile.sh` first (P1 dependency) so the `.r1cs`/`.wasm` artifacts exist for `init.sh` to checksum.
- **S3 · Initialize Phase 2 for the owned shapes only**, on a throwaway, non-production ceremony directory (this
  chunk does not touch the real `ceremony/` state, which still needs a public coordinator round — out of scope):
  `CEREMONY_SHAPES="1x1_owned 1x2_owned 1x3_owned" CEREMONY_DIR=./ceremony-owned-dryrun bash
  scripts/ceremony/init.sh`. This runs `snarkjs groth16 setup` against the real, pinned Hermez power-17 ptau
  (`lib.sh`'s `PTAU_URL`/`PTAU_SHA256`) — not `test-e2e.sh`'s throwaway power-15 ptau — because the owned shapes'
  verifying keys need to be usable by P4's acceptance check below, which compares against the same ptau the plain
  shapes used.
- **S4 · One coordinator contribution per owned shape**, so each has a non-trivial Phase-2 transcript (a
  `0000.zkey` alone is an unblinded setup, not a usable key): `CEREMONY_DIR=./ceremony-owned-dryrun bash
  scripts/ceremony/contribute.sh 1x1_owned dryrun-coordinator`, and the same for `1x2_owned` and `1x3_owned`.

Keep existing conventions: never commit a real private-entropy contribution to `integrated` — this chunk's
`ceremony-owned-dryrun` directory is for CI/local proof only and is deleted before the branch is pushed (name it in
`.gitignore` or delete it in the final commit, state which).

## Acceptance (paste output)
- `bash scripts/ceremony/lib.sh` sourced then `mget '.shapes | keys'` on `ceremony-owned-dryrun/manifest.json`,
  showing exactly `["1x1_owned", "1x2_owned", "1x3_owned"]`.
- For each owned shape, `npx snarkjs zkey verify build/<shape>/main_<shape>.r1cs build/ptau/
  powersOfTau28_hez_final_17.ptau ceremony-owned-dryrun/<shape>/0001.zkey` (the contributed zkey, S4), showing
  `[INFO] snarkJS: ZKey Ok!`. This is the same check ESTIMATION.md's check table cites for decision 6
  ("`snarkjs zkey verify` over the new shapes in CI").
- `node tests/diff-test.js transact-owned-1x2` (P1's S4 fixture), re-run against this chunk's
  `ceremony-owned-dryrun/1x2_owned/0001.zkey` instead of a bare `groth16 setup` key, showing the proof still
  verifies end to end with a real Phase-2-contributed key.

## Husband review
Not audit-critical (this chunk produces no production key; S3/S4's directory is explicitly a dry run). Check:
- the dry-run ceremony directory is not committed, and no step wrote into the real `ceremony/` directory;
- the ptau used (S3) is the real, checksummed Hermez power-17 file, not a throwaway, so the dry-run key's structure
  matches what a real contribution would produce.

## Out of scope
A real, public Phase-2 round for the owned shapes (a separate, operator-scheduled event per `docs/CEREMONY.md`,
once brought onto `integrated`); the plain shapes' ceremony (already run, per the lab book); the finalize/beacon
step (`finalize.sh`) — this chunk stops at one coordinator contribution per shape, proving the flow works, not
completing a production ceremony.

## Handoff
Moves `armada-laconic/notes/handoff-2026-10-20.md` §0.4, row "F1 pool", chunk P4.
