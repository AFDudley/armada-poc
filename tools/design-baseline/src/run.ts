// ABOUTME: Chain-free capture driver — builds+previews the committer and/or showcase targets and
// ABOUTME: captures every defined state×viewport into design-baseline/<target>/. `captureCommitter`
// ABOUTME: / `captureShowcase` are the reusable entry points (used by pipeline.ts for the single
// ABOUTME: documented `docker/run.sh` command); `main()` below is a thin CLI wrapper for standalone
// ABOUTME: regeneration (`npx tsx src/run.ts`).

import path from 'node:path'
import { rmSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { launchChromium } from './browser.ts'
import { runBuild, startPreview } from './proc.ts'
import { gotoFrozen, freezeMotion } from './freeze.ts'
import { captureState, type CaptureResult } from './capture.ts'
import { COMMITTER_DIR, COMMITTER_WORKSPACE, COMMITTER_STATES } from './targets/committer.ts'
import { SHOWCASE_WORKSPACE, SHOWCASE_STATES } from './targets/showcase.ts'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.resolve(__dirname, '../../..')

const COMMITTER_PORT = 48811
const SHOWCASE_PORT = 48812

interface CliArgs {
  target: 'all' | 'committer' | 'showcase'
  outDir: string
}

function parseArgs(argv: readonly string[]): CliArgs {
  let target: CliArgs['target'] = 'all'
  let outDir = path.join(REPO_ROOT, 'design-baseline')
  for (const arg of argv) {
    if (arg.startsWith('--target=')) {
      const value = arg.slice('--target='.length)
      if (value === 'committer' || value === 'showcase' || value === 'all') target = value
      else throw new Error(`unknown --target=${value} (expected committer|showcase|all)`)
    } else if (arg.startsWith('--out=')) {
      outDir = path.resolve(arg.slice('--out='.length))
    }
  }
  return { target, outDir }
}

/** Builds + captures both chain-free committer states (`prelaunch`, `deploy-error`) into
 *  `outDir/committer/`. Returns one result per state×viewport. */
export async function captureCommitter(repoRoot: string, outDir: string): Promise<CaptureResult[]> {
  const browser = await launchChromium()
  const results: CaptureResult[] = []
  try {
    // Neither chain-free state should ever see a deployment manifest — `deploy-error` depends on
    // its absence (that's the whole point of the state) and `prelaunch` never reads it either way.
    // A stale `public/api/deployments/crowdfund-hub.json` can persist on disk from an EARLIER
    // interactive run (`writeManifestForBuild` in manifest.ts, not gitignored, not host-cleaned)
    // and would otherwise make `deploy-error`'s build non-deterministic across runs/hosts — so
    // remove it unconditionally before either chain-free build.
    rmSync(path.join(repoRoot, COMMITTER_DIR, 'public', 'api', 'deployments'), { recursive: true, force: true })
    for (const state of COMMITTER_STATES) {
      console.log(`[committer] building "${state.name}" (${JSON.stringify(state.env)})`)
      runBuild(repoRoot, COMMITTER_WORKSPACE, state.env)

      const server = await startPreview(repoRoot, COMMITTER_WORKSPACE, COMMITTER_PORT)
      try {
        const context = await browser.newContext()
        const page = await context.newPage()
        await freezeMotion(page)
        await gotoFrozen(page, `http://127.0.0.1:${server.port}${state.path}`)

        for (const viewport of state.viewports) {
          const result = await captureState(page, path.join(outDir, 'committer'), state.name, viewport)
          console.log(`[committer] ${state.name}@${viewport.id} — ${result.elementCount} elements`)
          results.push(result)
        }
        await context.close()
      } finally {
        await server.stop()
      }
    }
  } finally {
    await browser.close()
  }
  return results
}

/** Builds + captures every showcase layout/interaction state into `outDir/showcase/`. Returns
 *  one result per state×viewport. */
export async function captureShowcase(repoRoot: string, outDir: string): Promise<CaptureResult[]> {
  const browser = await launchChromium()
  const results: CaptureResult[] = []
  runBuild(repoRoot, SHOWCASE_WORKSPACE, {})
  const server = await startPreview(repoRoot, SHOWCASE_WORKSPACE, SHOWCASE_PORT)
  try {
    for (const state of SHOWCASE_STATES) {
      const context = await browser.newContext()
      const page = await context.newPage()
      await freezeMotion(page)
      await gotoFrozen(page, `http://127.0.0.1:${server.port}/`)

      for (const viewport of state.viewports) {
        const result = await captureState(
          page,
          path.join(outDir, 'showcase'),
          state.name,
          viewport,
          state.prepare,
        )
        console.log(`[showcase] ${state.name}@${viewport.id} — ${result.elementCount} elements`)
        results.push(result)
      }
      await context.close()
    }
  } finally {
    await server.stop()
    await browser.close()
  }
  return results
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2))
  let total = 0
  if (args.target === 'all' || args.target === 'committer') {
    total += (await captureCommitter(REPO_ROOT, args.outDir)).length
  }
  if (args.target === 'all' || args.target === 'showcase') {
    total += (await captureShowcase(REPO_ROOT, args.outDir)).length
  }
  console.log(`\ndone — ${total} state×viewport captures written under ${args.outDir}`)
}

// Only run the CLI wrapper when this module is the direct entry point — pipeline.ts imports
// `captureCommitter`/`captureShowcase` without wanting this to fire.
if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(err)
    process.exitCode = 1
  })
}
