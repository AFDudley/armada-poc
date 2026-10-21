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

## Token authority (the Gnosis Safe)

`ArmadaToken` holds one immutable governance address, named `timelock` in the source. The
deploy sets it to the Gnosis Safe (`scripts/deploy_governance.ts` passes the Safe as the
token's `_timelock`). So the Baal-governed Safe holds every `timelock`-gated token power.
There is no separate `TimelockController`; the new design routes governance through Baal
and the Safe. The Safe holds exactly two token powers: `addAuthorizedDelegator` and
`setTransferable`. Both revert for any caller other than the Safe. The token exposes no
other governance-gated setter.

`burn` is not a Safe power. Only an authorized burner may call it, and the deployer
registers the sole burner (`ShieldedRagequit`) once at deploy through `initBurners`. The
burner set is then frozen: no address, the Safe included, can add a burner (there is no
`addBurner`). So no caller can destroy a holder's ARM except the one exit path.

## Transfer allowlist

Transfers are restricted until they are enabled. While `transferable` is false, only a
whitelisted sender (or a mint) can move ARM. The allowlist is set once at deploy through
the deployer-only, one-shot `initWhitelist` (crowdfund, treasury/Safe, revenue lock) and is
then fixed; there is no `addToWhitelist`, so no address joins the allowlist after deploy.
`setTransferable(true)` is a one-way switch callable only by the Safe; once transfers are
enabled they cannot be re-restricted. `removeDeployerFromWhitelist()` is a deployer-only,
one-shot function that removes solely the deployer's own entry.

## Delegation

`delegateOnBehalf` and `transferAndDelegate` let an authorized contract (for example
`RevenueLock` or the crowdfund) credit ARM and set its delegation in one call. A
`noDelegation` set blocks delegation for addresses such as the treasury (the Gnosis Safe).
The authorized-delegator set is seeded post-deploy by the deployer via the one-shot
`initAuthorizedDelegators` setter; `addAuthorizedDelegator` is a Safe-only, add-only power.

## Hedgey lockup

The team's reserved ARM sits in a vendored Hedgey `TokenLockupPlans` linear-unlock plan
(`lib/hedgey`). The plan is created with `cancelable` false, so nobody can revoke it. For
the lockup to move ARM before global unlock, its address must be in the construction
allowlist set by `initWhitelist`, because the allowlist no longer grows after deploy. The
crowdfund's finalization sends its proceeds to the Safe as a shielded, contract-owned note
in the same transaction.

## Events

Standard ERC-20 events (`Transfer`, `Approval`) plus `DelegateChanged`, `DelegateVotesChanged`,
and `TransferableSet(bool)` — the latter emitted once when transfers are unlocked.
`RevenueUpdated` is not an ARM token event; it is emitted by the `RevenueCounter` contract.
