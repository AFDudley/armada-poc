Chunk P3 · Family F1 · Points 6 · Route 5090
Depends on: P2a, P2b, P4

Repo: `armada-poc`. Branch: `integrated` (work in a `task/P3` branch cut from `integrated`, once P2a, P2b and P4
merge).

Read `contracts/privacy-pool/PrivacyPool.sol` (the whole file: `constructor`, `initialize`, the `deployer`
immutable), `contracts/privacy-pool/storage/PrivacyPoolStorage.sol` (the `owner`/module-address fields, the
"modules below are immutable — there is deliberately no setter" comment), `scripts/deploy_privacy_pool.ts` (the
whole `deployHub` function), and the armada-laconic lab book
`labbook/2026-10-18-contract-owned-notes-and-zk-channel-apps.md` §3 decisions 7, 8 and §6 ("who holds the proxy
admin").

## What this chunk is not
`PrivacyPool.sol` is already not a proxy. It has no `upgradeTo`, no `delegatecall` to an implementation slot for
its own logic, and a `constructor` that pins an immutable `deployer` used only to gate the one-time `initialize`
call (`PrivacyPool.sol` lines 44–49, 92–99). The four module addresses (`shieldModule`, `transactModule`,
`merkleModule`, `verifierModule`) are set once in `initialize` and have no setter (`PrivacyPoolStorage.sol`'s own
comment: "the four module addresses below are set once ... and are INTENTIONALLY IMMUTABLE"). `owner` is likewise
set once in `initialize` with no `transferOwnership`/`setOwner` anywhere in `grep -rn "setOwner\|transferOwnership"
contracts/privacy-pool/`. This chunk's job is to pin down and verify what already holds, name the one real gap
(the `VerifierModule` key-setter authority, decision 8), and add the deploy script and tests that prove it.

## Goal
The deployment the lab book requires — constructor-set keys, no proxy, deploy script, with the `owner` key held by
an address the Baal DAO cannot reach (decision 8: "the vkey setter must not be an authority the Baal DAO can
reach, because a swapped verifying key drains every pool user's funds") — is verified by a test and a deploy script
that cannot silently point `owner` at governance.

## Deliver
- **S1 · Verify no proxy, by test, not by reading.** Add `test/NonUpgradeable.t.sol`: deploy `PrivacyPool` fresh,
  assert `address(privacyPool).code` contains no `DELEGATECALL`-to-storage-slot pattern is not testable directly in
  Solidity — instead assert behaviorally: calling `initialize` twice reverts (`"PrivacyPool: Already initialized"`,
  already covered if an existing test does this — grep first and extend rather than duplicate), and that no
  function selector matching `upgradeTo(address)` or `upgradeToAndCall(address,bytes)` exists on the contract (a
  low-level call to those 4-byte selectors reverts with no function found, same pattern N1a's brief uses for a
  removed selector).
- **S2 · Owner is not a governance address, by test.** `test/NonUpgradeable.t.sol` also asserts: `PrivacyPool`
  exposes no path from any `ArmadaGovernor`/`ArmadaTreasuryGov`/Baal-style timelock address to a call that could
  reach `VerifierModule.setVerificationKey` (`owner` is a single EOA or Safe multisig address, checked by
  `msg.sender == owner` with no delegate/forwarder indirection — read `VerifierModule.sol` lines 34–42 again to
  confirm the check is direct). This is a structural assertion (the deploy script's `owner` argument, S3, is never
  a governance contract address), not a new contract mechanism — state in the report that the real guarantee is
  operational (which key `scripts/deploy_privacy_pool.ts` passes as `owner`), and the test only catches a future
  code change that adds a second path to `setVerificationKey`.
- **S3 · Deploy script asserts its own invariant.** In `scripts/deploy_privacy_pool.ts`'s `deployHub` (after the
  `initialize` call, around line 254), add a check: if the resolved `owner` address being passed to `initialize`
  equals any of the governance deployment's known contract addresses (`govDeployment.contracts.governor`,
  `.treasuryGov`, `.windDown` — read `scripts/deploy_governance.ts`'s saved deployment shape to get the exact
  field names), throw before sending the transaction, with a message naming which governance address collided.
  Resolve `owner` the same way the script already resolves `treasuryAddress` (env var override, else deployer,
  local only) — add an `OWNER_ADDRESS` env var read, refused on mainnet with no override per
  `getNetworkConfig()`'s existing pattern for `treasuryAddress`.
- **S4 · Deploy script documents the guarantee.** One comment block above the `initialize` call in
  `deploy_privacy_pool.ts`, citing this chunk and the lab book decision, stating plainly: "owner" is a single key
  or Safe multisig, never upgraded, never set to a DAO-governed contract.

Keep existing conventions: the script's existing `nm.override()` nonce-manager pattern for every transaction; no
new proxy library import.

## Acceptance (paste output)
`forge test --match-contract NonUpgradeableTest` output for S1 and S2's tests, each failing on the commit before
this task (file does not exist, counts as failing) and passing after.

Plus: a fixturenet deploy run, `npx hardhat run scripts/deploy_privacy_pool.ts --network hub`, with S3's check
present and passing (no governance-address collision on the current fixturenet governance deployment), pasted
output showing the new log line from S4/S3.

## Husband review
Audit-critical. Check:
- the `owner` address the deploy script actually uses on the fixturenet, Sepolia and any mainnet rehearsal config
  is a key or Safe the team controls directly, never a Baal/governance contract (confirm by reading the resolved
  address in the deploy output, not by trusting S3's check alone — S3 only catches a known governance address, not
  an unknown future one);
- S1/S2's tests do not give a false sense of "immutable forever": `VerifierModule.setVerificationKey` remains
  owner-callable by design (issue #349, cited in `PrivacyPoolStorage.sol`'s own comment) — this chunk pins who
  holds that key, it does not remove the capability.

## Out of scope
Any change to module logic (P1, P2a, P2b); the Phase-2 ceremony (P4); a governance-controlled, timelocked
key-rotation path for `owner` (if ever wanted, it is new scope, not this chunk's).

## Handoff
Moves `armada-laconic/notes/handoff-2026-10-20.md` §0.4, row "F1 pool", chunk P3.
