
# Chunk G1 · Family F3 · Points 6 · Route 5090

Depends on: — (first chunk of F3).
Handoff row moved: `notes/handoff-2026-10-20.md` §0.4, row "F3 governance", chunk G1.

Repo: `armada-poc`. Branch: `integrated` (`60a2f05`). Open a worker branch from it.

Read first:
- `contracts/governance/ArmadaToken.sol` (the whole file, 226 lines). It is the base this
  chunk edits.
- `labbook/2026-10-18-treasury-governance-baal-safe-shielded.md` §3, decisions 3, 4, and 5.
- `labbook/2026-10-18-treasury-governance-baal-safe-shielded.md` §4, the G1 check.

## Goal

`ArmadaToken` becomes the Baal shares token itself, with no mint after construction, no
upgrade path, and a transfer allowlist that RevenueLock, the Hedgey lockup, and the
crowdfund can join before transfers open to the public.

## Deliver

- **S1 · Keep the fixed supply, drop no code.** `ArmadaToken.sol:13` already sets
  `INITIAL_SUPPLY = 12_000_000 * 1e18` and the constructor at line 68 mints it once, with
  no other `_mint` call in the file. Add a forge test that calls `_mint` is unreachable:
  no public or external function on `ArmadaToken` triggers a second mint. State this as a
  source-level assertion, the same style as E16 S6 in armada-nitro
  (`docs/tasks/E16-adjudicator-hardening.md` S6): grep the file for `_mint(` and assert
  exactly one call site, the constructor.
- **S2 · Confirm non-upgradeability.** `ArmadaToken` already inherits only `ERC20Votes`
  (`ArmadaToken.sol:6,12`), no `Initializable`, no `UUPSUpgradeable`, no proxy pattern.
  Add a test that deploys `ArmadaToken` directly (`new ArmadaToken(...)`) and asserts its
  `extcodehash` is immutable code, not a proxy: no `delegatecall` opcode in its runtime
  bytecode (use `vm.getCode` plus a bytecode scan, or assert the contract has no
  `_authorizeUpgrade`-style selector).
- **S3 · The transfer allowlist already exists.** `ArmadaToken.sol:40`
  (`transferWhitelist`), `:80-89` (`initWhitelist`, deployer-only, one-shot),
  `:131-137` (`addToWhitelist`, timelock-only, add-only). Add three beneficiary-shaped
  addresses to a forge test fixture (stand-ins for RevenueLock, Hedgey lockup, and
  crowdfund, since G2–G5 deploy the real contracts later): confirm `initWhitelist` adds
  them, confirm `addToWhitelist` by the timelock adds a fourth address after deployment,
  confirm a non-timelock caller reverts.
- **S4 · `_beforeTokenTransfer` already blocks all non-whitelisted transfers while
  `transferable` is false** (`ArmadaToken.sol:211-216`). Add a test that a transfer from a
  non-whitelisted holder reverts with `"ArmadaToken: transfers restricted"`, and that a
  mint (`from == address(0)`) is not blocked.
- **S5 · `setTransferable` already restricts the caller to `windDownContract` or
  `timelock`** (`ArmadaToken.sol:165-171`). G6 removes `ArmadaWindDown`. Add a test that
  the timelock alone can call `setTransferable(true)` once `windDownContract` is never
  set (its default value is `address(0)`, which no test or deploy script may call). State
  explicitly in the test comment that G6 deletes `ArmadaWindDown` and nothing in this
  chunk may depend on it existing.
- **S6 · No new contract code is required for S1–S5.** If a test in S1–S5 fails against
  the current `ArmadaToken.sol`, stop and report the exact failing assertion instead of
  editing the contract to make it pass — the labbook's decisions 3, 4, and 5 describe code
  that `armada-poc` `60a2f05` already has.

## Conventions to keep

Match `test-foundry/ArmadaTokenDelegateOnBehalf.t.sol`'s setup pattern (deploy
`ArmadaToken` with a timelock stand-in, `initWhitelist` with a stand-in holder). Name the
new test file `test-foundry/ArmadaTokenShares.t.sol`. Use `forge fmt` conventions already
in the file (no changes to indentation or import order elsewhere).

## Acceptance (paste output)

`forge test --match-path test-foundry/ArmadaTokenShares.t.sol -vv`, with six tests, each
failing on `60a2f05` for the stated reason before any contract edit (if any edit proves
necessary) and passing after:
1. exactly one `_mint` call site (S1);
2. the deployed bytecode is non-proxy (S2);
3. `initWhitelist` and `addToWhitelist` gate correctly (S3);
4. a non-whitelisted transfer reverts (S4);
5. a mint is never blocked by the whitelist (S4);
6. `setTransferable` succeeds from the timelock with no `windDownContract` set (S5).

Plus: `forge test` for the existing suite still passes, unchanged.

## Husband review

Not audit-critical by the CHUNK-RULES list, but review: confirm no test in S1–S6 needed a
contract edit (if one did, the labbook's decisions 3–5 do not hold as written, and that is
an escalation, not a silent fix).

## Out of scope

`ArmadaToken.circulatingSupplyOf` (`:196-205`), `delegateOnBehalf`/`transferAndDelegate`
(`:173-194`), and `noDelegation` (`:44-46,218-225`): unchanged, used as-is by G4 and G5.
Deploying RevenueLock, the Hedgey lockup, or the crowdfund (G2–G5). Removing
`ArmadaWindDown` (G6).
