# Governance

Armada governance is a Baal (Moloch v3) DAO with a Gnosis Safe treasury. The old
on-chain governor, treasury-governor, steward, wind-down and redemption contracts are
gone. This document describes the contracts that remain.

## Baal and the Safe

Baal is the DAO. It holds proposals, voting and execution. ARM is the Baal shares token
(see `ARM_TOKEN.md`): one ARM is one vote.

The Gnosis Safe is the treasury. The Safe holds every protocol asset. The Safe has one
owner, the Baal contract, and its threshold is one. No human is a Safe owner. A treasury
move is an ordinary Baal proposal that Baal executes through the Safe. There is no
separate steward role and no veto contract.

`scripts/summon-baal-safe.ts` deploys Baal and the Safe and wires them (chunk G2).

## ShieldedRagequit

`contracts/governance/ShieldedRagequit.sol` lets any ARM holder exit at any time. The
holder calls `ragequit`, which burns their ARM and pays a bounded pro-rata share of the
treasury. The payout is a contract-owned note at the holder's note public key, paid
through the pool's contract-owned spend path. The bound is
`armAmount * safe.balanceOf(token) / armToken.totalSupply()`. A captured majority cannot
block the exit (chunk G3).

## RevenueLock on cumulative fees

`contracts/governance/RevenueLock.sol` holds the team's revenue allocation and releases
it against the pool's real `cumulativeFees(asset)` total. The release reads the live,
monotonic fee total; no rate-limit ratchet gates it. `RevenueReserveDistributor.sol`
pays each grantee from the lock (chunk G4).

## Hedgey lockup

The team's reserved ARM sits in a vendored Hedgey `TokenLockupPlans` linear-unlock plan
(`lib/hedgey`). The plan is created with `cancelable` false, so nobody can revoke it. The
`ArmadaToken` transfer allowlist lists the lockup through the timelock-only
`addToWhitelist` before ARM moves out of it (chunk G5).

## Shield pause

`contracts/governance/ShieldPauseController.sol` holds the shield pause state. Its pause
authority is a plain address set once at construction (the Safe). The SC pause duration is
zero, so an SC pause never actually pauses shields.
