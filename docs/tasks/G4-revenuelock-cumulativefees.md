
# Chunk G4 · Family F3 · Points 6 · Route 5090

Depends on: G1, P2 (armada-poc branch `briefs/F1`; interface:
`armada-laconic/.scratch/rewrite-evidence/P2-CONTRACT.md`).
Handoff row moved: `notes/handoff-2026-10-20.md` §0.4, row "F3 governance", chunk G4.

Repo: `armada-poc`. Branch: `integrated` (`60a2f05`), with G1 merged first.

Read first:
- `contracts/governance/RevenueLock.sol` (the whole file, 420 lines). The ratchet logic
  this chunk deletes is `maxObservedRevenue`, `_updateMaxObservedRevenue` (`:374-401`),
  `MAX_REVENUE_INCREASE_PER_DAY` (`:69`), and the wind-down freeze (`:329-360`).
- `contracts/governance/RevenueCounter.sol` (the whole file, 229 lines). This chunk's
  `RevenueLock` no longer reads `recognizedRevenueUsd` (`:18`); `RevenueCounter` itself is
  untouched here (G6 may remove it once nothing reads it, but check first — other callers
  may remain).
- `armada-laconic/.scratch/rewrite-evidence/P2-CONTRACT.md` item 4:
  `cumulativeFees(address asset) -> uint256` and `feeRecipient() -> bytes32 npk`, and item
  5: "G4's RevenueLock reads `cumulativeFees` and bounds its release by it."
- `labbook/2026-10-18-treasury-governance-baal-safe-shielded.md` §3 decision 22, and §4,
  the G4 check.

## Goal

`RevenueLock` releases ARM to beneficiaries in proportion to the pool's `cumulativeFees`
for one named asset, with no ratchet, no wind-down freeze, and no admin path — matching
the design's "every unlock corresponds to real USDC that ARM holders own" (decision 22).

## Deliver

- **S1 · Replace the revenue source.** Delete `IRevenueCounterRevenueLock` (`:7-9`) and the
  `revenueCounter` immutable (`:58`). Add an immutable `pool` reference and an immutable
  `asset` address (the token G4's release math bounds against, per P2-CONTRACT item 5).
  Constructor signature becomes `(address _armToken, address _pool, address _asset,
  address[] memory beneficiaries, uint256[] memory amounts)`, dropping
  `_revenueCounter` and `_maxIncreasePerDay`.
- **S2 · Delete the ratchet.** Remove `maxObservedRevenue`, `lastSyncTimestamp`,
  `MAX_REVENUE_INCREASE_PER_DAY`, `_updateMaxObservedRevenue` (`:374-401`),
  `getCappedObservedRevenue` (`:293-307`), `syncObservedRevenue` (`:251-253`), and the
  `ObservedRevenueUpdated`/`Synced` events. `cumulativeFees` is itself monotonic by the
  pool's own construction (P2-CONTRACT item 4: the pool increases it in the same
  transaction as a fee-tagged note), so the rate-limit ratchet that defended against a
  malicious `RevenueCounter` upgrade has no analogue to defend against: the pool is not
  upgradeable by Baal in the way `RevenueCounter` was UUPS-upgradeable by the old
  `ArmadaGovernor`. State this reasoning in a code comment at the deletion site.
- **S3 · `release(address delegatee)` reads `pool.cumulativeFees(asset)` directly** in
  place of `_updateMaxObservedRevenue()`'s result (`:225-227`). Keep the milestone step
  function (`_unlockBpsForRevenue`, `:406-415`) and its six constants unchanged — they are
  independent of the revenue source.
- **S4 · Delete the wind-down freeze.** Remove `windDownContract`,
  `windDownContractSet`, `setWindDownContract` (`:335-342`), `frozenAtWindDown`,
  `freezeAtWindDown` (`:351-360`), and `lockedAtWindDown` (`:321-327`). G6 removes
  `ArmadaWindDown` and `ArmadaRedemption`, the only callers of these functions; nothing in
  F3's kept contracts calls them after this chunk.
- **S5 · Keep unchanged:** `activate()` (`:203-209`), `allocation`/`released` mappings,
  `release`'s `armToken.transferAndDelegate` call (`:238`), `releasable` (`:261-269`,
  updated to call `pool.cumulativeFees(asset)` in place of `getCappedObservedRevenue()`),
  `beneficiaryCount` (`:310-312`).

## Conventions to keep

Keep the file's section-comment banner style (`// ============ ... ============`). Keep
`_min`/`BPS_100` if still referenced; delete if not.

## Acceptance (paste output)

`forge test --match-path test-foundry/RevenueLock.t.sol -vv`, with the existing suite
updated for the new constructor and these cases, each failing on `60a2f05` for the stated
reason before the edit and passing after:
1. `release` entitlement tracks `pool.cumulativeFees(asset)`, not a separate attestation
   call — call `pool.cumulativeFees` through a pool test double that a governance-only
   `addRevenue`-equivalent cannot move for free (the G4 check: "a test that inflates the
   counter for free ... must fail" now reads as "no function on `RevenueLock` or on the
   pool test double lets a non-fee-paying caller raise `cumulativeFees`" — assert no such
   function exists on `RevenueLock`);
2. a beneficiary cannot release ARM beyond the milestone the pool's real
   `cumulativeFees(asset)` value supports (the G4 check: "releases ARM with no matching fee
   must fail");
3. `releasable` and `release` agree bit-for-bit on the amount released, matching the
   deleted ratchet version's own invariant test (`test-foundry/RevenueLockInvariant.t.sol`,
   carried forward with the new constructor).

Plus: the existing `test-foundry/RevenueLockInvariant.t.sol` and
`test-foundry/RevenueReserveDistributor*.t.sol` suites still pass, updated only where the
constructor signature changed.

## Husband review

Not on the audit-critical list by name, but review: confirm `cumulativeFees` truly cannot
be moved except by a real fee-tagged pool transaction (P2's own guarantee, not
re-verified here) before trusting S1–S3's removal of the ratchet as safe.

## Out of scope

`RevenueCounter.sol` itself (not edited; G6 decides whether it is deleted once every
caller is gone). `RevenueReserveDistributor.sol` (reads `RevenueCounter`, not
`RevenueLock`; not touched unless G6's removal pass finds it orphaned).
