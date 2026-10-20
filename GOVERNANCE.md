# Armada Governance

The Armada on-chain governance surface is the Baal contract backed by a Gnosis
Safe, with ARM (ArmadaToken) as the Baal shares token.

## Components

- **Baal** (G2): the primary governance authority. One Baal is backed by one
  Gnosis Safe; the Safe's sole owner is the Baal contract, with threshold 1. ARM
  is registered as the Baal shares token.
- **Safe**: the Gnosis Safe proxy. The Baal is its sole owner; no human owner is
  ever present, even transiently. The Safe is owned solely by the Baal.
- **ShieldedRagequit** (G3): shields/unshields for the PrivacyPool with the
  ShieldedRagequit contract.
- **RevenueLock** (G4): locks the cumulativeFees on the RevenueLock contract.
- **Hedgey lockup** (G5): the crowdfund proceeds and the Hedgey lockup.

## Deployment

The Baal and Safe are deployed by `scripts/summon-baal-safe.ts` (the
`deploy:governance-baal` step in `package.json`'s setup chain). The old
governor, treasury-gov, steward, wind-down, and redemption stack is removed from
the repository; Baal and the Safe are the only on-chain governance surface.
