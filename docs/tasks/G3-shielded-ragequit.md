
# Chunk G3 · Family F3 · Points 9 · Route 5090

Depends on: G2, P2 (armada-poc branch `briefs/F1`; interface:
`armada-laconic/.scratch/rewrite-evidence/P2-CONTRACT.md`).
Handoff row moved: `notes/handoff-2026-10-20.md` §0.4, row "F3 governance", chunk G3.

Repo: `armada-poc`. Branch: `integrated` (`60a2f05`), with G1 and G2 merged first.

Read first:
- `labbook/2026-10-18-treasury-governance-baal-safe-shielded.md` §3 decisions 12, 13, 14,
  15, 16, 20, 21, and §4, the G3 check.
- `armada-laconic/.scratch/rewrite-evidence/P2-CONTRACT.md` items 1–3 and 6
  (`preimageOf`, `transactOwned`, a contract-owned `transact` output, and the owner-derived
  `npk` derivation). This chunk is the first consumer of `transactOwned`.
- `contracts/privacy-pool/types/PoolTypes.sol:79-83` (`CommitmentPreimage`: `npk`, `token`,
  `value`) and `:119-129` (`Transaction`).
- `contracts/privacy-pool/PrivacyPool.sol:138-148` (`shield` and `transact` both
  delegatecall into a module; `transactOwned` is P2's addition to this same router).
- `armada-sdk/src/tx/plan.ts` `planSpend` (line 392) and `armada-sdk/src/tx/prove.ts`
  `prove` (line 81): the client-side shape a held note is later spent with. G3's tests
  build one such proof to show a ragequit payout note is spendable.

## Goal

A Baal manager shaman, `ShieldedRagequit`, burns the caller's ARM and pays
`burned / totalSupply × treasuryBalance` of each listed token as a contract-owned note to
the caller's own `npk`, with no treasury signature and no quorum.

## Deliver

- **S1 · `ShieldedRagequit.sol`.** A new file under `contracts/governance/`. Constructor
  takes the ARM token (G1), the Baal address (G2), the Safe address (G2), and the pool
  address (P2). It implements Baal's manager-shaman interface (confirm the exact interface
  from the vendored `feat/baalZodiac` source G2 added; cite the real function names once
  read).
- **S2 · `ragequit(uint256 armAmount, bytes32 npk, address[] calldata tokens)`.** Burns
  `armAmount` of the caller's ARM (via `ArmadaToken` — G1 has no `burn` function today;
  add one, timelock-independent, callable only by `ShieldedRagequit`, mirroring the
  one-shot authorized-caller pattern of `addAuthorizedDelegator`
  (`ArmadaToken.sol:143-149`)). For each token in `tokens`, computes
  `payout = armAmount * safe.balanceOf(token) / armToken.totalSupply()` at the time of the
  call (decision 20), and calls the pool's `transactOwned` (P2) once per token to create a
  `CommitmentPreimage{npk, token, payout}` note owned by the caller, debited from the
  Safe's existing pool-owned note (not a plain ERC-20 transfer — the Safe's assets are
  pool-owned notes per decision 14, so the payout spends one Safe-owned note and outputs
  one caller-owned note plus one Safe-owned change note in the same `transactOwned` call).
- **S3 · No treasury signature.** `ragequit` requires only `msg.sender`'s own call;
  it calls no Safe-owner-gated function and needs no Baal proposal (decision 12 and the G3
  check in §4: "a test where the exit needs the treasury's signature must fail").
- **S4 · Payout bound.** `ragequit` must not pay more than
  `armAmount * safe.balanceOf(token) / armToken.totalSupply()` for any listed token (the
  G3 check: "a test where the exit pays more ... must fail"). Compute the bound from
  balances read inside the same transaction, not a cached or governance-set value.
- **S5 · One shaman only.** `ShieldedRagequit` is the only shaman Baal's summon (G2)
  registers (decision 21). Add a test asserting Baal's shaman list has exactly one entry
  after G2's summon plus this chunk's registration.

## Conventions to keep

`SafeERC20` for every token call (E16's convention, carried into armada-poc's existing
`ShieldModule.sol:34` `using SafeERC20 for IERC20`). An event for every holdings change
(`RagequitExecuted(address indexed holder, uint256 armBurned, bytes32 npk, address[]
tokens, uint256[] payouts)`).

## Acceptance (paste output)

`forge test --match-path test-foundry/ShieldedRagequit.t.sol -vv`, each test failing on
`60a2f05` (the contract does not exist) and passing after:
1. ragequit burns the caller's ARM and reduces `totalSupply` (S2);
2. ragequit creates a contract-owned note at the caller's `npk` with the bounded payout,
   confirmed by reading `preimageOf` (P2-CONTRACT item 1) on the resulting commitment (S2,
   S4);
3. ragequit with no Safe signature and no Baal proposal still succeeds (S3);
4. a crafted call that tries to claim more than the bound reverts (S4);
5. Baal's shaman list holds exactly `ShieldedRagequit` (S5).

Plus, using `armada-sdk` at `integrated` (`8d621aa`): a script or test (TypeScript, under
`test/` or a new `scripts/verify-ragequit-exit-proof.ts`) that takes the commitment from
test 2, calls `planSpend` and `prove` against it, and confirms the resulting proof
verifies on-chain through `PrivacyPool.transact` — proving the payout note is a real,
spendable note, not merely a correctly-sized preimage.

## Husband review (audit-critical)

- The payout bound (S4) holds for every call ordering, including two ragequits in the same
  block against the same token.
- `ShieldedRagequit` cannot be called through `transactOwned` by any account other than the
  Safe's own notes — confirm the `npk` derivation (P2-CONTRACT item 6) binds the spent note
  to the Safe's address, not to `msg.sender` of `ragequit`.
- The burn in S2 is irreversible and leaves no path to credit `armAmount` back to the
  caller on a reverted or partial payout.
- No code path lets `ShieldedRagequit` call `transactOwned` for a token the Safe does not
  hold as a pool-owned note.

## Out of scope

`authorizeAdapter` and `setFeeCollector` as Baal proposals (G2's scope, not built yet).
RevenueLock's `cumulativeFees` read (G4). The wallet-side ragequit flow (C6).
