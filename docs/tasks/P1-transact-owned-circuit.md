Chunk P1 · Family F1 · Points 9 · Route Sonnet (pending the circom probe)
Depends on: —

Repo: `armada-circuits`. Branch: `integrated` (work in a `task/P1` branch cut from `integrated`, commit
`80d8552`).

Read `src/operations/Transact.circom` (the whole file; the EdDSA hook is at line 158), `src/main/main_1x1.circom`,
`src/main/main_1x2.circom`, `src/main/main_1x3.circom` (the entry-point pattern), `scripts/compile.sh` (the `SHAPES`
list), `tests/diff-test.js` and `tests/fixtures/generated/transfer-1x2.json` (the differential-test pattern),
`docs/DIFFERENTIAL_TEST_VECTORS.md`, and the armada-laconic lab book
`labbook/2026-10-18-contract-owned-notes-and-zk-channel-apps.md` §3 decisions 1 to 4 and 6, and §4's first table
row.

This chunk also settles two open points in `.scratch/rewrite-evidence/P2-CONTRACT.md` (armada-laconic), which chunk
P2 (armada-poc) and F4's chunk N1a (armada-nitro) depend on: the `transactOwned` input/output arity, and the
owner-derived `npk` formula. State the settled values below as fact; P2's brief cites this file.

## Goal
A contract (for example a Safe or the armada-nitro adjudicator) owns a shielded note through a new circuit variant
that derives the note's `npk` from a public Ethereum address instead of a secret spending key, and skips the EdDSA
check, because a contract holds no EdDSA key (lab book decision 1, decision 2: "the pool authorizes a contract-owned
spend by `msg.sender == owner`, ... because the contract holds no spending key").

## Settled: owner-derived `npk` formula
`npk = Poseidon(ownerField, random)`, where `ownerField = uint256(uint160(owner))` (the owner address,
zero-extended into the field — the same encoding `Transact.circom`'s companion Solidity already uses for a token
address, `TransactModule.sol`'s `_getTokenID`). This replaces `Transact.circom`'s existing
`npk = Poseidon(masterPublicKey, random)` (`mpkHash` at lines 60–65, consumed at lines 74–77) for the owned
variant: `mpkHash` (built from `publicKey` and `nullifyingKey`) is not computed, and `ownerField` is a new public
input in its place.

## Settled: `transactOwned` arity
One input note, one to three output commitments: the same `(N, M)` shapes as the existing `1x1`, `1x2` and `1x3`
circuits. A contract-owned spend always replaces exactly one commitment (the contract's current note) and mints at
most: one replacement contract-owned note, plus up to two payout notes in the same call. A payout needing more than
two destinations in one call is out of scope; it splits across multiple `transactOwned` calls (a P2/N2b decision,
not this chunk's).

## Deliver
- **S1 · `TransactOwned(N, M)` template**, in a new file `src/operations/TransactOwned.circom`. Copy
  `Transact(N, M)`'s Merkle-membership, nullifier-derivation and value-conservation constraints unchanged (lines
  79–135 of `Transact.circom`). Replace the signature and `npk` logic:
  - New public input `owner` (the contract's address, field-encoded as above).
  - Drop `publicKey`, `signature` and the `mpkHash`/`eddsa` components entirely (no `EdDSAPoseidonVerifier`
    instantiation at all — not a toggled `enabled <== 0`, because that still requires a valid-looking signature
    witness; this variant has none).
  - `npkHashes[i]` (for every input and output) becomes `Poseidon(2)` over `[owner, random]` instead of
    `[mpkHash.out, random]`.
  - `nullifierHashes[i]` keeps `Poseidon(nullifyingKey, leafIndex)`, but `nullifyingKey` is now a public input
    derived the same way as `npk`'s first argument: `nullifyingKey = owner` (one fewer private witness field; the
    nullifier stays public either way, lab book decision 4: "a public nullifier is not a show-stopper").
  - Public input list: `merkleRoot, boundParamsHash, nullifiers[N], commitmentsOut[M], owner`.
- **S2 · Entry points.** Add `src/main/main_1x1_owned.circom`, `src/main/main_1x2_owned.circom`,
  `src/main/main_1x3_owned.circom`, matching `main_1x1.circom`'s pattern but instantiating `TransactOwned(1, M)`
  with `owner` added to the `public [...]` list.
- **S3 · `scripts/compile.sh`.** Add the three owned shapes to the `SHAPES` array (`"1,1_owned" "1,2_owned"
  "1,3_owned"` or an equivalent naming the script's `shape_name`/`main_file` construction accepts — adapt the
  script's string handling if the comma-split breaks on the suffix; note the exact change made).
- **S4 · Differential tests.** Write `tests/fixtures/generated/transact-owned-1x2.json` by hand (no capture script
  exists yet for the owned variant; derive its fields from `transfer-1x2.json`'s shape, substituting the EdDSA/
  `publicKey` fields for a plain `owner` address and recomputing `npk`/commitments/nullifiers with Poseidon per S1's
  formula — use `circomlibjs`'s `poseidon`, already a devDependency per `tests/diff-test.js`'s `snarkjs` import).
  Extend `tests/diff-test.js` (or add `tests/diff-test-owned.js`, state which) to build the owned circuit's witness
  input (no `publicKey`/`signature`, add `owner`) and run it against `main_1x2_owned`'s compiled artifacts.

Keep existing conventions: signal names match the existing `FormattedCircuitInputsRailgun`-style naming where the
field still exists; every new public input is listed in the main file's `public [...]` array, not left implicit.

## Acceptance (paste output)
- `bash scripts/compile.sh` output, showing `1x1_owned`, `1x2_owned` and `1x3_owned` compiled with no errors
  (compare against the same command's output on the commit before this task, where those three lines do not
  appear).
- `node tests/diff-test.js transact-owned-1x2` (or the S4 script's equivalent invocation), showing the proof
  verifies and public signals match the hand-built fixture. This test fails on the commit before this task (the
  fixture and the owned circuit do not exist) and passes after.
- `npm run lint:circom` clean.

## Husband review
Audit-critical. Check:
- the owned variant's `npk`/`nullifyingKey` derivation cannot be confused with a normal user note's derivation
  (different Poseidon arity or domain-separated some other way), so a contract-owned note is never mistaken for a
  spendable user note or vice versa;
- dropping the EdDSA component entirely (not just disabling it) does not leave any dangling public input that lets
  a prover supply an unconstrained value;
- the value-conservation and Merkle-membership constraints (S1, copied unchanged) are byte-for-byte the same logic
  as `Transact.circom`'s.

## Out of scope
The Solidity side (`transactOwned`, `preimageOf`, fee-tagged outputs — P2); the Phase-2 ceremony run for these
shapes (P4); any shape beyond `1x1_owned`/`1x2_owned`/`1x3_owned`.

## Handoff
Moves `armada-laconic/notes/handoff-2026-10-20.md` §0.4, row "F1 pool", chunk P1.
