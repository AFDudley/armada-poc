# ARM Token

The ArmadaToken is the fixed-supply Baal shares token (G1). It is registered on
the Baal as its shares token, and transferred to the Baal so only the Baal can
mint, burn, pause, or unpause it.

## Relationship to Baal

The ArmadaToken (ARM) is the Baal's registered shares token. The Baal contract
(lib/baal) uses it as the fixed-supply shares token for its governance. The token
is deployed by `scripts/summon-baal-safe.ts` and wired to the Baal.
