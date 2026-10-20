
# Chunk C6 · Family F3 · Points 6 · Route 5090

Depends on: G3.
Handoff row moved: `notes/handoff-2026-10-20.md` §0.4, row "F3 governance", chunk C6.

**Repo note:** this brief is written in `armada-poc/docs/tasks/` per the brief writer's
instruction (`armada-laconic/.scratch/rewrite-evidence/BRIEF-WRITER.md` "Where to write"),
but the worker opens a branch in a different repo: `armada-sdk`, branch `integrated`
(`8d621aa`, pushed to the `fork` remote — `armada-laconic/notes/handoff-2026-10-20.md`
§0.3). The lead should confirm this split before dispatch; see the writer's report.

Read first:
- `armada-sdk/src/tx/plan.ts` `planSpend` (line 392) and `planTransfer` (line 264).
- `armada-sdk/src/tx/prove.ts` `prove` (line 81) and `proveAll` (line 94).
- `armada-sdk/src/tx/serialize.ts` `buildTransactCalldata` (line 102).
- `armada-sdk/src/tx/witness.ts` `buildWitness` (line 186).
- `contracts/governance/ShieldedRagequit.sol` (G3's output): `ragequit`'s parameters, and
  the resulting contract-owned note's `npk` derivation
  (`armada-laconic/.scratch/rewrite-evidence/P2-CONTRACT.md` item 6).
- `armada-sdk/src/wallet/local-signer.ts` and `armada-sdk/src/wallet/derive.ts`: the
  signer shape a wallet-facing flow builds on.

## Goal

A wallet holding ARM can call `ragequit`, then recognize and spend the resulting
contract-owned payout note on-device, with no server-side proving step.

## Deliver

- **S1 · `planRagequit`.** A new function in `armada-sdk/src/tx/`, alongside `plan.ts`'s
  `planTransfer`/`planSpend`, that takes the holder's ARM balance, the assets the Safe
  currently holds (read from chain, the same way `planSpend`'s callers already read spend
  candidates), and returns the calldata for `ShieldedRagequit.ragequit` plus the expected
  resulting `CommitmentPreimage` for each asset (computed with the same bound G3 S4
  enforces on-chain, so the wallet can show the user the expected payout before they sign).
- **S2 · Note recognition.** After the on-chain `ragequit` call, the wallet must recognize
  the new contract-owned note without a ciphertext (P2-CONTRACT item 3: "the caller
  supplies the preimage in the clear instead of a ciphertext"). Add a scan step that reads
  `preimageOf` for the commitment `planRagequit` predicted in S1, confirms it matches, and
  inserts it into the wallet's local note store the same way `armada-sdk/src/sync/` ingests
  a recognized note from a ciphertext today (read `armada-sdk/src/sync/` before writing
  this step; match its existing note-insertion shape, do not invent a second store).
- **S3 · Spend the payout note.** Once S2's note is in the local store, it must spend like
  any other note: `planSpend` (already handles arbitrary stored notes) plus `prove`
  (`prove.ts:81`) plus `buildTransactCalldata` (`serialize.ts:102`) must succeed against
  it with no special-casing beyond S1/S2's insertion step. Add an integration test that
  shields a note, ragequits (against a local or fixturenet `ShieldedRagequit` deployment),
  and spends the resulting note, asserting the on-chain `transact` call verifies.

## Conventions to keep

Match `plan.ts`'s existing function signature shape (`PlanTransferParams`-style input
object, a `Plan`/`PlanSelection` return type). Keep proof building device-local: do not add
a network call to any proving service (per the chunk title, "on-device proof").

## Acceptance (paste output)

The SDK's existing test runner (confirm the exact command from `armada-sdk/package.json`'s
`scripts.test`) for a new test file, `src/tx/ragequit.test.ts`, with these cases, each
failing on `8d621aa` (no ragequit support exists in the SDK today) and passing after:
1. `planRagequit` computes the same bound G3's contract enforces, for a mocked Safe
   balance and ARM supply;
2. the note-recognition step (S2) inserts a contract-owned note from `preimageOf` with no
   ciphertext decrypt attempted;
3. the end-to-end integration test (S3) shields, ragequits, and spends, against a local
   `ShieldedRagequit` deployment, with the final `transact` call's proof verifying.

## Husband review

Confirm S2 never attempts to decrypt a ciphertext for a contract-owned note (there is
none to decrypt — a wrong assumption here silently drops every ragequit payout from the
wallet's note store). Confirm S1's predicted payout matches G3's on-chain bound exactly,
not an approximation.

## Out of scope

A UI component for the ragequit flow (this chunk is the SDK function and its tests, not a
client application screen). The Baal vote/proposal flow (C-family chunks outside this
brief's scope; G7a covers the governance-contract side of voting).
