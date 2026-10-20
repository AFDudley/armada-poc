# Governance

Armada's governance is one Baal (Moloch v3) DAO holding one Gnosis Safe as its
treasury. This document describes the contracts that remain.

## Baal and the Safe

Baal is the DAO. It holds the proposals, the votes, and the execution. ARM is Baal's
shares token (see ARM_TOKEN.md): one ARM is one vote.

The Gnosis Safe is the treasury. The Safe holds every protocol asset. Baal is the Safe's
sole owner, and its threshold is one. No human is a Safe owner. A treasury movement is an
ordinary Baal proposal that Baal executes through the Safe. No other treasury role
or gate contract exists.

`scripts/summon-baal-safe.ts` deploys Baal and the Safe and wires them (chunk G2). The
wiring order guarantees no human is a Safe owner at any point — not even transiently:

1. Deploy the Safe proxy with empty setup data (zero owners, threshold zero — not yet a
   functioning Safe, and no owner of any kind, human or not, exists at that point).
2. Clone the Baal template via zodiac's ModuleProxyFactory.
3. `safe.setup(owners=[baal], threshold=1)` enables Baal as the Safe's first and only
   owner in the same call — the Safe's first owner-bearing state has the Baal as its sole
   owner, never a human key.
4. `baal.setUp(...)` registers G1's `ArmadaToken` as Baal's shares token and the frozen
   `BaallLootToken` as its loot token, with the Safe as Baal's avatar.
5. Transfer the loot token's ownership to the Baal. The shares token is a plain,
   non-upgradeable ERC20 with no ownership to transfer: Baal only reads it (paused,
   name, symbol, getVotes, getPastVotes, totalSupply), and the ARM burn is gated to the
   ShieldedRagequit shaman (G3), so Baal can neither mint nor burn ARM.

`BaallLootToken`'s mint reverts forever, so the loot supply is zero at every moment: no
loot holder can use Baal's native ragequit.

## ShieldedRagequit

`contracts/governance/ShieldedRagequit.sol` is the one exit from the DAO. It lets any ARM
holder exit at any time. The holder calls `ragequit(armAmount, npk, tokens)`, which burns
their ARM and pays a bounded pro-rata share of the treasury.

- The burn goes through `ArmadaToken.burn`, which is callable only by the shaman (G3).
- The per-token payout bound is `armAmount * safe.balanceOf(token) / armToken.totalSupply()`.
- The payout is a contract-owned note at the holder's note public key, paid through the
  pool's contract-owned spend path (`transactOwned`, P2a) and debited from the Safe's
  pool-owned note. No Safe signature, no Baal proposal — a captured majority cannot block
  the exit.
- Every holdings change emits `RagequitExecuted`.

## RevenueLock on cumulative fees

`contracts/governance/RevenueLock.sol` holds the team's revenue allocation and releases it
against the pool's real per-asset `cumulativeFees(asset)` total. The release reads the
live, monotonic fee total; no rate-limit ratchet is needed (decision 22). `release(delegatee)`
transfers and delegates atomically: `ArmadaToken.transferAndDelegate(msg.sender, amount,
delegatee)`.

`activate()` is one-shot and requires the lock to hold at least its full allocation.
`releasable(beneficiary)` mirrors exactly what `release()` would deliver.
`RevenueReserveDistributor.sol` pays each grantee from the lock: anyone may sponsor a
batch through `distribute()`; the distributor atomically undelegates its collected ARM and
preserves each recipient's existing delegation (chunk G4).

## Hedgey lockup

The team's reserved ARM sits in a vendored Hedgey `TokenLockupPlans` linear-unlock plan
(`lib/hedgey`). The plan is created with `cancelable` false, so nobody can revoke it. The
`ArmadaToken` transfer allowlist lists the lockup through the timelock-only
`addToWhitelist` before ARM moves out of it (chunk G5). The crowdfund's sale proceeds reach
the Safe as a shielded, contract-owned note in the same transaction that ends the sale
(G5 S1), with no USDC resting at a public address.

## Shield pause

`contracts/governance/ShieldPauseController.sol` holds the shield pause state. Its pause
authority is a plain address set once at construction (the Safe holds the pause authority
after G6). The SC pause duration is zero, so an SC pause never actually pauses shields:
`shieldsPaused()` reads a rolling window of duration zero. Unshielding is never pausable.
The `setWindDownContract` one-shot setter (timelock-only) registers the exit contract.
