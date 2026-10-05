// ABOUTME: CLI entry point — builds+previews the committer and/or showcase targets and
// ABOUTME: captures every defined state×viewport into design-baseline/<target>/.

import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { launchChromium } from './browser.ts'
import { runBuild, startPreview } from './proc.ts'
import { gotoFrozen, freezeMotion } from './freeze.ts'
import { captureState } from './capture.ts'
import { COMMITTER_WORKSPACE, COMMITTER_STATES } from './targets/committer.ts'
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

async function captureCommitter(outDir: string): Promise<number> {
  const browser = await launchChromium()
  let total = 0
  try {
    for (const state of COMMITTER_STATES) {
      console.log(`[committer] building "${state.name}" (${JSON.stringify(state.env)})`)
      runBuild(REPO_ROOT, COMMITTER_WORKSPACE, state.env)

      const server = await startPreview(REPO_ROOT, COMMITTER_WORKSPACE, COMMITTER_PORT)
      try {
        const context = await browser.newContext()
        const page = await context.newPage()
        await freezeMotion(page)
        await gotoFrozen(page, `http://127.0.0.1:${server.port}${state.path}`)

        for (const viewport of state.viewports) {
          const result = await captureState(page, path.join(outDir, 'committer'), state.name, viewport)
          console.log(`[committer] ${state.name}@${viewport.id} — ${result.elementCount} elements`)
          total += 1
        }
        await context.close()
      } finally {
        await server.stop()
      }
    }
  } finally {
    await browser.close()
  }
  return total
}

async function captureShowcase(outDir: string): Promise<number> {
  const browser = await launchChromium()
  let total = 0
  runBuild(REPO_ROOT, SHOWCASE_WORKSPACE, {})
  const server = await startPreview(REPO_ROOT, SHOWCASE_WORKSPACE, SHOWCASE_PORT)
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
        total += 1
      }
      await context.close()
    }
  } finally {
    await server.stop()
    await browser.close()
  }
  return total
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2))
  let total = 0
  if (args.target === 'all' || args.target === 'committer') {
    total += await captureCommitter(args.outDir)
  }
  if (args.target === 'all' || args.target === 'showcase') {
    total += await captureShowcase(args.outDir)
  }
  console.log(`\ndone — ${total} state×viewport captures written under ${args.outDir}`)
}

main().catch((err) => {
  console.error(err)
  process.exitCode = 1
})
