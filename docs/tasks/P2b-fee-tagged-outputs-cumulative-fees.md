Chunk P2b · Family F1 · Points 5 · Route 5090
Depends on: P2a

Repo: `armada-poc`. Branch: `integrated` (work in a `task/P2b` branch cut from `task/P2a`, once P2a merges to
`integrated` — or from P2a's own branch if P2a has not yet merged; state which in the report).

Read `contracts/privacy-pool/modules/ShieldModule.sol` (the whole file), `contracts/privacy-pool/modules/
TransactModule.sol`, P2a's diff on `preimageOf` and `transactOwned` (`contracts/privacy-pool/storage/
PrivacyPoolStorage.sol`, `contracts/privacy-pool/interfaces/ITransactModule.sol` once merged), and the
armada-laconic lab book `labbook/2026-10-18-treasury-governance-baal-safe-shielded.md` §3 decisions 15, 16, 22 and
§4 ("G4 tests", "N8 gate").

## This chunk's contract to F4
Chunk N2b in `armada-nitro` (`briefs/F4`, commit `ab694ba`) assumes this interface. Meet it exactly, or stop and
report the difference:
- `cumulativeFees(address asset) -> uint256`.
- `feeRecipient() -> bytes32 npk` (the Safe's registered note public key).
- An output whose `npk == feeRecipient()` is recognized by the pool itself — not by the caller declaring it a fee
  — in the same call that creates it, both storing its `preimageOf` (P2a) and incrementing `cumulativeFees[asset]`
  by its value. This applies identically whether the output comes from a user's `transact` call (a swap fee), a
  local `shield` call, or the adjudicator's `transactOwned` payout (N2b).

## Goal
A note paid to the Safe's registered `npk`, by any path that creates a contract-owned output, is counted toward a
single on-chain running total per asset, with no caller-declared flag the pool has to trust (lab book decision 15:
"`ShieldModule` creates the fee note to the Safe's `npk` and increments `cumulativeFees` in the same permissionless
call").

## Deliver
- **S1 · `feeRecipient` storage and setter.** Add `bytes32 public feeRecipient;` to `PrivacyPoolStorage.sol`
  (append, per its "add at the end" rule) and `function setFeeRecipient(bytes32 npk) external` on `PrivacyPool`
  (owner-gated, same pattern as `setShieldFee`). `npk` is the Safe's owner-derived value, P1's formula applied to
  the Safe's address — this chunk does not compute it; it only stores whatever `npk` governance sets.
- **S2 · `cumulativeFees` storage.** Add `mapping(address => uint256) public cumulativeFees;` (asset address to
  running total), appended per the same rule.
- **S3 · Recognition in the contract-owned-output path.** In P2a's S1 write path (where `preimageOf[commitment]` is
  set for a plaintext output), add: if `preimage.npk == feeRecipient` and `feeRecipient != bytes32(0)`,
  `cumulativeFees[preimage.token.tokenAddress] += preimage.value`. One write site covers `transact`'s
  contract-owned outputs and `transactOwned`'s outputs (N2b's payout path), because both go through P2a's shared
  helper.
- **S4 · Recognition in `shield`/`processIncomingShield`.** `ShieldModule`'s notes are always plaintext commitment
  preimages already (`_shieldRequests[i].preimage`, `ShieldRequest` has no ciphertext-only mode for the preimage
  itself — only `ShieldCiphertext` is the encrypted *metadata*). After `_transferTokenIn`/`_applyShieldFee` produce
  `commitments[i]` (the fee-adjusted preimage), apply S3's same check: `npk == feeRecipient` and increment
  `cumulativeFees`, and write `preimageOf[hash] = commitments[i]` (P2a's registry, extended to cover
  `ShieldModule`'s outputs too — state in the report whether P2a's S1 already covered `shield`'s plaintext outputs
  or whether this is new).

Keep existing conventions: an event for every state change (`FeeRecognized(address asset, uint256 amount, bytes32
commitment)`); the owner-gated setter pattern `setShieldFee` already uses.

## Acceptance (paste output)
`forge test --match-contract FeeTaggedOutputsTest` (new file `test/FeeTaggedOutputs.t.sol`) output for these tests,
each failing on the commit before this task and passing after:
- a local `shield` call whose note's `npk` equals `feeRecipient` increases `cumulativeFees[token]` by exactly the
  shielded (fee-adjusted) value, and does not increase it for any other npk;
- a `transact` call with a contract-owned output to `feeRecipient` increases `cumulativeFees` by the output's
  value, and a second output to a different `npk` in the same call does not;
- `cumulativeFees` cannot be inflated by a call that creates no matching output (a transaction with no
  `feeRecipient`-targeted output leaves every `cumulativeFees[asset]` unchanged) — this is the test G4's
  RevenueLock rewrite relies on (governance lab book, "G4 tests": "A test that inflates the counter for free ...
  must fail").

Plus: the full `forge test` suite compiles and passes.

## Husband review
Audit-critical. Check:
- `cumulativeFees` increases only on a real, value-moving output the pool itself hashed and verified (S3/S4), never
  on a caller-asserted amount;
- `feeRecipient` has no code path that lets anyone but the owner change it after the fact without an event;
- the Safe's `npk` (P1's formula applied to the Safe's address) is the only value that can ever be set as
  `feeRecipient` — confirm this is an operational/governance guarantee, not a contract-enforced one, and name it as
  such in the report if the contract does not check it.

## Out of scope
Non-upgradeable deployment (P3); the Phase-2 ceremony (P4); RevenueLock's own rewrite (G4, a different family);
the N8 gate itself, which proves the full swap-fee-to-RevenueLock path end to end.

## Handoff
Moves `armada-laconic/notes/handoff-2026-10-20.md` §0.4, row "F1 pool", chunk P2 (second half).
