Chunk P2a · Family F1 · Points 6 · Route 5090
Depends on: P1

Repo: `armada-poc`. Branch: `integrated` (work in a `task/P2a` branch cut from `integrated`, commit `60a2f05`).

Read `contracts/privacy-pool/modules/TransactModule.sol` (the whole file), `contracts/privacy-pool/modules/
VerifierModule.sol`, `contracts/privacy-pool/storage/PrivacyPoolStorage.sol`, `contracts/privacy-pool/types/
PoolTypes.sol`, `contracts/privacy-pool/interfaces/IPrivacyPool.sol`, `contracts/privacy-pool/interfaces/
ITransactModule.sol`, `contracts/privacy-pool/PrivacyPool.sol` (the delegatecall router pattern, `onlyDelegatecall`
modifier use), and the armada-laconic lab book `labbook/2026-10-18-contract-owned-notes-and-zk-channel-apps.md` §3
decisions 1, 2, 3, 4, 6, and P1's brief (`docs/tasks/P1-transact-owned-circuit.md`, "Settled" sections — this chunk
wires the circuit P1 built).

## This chunk's contract to F4
Chunk N1a and N2a in `armada-nitro` (`briefs/F4`, commit `ab694ba`) assume this interface. Meet it exactly, or stop
and report the difference:
- `preimageOf(bytes32 commitment) -> CommitmentPreimage` (N1a assumption 1).
- `transactOwned(Transaction[] calldata)`, authorized by `msg.sender == owner`, no EdDSA (N1a assumption 2). P1
  settled the arity: one input note, one to three outputs.
- A `transact` output can be contract-owned: the caller supplies the preimage in the clear; the pool checks it and
  stores it in `preimageOf` (N2a assumption 1).
- The owner-derived `npk` formula is P1's: `npk = Poseidon(uint256(uint160(owner)), random)`.

## Goal
The pool gains a second, non-EdDSA entry point for a contract to spend and re-mint its own notes, and a public
registry so any reader can learn a contract-owned note's `token` and `value` from its commitment alone, with no
off-chain index (lab book decision 3).

## Deliver
- **S1 · `preimageOf` storage and population.** Add `mapping(bytes32 => CommitmentPreimage) public preimageOf;` to
  `PrivacyPoolStorage.sol`, at the end of the contract per its own "add at the end" rule (the file's header
  comment). In `TransactModule._accumulateAndNullify` (or a new helper called from the same place, name which),
  when a transaction's output `CommitmentCiphertext` slot is instead accompanied by a plaintext
  `CommitmentPreimage` (S2), hash it, require the hash equals the transaction's `commitments[i]`, and write
  `preimageOf[commitments[i]] = preimage` before the commitment is inserted into the tree.
- **S2 · Contract-owned output in `transact`.** `BoundParams.commitmentCiphertext` is a `CommitmentCiphertext[]`,
  one entry per non-unshield commitment (`PoolTypes.sol`'s `BoundParams`). Add a parallel, equal-length array of
  `CommitmentPreimage` option: a single new field on `BoundParams`,
  `CommitmentPreimage[] publicOutputs` (zero-length when no output is contract-owned; otherwise one entry per
  commitment, with the entry's `npk`/`token`/`value` all zero for a commitment whose output stays encrypted, and
  populated for a contract-owned output — state in the report if you instead key this by index with a separate
  `bool[]` flag, and why). `_validateTransaction` gains a check: for each non-zero `publicOutputs[i]`,
  `_hashCommitment(publicOutputs[i]) == commitments[i]`, and `publicOutputs[i].npk` matches P1's owner-derived
  formula only loosely required here — the pool does not re-derive `owner` from `npk` (any `npk` is acceptable as
  a plaintext output; the proof already constrained it). S1's `preimageOf` write happens for every non-zero
  `publicOutputs[i]`, for both `transact` and `transactOwned`.
- **S3 · `transactOwned` entry point.** New function on `ITransactModule`/`TransactModule`:
  `function transactOwned(Transaction[] calldata transactions) external;`, delegatecall-gated like `transact`.
  Each transaction's `boundParams.unshield` must be `UnshieldType.NONE` (no unshield from this path — P1's circuit
  has no `publicKey`/`signature` witness, so nothing authorizes paying out to an arbitrary address). Validation
  mirrors `_validateTransaction` (gas floor, chain ID, Merkle root, proof via `IVerifierModule(address(this))
  .verify`), but the proof is checked against P1's owned verifying-key set (the `(N, M)` shapes P1 registers under
  `_owned`, distinguished from the plain shapes — add a `bool owned` parameter to `VerifierModule.verify`'s shape
  lookup, or a separate `verifyOwned`, state which) and the function additionally requires
  `msg.sender == address(uint160(uint256(transactions[i].boundParams.ownerField)))` for every transaction (the
  circuit's public `owner` input, carried into `BoundParams` as a new `bytes32 ownerField` — add it next to
  `adaptContract`/`adaptParams`). Every output in a `transactOwned` call is contract-owned: S2's `publicOutputs`
  is mandatory (non-zero for every commitment), not optional.
- **S4 · `VerifierModule` owned-shape registry.** `setVerificationKey` gains an `owned` flag parameter (or a
  parallel `setVerificationKeyOwned`, state which) so P1's `1x1_owned`/`1x2_owned`/`1x3_owned` keys live in their
  own `(nullifiers, commitments)` slot, never colliding with the plain shapes' keys.

Keep existing conventions: every state-changing function stays `onlyDelegatecall`; `PrivacyPoolStorage`'s "add at
the end, never reorder" rule for new storage; an event for every state change (`PreimageRecorded(bytes32
commitment)` on S1's write, `TransactOwned(...)`, matching `Transact`'s existing event shape where reasonable).

## Acceptance (paste output)
`forge test --match-contract TransactOwnedTest` (new file `test/TransactOwned.t.sol`) output for these tests, each
failing on the commit before this task (compile failure counts as failing) and passing after:
- a `transact` call with one contract-owned output records `preimageOf[commitment]` with the correct `token` and
  `value`, readable by any caller;
- a `transact` call whose plaintext `publicOutputs[i]` does not hash to `commitments[i]` reverts;
- `transactOwned` from the correct owner, with a valid P1-owned proof, succeeds and updates `preimageOf` for every
  output;
- `transactOwned` called by an address other than the proof's `owner` reverts;
- `transactOwned` with `unshield != NONE` reverts.

Plus: the full `forge test` suite compiles and passes, including the existing `TransactModule` tests unaffected by
S1/S2's additive `BoundParams` field.

## Husband review
Audit-critical. Check:
- `preimageOf` is written only for a commitment the pool itself just verified (via the proof's commitment hash,
  S1/S2), never from an unverified caller input — the registry must never lie;
- `transactOwned`'s `msg.sender == owner` check reads the circuit's public input, not a separate caller-supplied
  parameter that could diverge from what the proof actually constrains;
- the owned and plain verifying-key sets (S4) cannot be confused — a plain-shape proof must never verify against
  an owned-shape key or vice versa.

## Out of scope
Fee-tagged outputs, `cumulativeFees`, `feeRecipient`, the `ShieldModule` fee note (P2b); non-upgradeable deployment
(P3); the Phase-2 ceremony for the owned shapes (P4).

## Handoff
Moves `armada-laconic/notes/handoff-2026-10-20.md` §0.4, row "F1 pool", chunk P2 (first half).
