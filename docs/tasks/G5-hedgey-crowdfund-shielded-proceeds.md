> **SUPERSEDED IN PART (2026-10-22).** The crowdfund has NO code path into the
> pool or governance (treasury lab book
> `armada-laconic/labbook/2026-10-18-treasury-governance-baal-safe-shielded.md`
> §3a T3). So deliverable S1 below — `finalize` shields `proceedsPush` through
> the pool's shield path to the Safe's `npk` — is void. `finalize` keeps its
> plain `usdc.safeTransfer(treasury, proceedsPush)`. There is no protocol swap
> fee (§3a T9; decision 23 struck on 2026-10-22 as an agent error) and no
> fee-tagged `transact` output. The `finalize`-to-`feeRecipient` shield never
> raises `cumulativeFees`: only the shield-in fee that `ShieldModule` charges
> does (§3a T2(a)). Read the P2-CONTRACT `feeRecipient`/`cumulativeFees`
> references below as not applicable to the crowdfund. The Hedgey lockup
> deliverables (S3 and after) are unchanged.


# Chunk G5 · Family F3 · Points 8 · Route 5090

Depends on: G1, P2 (armada-poc branch `briefs/F1`; interface:
`armada-laconic/.scratch/rewrite-evidence/P2-CONTRACT.md`).
Handoff row moved: `notes/handoff-2026-10-20.md` §0.4, row "F3 governance", chunk G5.

Repo: `armada-poc`. Branch: `integrated` (`60a2f05`), with G1 merged first.

Read first:
- `contracts/crowdfund/ArmadaCrowdfund.sol:569-611` (`claim`): it already transfers ARM
  (G1's `ArmadaToken`) to each participant via `transferAndDelegate` (`:602`). This part of
  "crowdfund delivers ARM shares" needs no change.
- `contracts/crowdfund/ArmadaCrowdfund.sol:466-558` (`finalize`), specifically
  `:529-555`: `finalize` computes `proceedsPush` and pays it with a plain
  `usdc.safeTransfer(treasury, proceedsPush)` at line 555. This is the tainted-treasury
  path the labbook's §6.1 "treasury fees and the deposit system" observation names: a
  direct transfer leaves the treasury one hop from any tainted committer's USDC.
- `armada-laconic/.scratch/rewrite-evidence/P2-CONTRACT.md` items 1–4 (`preimageOf`,
  `transactOwned`, a contract-owned output, `feeRecipient`/`cumulativeFees`).
- `labbook/2026-10-18-treasury-governance-baal-safe-shielded.md` §3 decisions 6, 7, 15,
  16, and §4, the G5 check.
- `contracts/privacy-pool/modules/ShieldModule.sol:138-211` (`_applyShieldFee`): the shape
  of a module-level shield call this chunk's crowdfund-side shield follows, scaled down (no
  fee split needed here — the full `proceedsPush` goes to the Safe's note).

## Goal

The crowdfund's sale proceeds reach the Safe as a shielded, contract-owned note in the
same transaction that ends the sale, with no USDC resting at a public address. A Hedgey
`TokenLockupPlans` linear unlock holds ARM reserved for the team and releases it over
time, with no revocation and no admin override.

## Deliver

- **S1 · Replace the plain transfer.** `ArmadaCrowdfund.sol:554-555` becomes a call into
  the pool's shield path (P2's `shield` or a Safe-owned variant of it), creating a
  `CommitmentPreimage{npk: safeNpk, token: usdc, value: proceedsPush}` note instead of
  `usdc.safeTransfer(treasury, proceedsPush)`. `safeNpk` is the Safe's owner-derived `npk`
  (P2-CONTRACT item 6, the same derivation G3 uses). The crowdfund contract needs
  `approve`/`forceApprove` on the pool before the shield call, following
  `ShieldModule.sol`'s own `SafeERC20` convention.
- **S2 · The `treasury` field's role narrows.** `ArmadaCrowdfund.sol:99`
  (`address public immutable treasury`) still receives `withdrawUnallocatedArm`'s ARM sweep
  (`:643-656`, unchanged — unsold ARM is not tainted, it never left the contract as a
  public-address balance of committed funds). Only the USDC proceeds path (S1) changes.
  Do not rename or remove the `treasury` immutable.
- **S3 · Hedgey lockup deploy.** Add the `hedgey-protocol` `TokenLockupPlans` dependency
  (`forge install`, pinned to the Consensys-Diligence-audited release the labbook names,
  2023-06; confirm the exact tag by reading the upstream repo's release list) and a deploy
  script, `scripts/deploy-hedgey-lockup.ts`, that creates one linear-unlock plan for the
  team's reserved ARM allocation, with `cancelable = false` at creation (Hedgey's lockup
  "cannot be configured wrong" per the labbook only if this flag is set correctly; assert
  it explicitly in the deploy script, not only by relying on the default).
- **S4 · Whitelist the lockup.** `ArmadaToken.addToWhitelist` (`:131-137`, timelock-only)
  must list the Hedgey lockup contract's address before ARM transfers into it, and
  `ArmadaCrowdfund` must stay whitelisted for its own ARM transfers out via `claim`
  (already true: `ArmadaCrowdfund` is not the sender in `transferAndDelegate`, `ArmadaToken`
  itself is, per `:190-194`; confirm this still holds and needs no extra whitelist entry).

## Conventions to keep

`SafeERC20`/`forceApprove` before any pool call, matching `ShieldModule.sol`'s pattern. Keep
`ArmadaCrowdfund`'s existing `nonReentrant` modifier on `finalize`.

## Acceptance (paste output)

`forge test --match-path test-foundry/CrowdfundShieldedProceeds.t.sol -vv`, each test
failing on `60a2f05` (the current code sends a plain transfer) before the edit and passing
after:
1. after `finalize`, the pool holds a Safe-owned note for `proceedsPush`, confirmed by
   reading `preimageOf` on the resulting commitment, and the USDC balance of the `treasury`
   address (a plain EOA/contract balance, not the Safe's pool-owned note) is unchanged by
   `finalize` (the G5 check: "a test where crowdfund USDC sits at a public address must
   fail");
2. ARM still reaches each claimant through `claim`, unchanged behavior (regression check
   against the existing `test-foundry/CrowdfundFullInvariant.t.sol` suite);
3. the Hedgey lockup plan for the team allocation is non-cancelable, confirmed by reading
   the deployed plan's `cancelable` field.

Plus: the existing `test-foundry/Crowdfund*.t.sol` suite passes with `treasury` receiving
only the unsold-ARM sweep, not USDC proceeds.

## Husband review

Not on the audit-critical list by name, but review: the Safe's `npk` derivation in S1
matches the same derivation G3 uses for ragequit payouts (one owner-derived `npk` per
Safe, not two divergent ones), and the rounding-buffer USDC
(`ArmadaCrowdfund.sol:553`, "stranded in the contract as unrecoverable dust") is not a new
quarantine case this chunk must solve — it is pre-existing, documented dust, out of scope.

## Out of scope

The fee-tagged note path for the pool's own shield/unshield fees (decision 15; a separate
item inside P2/ShieldModule, not the crowdfund). Governance-gated changes to the Hedgey
plan after creation (none exist; Hedgey has no admin override by design).
