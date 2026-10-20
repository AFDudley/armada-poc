# ARM Token

`contracts/governance/ArmadaToken.sol` is ARM, the Baal shares token. One ARM is one
vote in Baal governance. ARM is an `ERC20Votes` token, so Baal reads voting power from its
checkpoints.

## Fixed supply

The constructor mints the whole supply once, 12,000,000 ARM, to the deployer, and mints
no more. There is no later mint path. The deployer distributes the supply at launch:

| Allocation | Amount | Recipient |
|---|---|---|
| Crowdfund | 1,800,000 | Crowdfund contract |
| Treasury | 7,800,000 | The Gnosis Safe |
| Early network | 2,400,000 | The shared revenue-lock contract |

## Non-upgradeable

ArmadaToken is a plain contract, not a proxy. It has no upgrade function and no admin that
can replace its code. Its invariants are unconditional — no proxy, no UUPS, no diamond,
no beacon.

## Transfer allowlist

Transfers are restricted until they are enabled. While `transferable` is false, only a
whitelisted sender (or a mint) can move ARM. `addToWhitelist` is timelock-only and
add-only: it lists an address, for example the Hedgey lockup, so that address can move ARM
before global unlock. `setTransferable(true)` is a one-way switch callable by the
timelock; once transfers are enabled they cannot be re-restricted. The initial whitelist
(crowdfund, treasury/Safe, revenue lock) is set in the constructor; `removeDeployerFromWhitelist()`
is a deployer-only, one-shot function that removes solely the deployer's own entry.

## Delegation

`delegateOnBehalf` and `transferAndDelegate` let an authorized contract (for example
`RevenueLock` or the crowdfund) credit ARM and set its delegation in one call. A
`noDelegation` set blocks delegation for addresses such as the treasury (the Gnosis Safe).
The authorized-delegator set is seeded post-deploy by the deployer via the one-shot
`initAuthorizedDelegators` setter; `addAuthorizedDelegator` is timelock-only and add-only.

## Hedgey lockup

The team's reserved ARM sits in a vendored Hedgey `TokenLockupPlans` linear-unlock plan
(`lib/hedgey`). The plan is created with `cancelable` false, so nobody can revoke it. The
`ArmadaToken` transfer allowlist lists the lockup through the timelock-only
`addToWhitelist` before ARM moves out of it. The crowdfund's finalization sends its
proceeds to the Safe as a shielded, contract-owned note in the same transaction.

## Events

Standard ERC-20 events (`Transfer`, `Approval`) plus `DelegateChanged`, `DelegateVotesChanged`,
and `TransferableSet(bool)` — the latter emitted once when transfers are unlocked.
`RevenueUpdated` is not an ARM token event; it is emitted by the `RevenueCounter` contract.
