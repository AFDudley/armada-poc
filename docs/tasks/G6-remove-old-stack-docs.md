
# Chunk G6 · Family F3 · Points 8 · Route 5090

Depends on: G2, G5.
Handoff row moved: `notes/handoff-2026-10-20.md` §0.4, row "F3 governance", chunk G6.

Repo: `armada-poc`. Branch: `integrated` (`60a2f05`), with G1, G2, G3, G4, G5 merged first.

Read first:
- `armada-laconic/labbook/2026-10-19-docs-versus-code.md` §3 finding 11: "The docs omit
  the governance contracts in `armada-poc`: `ArmadaGovernor`, `ArmadaTreasuryGov`,
  `TreasurySteward`, `ArmadaToken`, `ArmadaCrowdfund`, `ArmadaWindDown`,
  `ArmadaRedemption` and the revenue contracts." G6 is the chunk that makes the code match
  the new design, so this gap closes by code removal, not by a new doc section.
- `armada-laconic/labbook/2026-10-18-treasury-governance-baal-safe-shielded.md` §5,
  "Rejected options", first bullet: "The current `armada-poc` governance (governor,
  treasury-governor, steward, wind-down, redemption, the veto). Rejected because exit
  replaces rule-based defense."
- Every file this chunk deletes, read in full first: `contracts/governance/ArmadaGovernor.sol`
  (1640 lines), `contracts/governance/ArmadaTreasuryGov.sol` (686 lines),
  `contracts/governance/TreasurySteward.sol` (86 lines),
  `contracts/governance/ArmadaWindDown.sol` (273 lines),
  `contracts/governance/ArmadaRedemption.sol` (267 lines),
  `contracts/periphery/RedemptionRouter.sol`, `contracts/governance/MockRedemptionDeps.sol`.
- `contracts/governance/IArmadaGovernance.sol`: keep `IAdapterRegistry` (used by
  `ShieldModule.sol:17,224-226`); delete `IArmadaGovernorTiming` and `ITreasurySteward`
  (no caller survives this chunk).
- `contracts/governance/RevenueCounter.sol:224` comment references `ArmadaGovernor`'s
  50-slot gap convention only in a comment; `RevenueCounter` itself still has callers
  (confirm with a repo-wide search before deciding whether it, too, is removed — the
  labbook's decision 1 names only governor/treasury-governor/steward/wind-
  down/redemption/veto as dropped, not `RevenueCounter`).

## Goal

The repository contains no governor, treasury-governor, steward, wind-down, or
redemption contract. Baal (G2) and the Safe are the only governance surface. `specs/GOVERNANCE.md`
and `specs/ARM_TOKEN.md` describe the code that remains.

## Deliver

- **S1 · Delete the contracts.** Remove `ArmadaGovernor.sol`, `ArmadaTreasuryGov.sol`,
  `TreasurySteward.sol`, `ArmadaWindDown.sol`, `ArmadaRedemption.sol`,
  `RedemptionRouter.sol`, `MockRedemptionDeps.sol`, and every test file under
  `test-foundry/` and `test/` that targets only these contracts (for example
  `GovernorClassificationWindDown.t.sol`, `GovernorEventGaps.t.sol`,
  `GovernorInvariant.t.sol`, `GovernorQueueOutflow.t.sol`, `GovernorSignaling.t.sol`,
  `GovernorSteward.t.sol`, `GovernorUpdateDelayCap.t.sol`, `GovernorUpgrade.t.sol`,
  `GovernorVeto.t.sol`, `helpers/GovernorDeployHelper.sol`). Grep the deleted files' names
  across `contracts/`, `scripts/`, `test/`, and `test-foundry/` first and list every match
  in the report — do not delete a file with a surviving caller without updating that
  caller in the same commit.
- **S2 · Trim `IArmadaGovernance.sol`.** Delete `IArmadaGovernorTiming` and
  `ITreasurySteward` and the `ProposalType`/`ProposalState`/`ProposalParams` types that
  only those interfaces used. Keep `IAdapterRegistry`.
- **S3 · Deploy scripts.** Remove `deploy:governance`'s old steps from `package.json`'s
  `scripts.setup` chain (the governor/treasury-gov/steward/wind-down/redemption deploy
  calls) and any `scripts/deploy_governance*.ts` that only deployed them. G2's Baal/Safe
  summon script (already added) takes their place in the chain.
- **S4 · `specs/GOVERNANCE.md` rewrite.** If `specs/GOVERNANCE.md` exists, rewrite it to describe Baal
  + Safe (G2), `ShieldedRagequit` (G3), `RevenueLock` on `cumulativeFees` (G4), and the
  Hedgey lockup (G5), with no section describing the deleted contracts. If it does not
  exist, create it at the repo root, same shape as a comparable doc you find in the repo
  (check `docs/` and the root for an existing pattern before inventing one).
- **S5 · `specs/ARM_TOKEN.md` rewrite.** Describe `ArmadaToken` as the Baal shares token (G1):
  fixed 12M supply, non-upgradeable, transfer allowlist, no wind-down-gated
  `setTransferable` caller (G1 S5 already removed the dependency on
  `windDownContract`). Remove any existing description of `ArmadaRedemption`'s
  `circulatingSupply` math or `ArmadaWindDown`'s sweep.

## Conventions to keep

Match the existing `ABOUTME:` header comment convention on any new or rewritten
Markdown-adjacent Solidity file touched incidentally. Do not touch `RevenueReserveDistributor.sol`
or `RevenueCounter.sol` unless S1's grep shows them with no surviving caller.

## Acceptance (paste output)

`forge build` succeeds with zero references to the deleted contracts (`grep -rl
"ArmadaGovernor\|ArmadaTreasuryGov\|TreasurySteward\|ArmadaWindDown\|ArmadaRedemption"
contracts/ scripts/` returns nothing). `forge test` runs with no failing import. A diff of
`specs/GOVERNANCE.md` and `specs/ARM_TOKEN.md` pasted in the report.

## Husband review

Confirm S1's grep was run and its output is in the report, not merely claimed. Confirm no
test left behind calls a deleted contract's address as a mock/fixture dependency.

## Out of scope

Rewriting `RevenueReserveDistributor.sol` (kept unless S1 finds it orphaned). The G7 gate
itself (reads the surviving contracts only, run after this chunk merges).
