// ABOUTME: Spawns/stops the in-container Anvil instance used by every interactive-baseline
// ABOUTME: scenario, and asserts its chain identity before any deploy touches it — the hard
// ABOUTME: safety check the task brief requires ("assert eth_chainId === 31337 AND
// ABOUTME: web3_clientVersion contains 'anvil', abort otherwise").

import { spawn, type ChildProcess } from 'node:child_process'

export const ANVIL_RPC_URL = 'http://127.0.0.1:8545'
// No `--mnemonic`/`--mnemonic-seed-unsafe` flag is passed below — Anvil's own built-in default
// (used whenever neither flag is given) deterministically derives the SAME well-known test
// accounts every start (account 0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266), which is exactly
// the account `config/local.env`'s committed `DEPLOYER_PRIVATE_KEY` controls — the repo's own
// deploy scripts (`source config/local.env && npm run deploy:*`, reused verbatim by chainPlan.ts)
// need that account funded to pay gas. This tool never writes a mnemonic phrase or private key of
// its own anywhere; `getAccounts()` below reads whichever addresses Anvil generated back via
// `eth_accounts` rather than deriving or duplicating them.
// Fixed genesis block timestamp — 2023-11-14T22:13:20Z. Any value works (nothing anchors to a
// real calendar date); fixing it means the FIRST block's timestamp doesn't depend on wall-clock
// time at anvil startup, and every subsequent block's timestamp (auto-mine assigns
// `max(parent+1, now)`, so it increments by exactly the deploy/commit tx count when mined faster
// than 1 real second apart, which local Anvil always is) is then a deterministic function of how
// many transactions this pipeline sends — not of when it happened to run. See README.md
// "Determinism" for the one thing this does NOT cover (the device-clock-anchored countdown text).
export const ANVIL_GENESIS_TIMESTAMP = 1_700_000_000
export const ANVIL_ACCOUNT_COUNT = 200

function delay(ms: number): Promise<void> {
  const { promise, resolve } = Promise.withResolvers<void>()
  setTimeout(resolve, ms)
  return promise
}

async function rpc(method: string, params: unknown[] = []): Promise<unknown> {
  const res = await fetch(ANVIL_RPC_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  })
  const json = (await res.json()) as { result?: unknown; error?: { message: string } }
  if (json.error) throw new Error(`${method} failed: ${json.error.message}`)
  return json.result
}

/**
 * Starts anvil bound to 127.0.0.1:8545 INSIDE this process's network namespace (the container —
 * see docker/run.sh, which never publishes a port and never uses --network host, so there is no
 * route from here to the host's 8545, which is owned by an unrelated fixturenet).
 */
export async function startAnvil(): Promise<ChildProcess> {
  const child = spawn(
    'anvil',
    [
      '--host', '127.0.0.1',
      '--port', '8545',
      '--chain-id', '31337',
      '--accounts', String(ANVIL_ACCOUNT_COUNT),
      '--balance', '10000',
      '--timestamp', String(ANVIL_GENESIS_TIMESTAMP),
      // Deterministic ordering + no interactive banners.
      '--order', 'fifo',
      '--silent',
    ],
    { stdio: ['ignore', 'pipe', 'pipe'] },
  )
  let out = ''
  child.stdout?.on('data', (d) => (out += String(d)))
  child.stderr?.on('data', (d) => (out += String(d)))

  const deadline = Date.now() + 30_000
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`anvil exited (code ${child.exitCode}) before coming up:\n${out}`)
    }
    try {
      await rpc('eth_chainId')
      return child
    } catch {
      await delay(200)
    }
  }
  child.kill('SIGKILL')
  throw new Error(`anvil did not come up within 30s:\n${out}`)
}

export async function stopAnvil(child: ChildProcess): Promise<void> {
  child.kill('SIGTERM')
  await delay(150)
  if (child.exitCode === null) child.kill('SIGKILL')
}

/**
 * Hard safety gate (task brief, "Hard constraints"): before ANY deploy transaction, confirm
 * `http://127.0.0.1:8545` inside THIS process is really our own freshly-started Anvil — not some
 * other process that happened to answer on the port. Aborts the whole pipeline otherwise.
 */
export async function assertChainIdentity(): Promise<{ chainId: string; clientVersion: string }> {
  const chainId = await rpc('eth_chainId')
  const clientVersion = await rpc('web3_clientVersion')
  if (chainId !== '0x7a69') {
    throw new Error(`REFUSING TO CONTINUE: eth_chainId returned ${String(chainId)}, expected 0x7a69 (31337)`)
  }
  if (typeof clientVersion !== 'string' || !clientVersion.toLowerCase().includes('anvil')) {
    throw new Error(`REFUSING TO CONTINUE: web3_clientVersion returned ${String(clientVersion)}, expected to contain "anvil"`)
  }
  console.log(`[anvil] identity confirmed — chainId=${chainId} clientVersion=${clientVersion}`)
  return { chainId, clientVersion }
}

/** Returns Anvil's mnemonic-derived account addresses in index order (account 0 first) — reused
 *  instead of deriving them from the mnemonic ourselves (no `ethers` dependency needed in this
 *  tool's own `package.json`; Anvil already knows its own derivation). */
export async function getAccounts(): Promise<string[]> {
  const result = await rpc('eth_accounts')
  return result as string[]
}
