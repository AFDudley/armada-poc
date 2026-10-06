// ABOUTME: Top-level entry point for the interactive committer baseline — run ONLY inside the
// ABOUTME: isolated container (see docker/run.sh). Starts Anvil, asserts its identity, builds the
// ABOUTME: committer ONCE for the "live" (non-prelaunch, real manifest) config, then for each
// ABOUTME: scenario: fresh Anvil + deploy, swap the served deployment manifest, run that
// ABOUTME: scenario's UI-driven captures, repeat. Leaves `design-baseline/committer/` (or
// ABOUTME: `--out=<dir>`) holding every prelaunch/deploy-error/live-scenario capture.

import path from 'node:path'
import { fileURLToPath } from 'node:url'
import type { Browser } from '@playwright/test'
import { launchChromium } from './browser.ts'
import { runBuild, startPreview } from './proc.ts'
import { COMMITTER_WORKSPACE } from './targets/committer.ts'
import { startAnvil, stopAnvil, assertChainIdentity } from './anvil.ts'
import { deployCrowdfundScenario, readCrowdfundDeployment } from './chainPlan.ts'
import { writeManifestForBuild, writeManifestForPreview } from './manifest.ts'
import { runMainScenario } from './scenarios/main.ts'
import { runCanceledScenario } from './scenarios/canceled.ts'
import { runRefundScenario } from './scenarios/refund.ts'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.resolve(__dirname, '../../..')
const PREVIEW_PORT = 48813

interface Scenario {
  name: string
  run: (repoRoot: string, browser: Browser, previewUrl: string, outDir: string) => Promise<void>
}

const SCENARIOS: Scenario[] = [
  { name: 'main', run: runMainScenario },
  { name: 'canceled', run: runCanceledScenario },
  { name: 'refund', run: runRefundScenario },
]

interface CliArgs {
  outDir: string
  scenario: string | null
}

function parseArgs(argv: readonly string[]): CliArgs {
  let outDir = path.join(REPO_ROOT, 'design-baseline')
  let scenario: string | null = null
  for (const arg of argv) {
    if (arg.startsWith('--out=')) outDir = path.resolve(arg.slice('--out='.length))
    else if (arg.startsWith('--scenario=')) scenario = arg.slice('--scenario='.length)
  }
  return { outDir, scenario }
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2))
  const scenarios = args.scenario ? SCENARIOS.filter((s) => s.name === args.scenario) : SCENARIOS
  if (scenarios.length === 0) {
    throw new Error(`unknown --scenario=${args.scenario} (expected one of ${SCENARIOS.map((s) => s.name).join(', ')})`)
  }

  // Each scenario's `deployCrowdfundScenario()` call below overwrites exactly three files
  // (`deployments/{hub-v3,governance-hub,crowdfund-hub}.json` — the repo's own deploy scripts
  // `saveDeployment()` unconditionally, no guard) and nothing else in `deployments/`. Do NOT
  // `rm -rf` the directory here: it also holds COMMITTED Sepolia manifests this pipeline must
  // never touch.

  // ---- Deploy the FIRST scenario before the one committer build, so the build's baked-in
  // ---- public/api/deployments/crowdfund-hub.json is well-formed (content doesn't matter beyond
  // ---- that — every scenario after the first overwrites dist/'s copy directly, see manifest.ts).
  const anvilForBuild = await startAnvil()
  await assertChainIdentity()
  deployCrowdfundScenario(REPO_ROOT)
  writeManifestForBuild(REPO_ROOT, readCrowdfundDeployment(REPO_ROOT))
  await stopAnvil(anvilForBuild)

  console.log('[orchestrate] building committer (live config, local network)...')
  runBuild(REPO_ROOT, COMMITTER_WORKSPACE, {
    VITE_NETWORK: 'local',
    VITE_WALLETCONNECT_PROJECT_ID: 'design-baseline-placeholder',
  })

  const server = await startPreview(REPO_ROOT, COMMITTER_WORKSPACE, PREVIEW_PORT)
  const previewUrl = `http://127.0.0.1:${server.port}`
  const browser = await launchChromium()

  try {
    for (const scenario of scenarios) {
      console.log(`\n=== scenario: ${scenario.name} ===`)
      const anvil = await startAnvil()
      try {
        await assertChainIdentity()
        deployCrowdfundScenario(REPO_ROOT)
        writeManifestForPreview(REPO_ROOT, readCrowdfundDeployment(REPO_ROOT))
        await scenario.run(REPO_ROOT, browser, previewUrl, path.join(args.outDir, 'committer'))
      } finally {
        await stopAnvil(anvil)
      }
    }
  } finally {
    await browser.close()
    await server.stop()
  }

  console.log(`\ndone — interactive committer captures written under ${path.join(args.outDir, 'committer')}`)
}

main().catch((err) => {
  console.error(err)
  process.exitCode = 1
})

