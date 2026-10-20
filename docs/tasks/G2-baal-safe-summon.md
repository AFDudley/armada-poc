
# Chunk G2 · Family F3 · Points 8 · Route 5090

Depends on: G1.
Handoff row moved: `notes/handoff-2026-10-20.md` §0.4, row "F3 governance", chunk G2.

Repo: `armada-poc`. Branch: `integrated` (`60a2f05`), with G1 merged first.

Read first:
- `labbook/2026-10-18-treasury-governance-baal-safe-shielded.md` §2 ("MolochDAO and
  Baal"), §3 decisions 1, 8, 9, 10, and §4, the G2 check.
- `contracts/governance/ArmadaToken.sol` (G1's output): `delegateOnBehalf`,
  `addAuthorizedDelegator`, `getPastVotes` inherited from `ERC20Votes`.
- `armada-nitro/docs/ENVIRONMENT.md` §4 ("Reconciler contract") for the module shape a
  fixturenet deploy script must follow: `observe`/`apply`/`verify` steps, idempotent, gas
  printed per module. G2's deploy script does not join the reconciler's `env/` tree (that
  tree lives in `armada-nitro`); it follows the same shape inside `armada-poc`'s own
  `scripts/`.

## Goal

A summon script deploys one Baal instance (the HausDAO `feat/baalZodiac` branch, the
version the labbook records as audited by Hacken 2022-08-02 and Quantstamp 2022-10-18)
backed by one Gnosis Safe, with ARM as the Baal shares token, the Safe's only owner set to
the Baal contract, and the Safe's threshold set to 1.

## Deliver

- **S1 · Vendor the dependency.** No Safe or Baal contracts exist in this repo today
  (`lib/` holds only `forge-std` and `halmos-cheatcodes`; no `.gitmodules`). Add Gnosis
  Safe's `safe-contracts` and HausDAO's `Baal` (`feat/baalZodiac` branch) as `forge
  install` dependencies under `lib/`, pinned to the commits the labbook names (confirm the
  exact commit hashes by reading the `feat/baalZodiac` branch tip yourself; the labbook
  names the branch and the audit dates, not a commit hash). Add the matching
  `remappings.txt` entries alongside the existing `@openzeppelin/=node_modules/@openzeppelin/`
  line in `foundry.toml`.
- **S2 · Summon script.** `scripts/summon-baal-safe.ts` (or `.s.sol`, match the existing
  deploy scripts' language — read `scripts/deploy_privacy_pool.ts` for the house style
  first) that:
  1. deploys a Gnosis Safe with no human owners;
  2. deploys Baal, configured with ARM (G1's `ArmadaToken`) as its shares token, per the
     Baal summon interface in the vendored `feat/baalZodiac` source (cite the real
     function name and parameters once S1 is vendored; do not guess them here);
  3. sets the Safe's sole owner to the Baal contract and its threshold to 1;
  4. calls `ArmadaToken.addAuthorizedDelegator` with the Baal contract's address if Baal
     needs to move ARM voting power on summon (check the vendored source; skip this step
     if Baal does not call `delegateOnBehalf`).
- **S3 · Module wiring.** Baal's `authorizeAdapter` and `setFeeCollector` (an eventual
  call pattern that `labbook/2026-10-18` ruling 21:44:04 assigns to governance) are not
  yet contracts in this repo. This chunk wires only what G2's own scope builds: the Baal
  instance accepts proposals (confirm the vendored Baal exposes a `submitProposal` or
  equivalent entry point) and the Safe executes only through Baal.
- **S4 · Fixturenet deploy.** Extend `scripts/setup.sh` (or the `npm run setup` chain in
  `package.json`) with a `deploy:governance-baal` step that runs after ARM is deployed and
  before the crowdfund (G5) needs ARM shares. Match the existing step names in `package.json`
  `scripts.setup` (`deploy:governance`, `deploy:privacy-pool`, etc.).

## Conventions to keep

Follow the existing deploy script conventions in `scripts/` (confirm the pattern by
reading one deploy script fully before writing a new one — do not invent a new structure).

## Acceptance (paste output)

A fixturenet deploy run (`npm run setup` or the new step in isolation) that prints:
1. the Safe address, with zero human owners and threshold 1;
2. the Baal address, with ARM as its registered shares token;
3. `safe.isOwner(baal) == true` and `safe.getOwners().length == 1`.

Add a forge test, `test-foundry/BaalSafeSummon.t.sol`, that deploys the pair on a local
EVM and asserts the same three facts, failing before S2 exists (the summon script and its
target contracts are new) and passing after.

## Husband review

Audit-critical review not required by name (G2 is not on the P1/P2/N1/N2/G3 list), but the
husband must check: the Safe has no human owner at any point in the deploy script (even
transiently, since a transient human owner that is never removed is a latent second
spending path per decision 9); and the vendored Baal/Safe commits match the audited
versions the labbook names.

## Out of scope

`ShieldedRagequit` as the one shaman (G3). `authorizeAdapter`/`setFeeCollector` as live
Baal proposals against real adapter contracts (needs the adapters G4/G5 touch). The
treasury's shielded notes (G3, G5).
