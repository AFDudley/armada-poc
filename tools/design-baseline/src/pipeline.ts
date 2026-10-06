// ABOUTME: Single entry point for `docker/run.sh` — regenerates every chain-free capture
// ABOUTME: (committer prelaunch/deploy-error, showcase) AND every interactive capture (main/
// ABOUTME: canceled/refund scenarios) in one command, then writes a timestamped run record
// ABOUTME: (design-baseline/runs/<UTC-timestamp>/summary.json) describing exactly what happened.

import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { mkdirSync, writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { captureCommitter, captureShowcase } from './run.ts'
import { runInteractive } from './orchestrate.ts'
import type { CaptureResult } from './capture.ts'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.resolve(__dirname, '../../..')

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

function gitHead(): string {
  try {
    return execFileSync('git', ['rev-parse', 'HEAD'], { cwd: REPO_ROOT, encoding: 'utf-8' }).trim()
  } catch {
    return 'unknown'
  }
}

interface StateSummary {
  state: string
  viewports: string[]
  elementCounts: Record<string, number>
}

function summarizeByState(results: readonly CaptureResult[]): StateSummary[] {
  const byState: Record<string, StateSummary> = {}
  for (const r of results) {
    let entry = byState[r.state]
    if (!entry) {
      entry = { state: r.state, viewports: [], elementCounts: {} }
      byState[r.state] = entry
    }
    entry.viewports.push(r.viewport)
    entry.elementCounts[r.viewport] = r.elementCount
  }
  return Object.values(byState)
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2))
  const startedAt = new Date()
  const runTimestamp = process.env.DESIGN_BASELINE_RUN_TIMESTAMP ?? startedAt.toISOString().replace(/[:.]/g, '-')
  const runDir =
    process.env.DESIGN_BASELINE_RUN_DIR ?? path.join(REPO_ROOT, 'design-baseline', 'runs', runTimestamp)
  mkdirSync(runDir, { recursive: true })

  const summary: {
    runTimestamp: string
    startedAt: string
    finishedAt: string | null
    durationMs: number | null
    gitHead: string
    dockerImageId: string | null
    scenarioFilter: string | null
    outDir: string
    anvilIdentity: { chainId: string; clientVersion: string } | null
    chainFree: { target: string; states: StateSummary[]; pass: boolean; error: string | null }[]
    interactive: { scenariosRun: string[]; states: StateSummary[]; pass: boolean; error: string | null }
    totalCaptures: number
  } = {
    runTimestamp,
    startedAt: startedAt.toISOString(),
    finishedAt: null,
    durationMs: null,
    gitHead: gitHead(),
    dockerImageId: process.env.DESIGN_BASELINE_IMAGE_ID ?? null,
    scenarioFilter: args.scenario,
    outDir: args.outDir,
    anvilIdentity: null,
    chainFree: [],
    interactive: { scenariosRun: [], states: [], pass: false, error: null },
    totalCaptures: 0,
  }

  // ---- Chain-free captures (committer prelaunch/deploy-error, showcase) — no Anvil needed ------
  // Skipped entirely under --scenario=<name> (a chain scenario debugging run; chain-free output
  // is unaffected by scenario choice and re-running it every debug iteration wastes minutes).
  if (!args.scenario) {
    for (const [targetName, captureFn] of [
      ['committer', captureCommitter],
      ['showcase', captureShowcase],
    ] as const) {
      try {
        const results = await captureFn(REPO_ROOT, args.outDir)
        summary.chainFree.push({ target: targetName, states: summarizeByState(results), pass: true, error: null })
        summary.totalCaptures += results.length
      } catch (err) {
        summary.chainFree.push({ target: targetName, states: [], pass: false, error: String(err) })
      }
    }
  }

  // ---- Interactive captures (main/canceled/refund scenarios) — fresh Anvil + real deploy -------
  try {
    const interactiveResult = await runInteractive(REPO_ROOT, args.outDir, args.scenario)
    summary.anvilIdentity = interactiveResult.anvilIdentity
    summary.interactive = {
      scenariosRun: interactiveResult.scenariosRun,
      states: summarizeByState(interactiveResult.results),
      pass: true,
      error: null,
    }
    summary.totalCaptures += interactiveResult.results.length
  } catch (err) {
    summary.interactive = { scenariosRun: [], states: [], pass: false, error: String(err) }
  }

  const finishedAt = new Date()
  summary.finishedAt = finishedAt.toISOString()
  summary.durationMs = finishedAt.getTime() - startedAt.getTime()

  writeFileSync(path.join(runDir, 'summary.json'), JSON.stringify(summary, null, 2))
  console.log(`\n[pipeline] run record written to ${path.join(runDir, 'summary.json')}`)
  console.log(`[pipeline] ${summary.totalCaptures} total state×viewport captures in ${summary.durationMs}ms`)

  const failed = [...summary.chainFree.filter((c) => !c.pass), !summary.interactive.pass ? summary.interactive : null].filter(
    Boolean,
  )
  if (failed.length > 0) {
    console.error(`[pipeline] ${failed.length} phase(s) failed — see summary.json for details`)
    process.exitCode = 1
  }
}

main().catch((err) => {
  console.error(err)
  process.exitCode = 1
})
