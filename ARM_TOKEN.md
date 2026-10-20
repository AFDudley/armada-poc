# ARM token

`contracts/governance/ArmadaToken.sol` is ARM, the Baal shares token. One ARM is one
vote in Baal governance. ARM is an `ERC20Votes` token, so Baal reads voting power from its
checkpoints.

## Fixed supply

The constructor mints the whole supply once, 12,000,000 ARM, to the deployer, and mints
no more. There is no later mint path. The deployer distributes the supply at launch.

## Non-upgradeable

ArmadaToken is a plain contract, not a proxy. It has no upgrade function and no admin that
can replace its code.

## Transfer allowlist

Transfers are restricted until they are enabled. While `transferable` is false, only a
whitelisted sender (or a mint) can move ARM. `addToWhitelist` is timelock-only and
add-only; it lists an address, for example the Hedgey lockup, so that address can move ARM.
`setTransferable(true)` is a one-way switch callable by the timelock; once transfers are
enabled they cannot be re-restricted.

## Delegation

`delegateOnBehalf` and `transferAndDelegate` let an authorized contract (for example
`RevenueLock` or the crowdfund) credit ARM and set its delegation in one call. A
`noDelegation` set blocks delegation for addresses such as the treasury.
