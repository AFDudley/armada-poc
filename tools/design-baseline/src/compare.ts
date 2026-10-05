// ABOUTME: Equivalence-compare CLI — diffs two baseline directory trees (same
// ABOUTME: <target>/<state>@<width>.json layout) and exits non-zero on any difference.

import { readFile, readdir } from 'node:fs/promises'
import path from 'node:path'

interface ElementRecord {
  path: string
  rect: { x: number; y: number; width: number; height: number }
  styles: Record<string, string>
}

interface BaselineFile {
  state: string
  viewport: { id: string; width: number; height: number }
  elementCount: number
  elements: ElementRecord[]
}

async function listJsonFiles(dir: string): Promise<string[]> {
  const out: string[] = []
  let entries: string[]
  try {
    entries = await readdir(dir, { recursive: true } as { recursive: true } & Record<string, never>)
  } catch {
    return out
  }
  for (const entry of entries) {
    if (entry.endsWith('.json')) out.push(entry)
  }
  return out.sort()
}

function diffElement(a: ElementRecord, b: ElementRecord, prefix: string): string[] {
  const diffs: string[] = []
  const rectKeys = ['x', 'y', 'width', 'height'] as const
  for (const key of rectKeys) {
    if (a.rect[key] !== b.rect[key]) {
      diffs.push(`${prefix} rect.${key}: ${a.rect[key]} -> ${b.rect[key]}`)
    }
  }
  const keys = new Set([...Object.keys(a.styles), ...Object.keys(b.styles)])
  for (const key of Array.from(keys).sort()) {
    const av = a.styles[key]
    const bv = b.styles[key]
    if (av !== bv) {
      diffs.push(`${prefix} styles.${key}: ${JSON.stringify(av)} -> ${JSON.stringify(bv)}`)
    }
  }
  return diffs
}

function diffFile(a: BaselineFile, b: BaselineFile, relPath: string): string[] {
  const diffs: string[] = []
  const aByPath = new Map(a.elements.map((el) => [el.path, el]))
  const bByPath = new Map(b.elements.map((el) => [el.path, el]))
  const allPaths = new Set([...aByPath.keys(), ...bByPath.keys()])

  for (const elPath of Array.from(allPaths).sort()) {
    const aEl = aByPath.get(elPath)
    const bEl = bByPath.get(elPath)
    if (!aEl) {
      diffs.push(`${relPath}: + element only in B: ${elPath}`)
      continue
    }
    if (!bEl) {
      diffs.push(`${relPath}: - element only in A: ${elPath}`)
      continue
    }
    diffs.push(...diffElement(aEl, bEl, `${relPath} [${elPath}]`))
  }
  return diffs
}

async function compareDirs(dirA: string, dirB: string): Promise<string[]> {
  const filesA = new Set(await listJsonFiles(dirA))
  const filesB = new Set(await listJsonFiles(dirB))
  const allFiles = new Set([...filesA, ...filesB])
  const diffs: string[] = []

  for (const rel of Array.from(allFiles).sort()) {
    if (!filesA.has(rel)) {
      diffs.push(`+ file only in B: ${rel}`)
      continue
    }
    if (!filesB.has(rel)) {
      diffs.push(`- file only in A: ${rel}`)
      continue
    }
    const a = JSON.parse(await readFile(path.join(dirA, rel), 'utf-8')) as BaselineFile
    const b = JSON.parse(await readFile(path.join(dirB, rel), 'utf-8')) as BaselineFile
    diffs.push(...diffFile(a, b, rel))
  }
  return diffs
}

async function main(): Promise<void> {
  const [dirA, dirB] = process.argv.slice(2)
  if (!dirA || !dirB) {
    console.error('usage: tsx src/compare.ts <baseline-dir-a> <baseline-dir-b>')
    process.exit(2)
  }
  const diffs = await compareDirs(path.resolve(dirA), path.resolve(dirB))
  if (diffs.length === 0) {
    console.log(`identical — no differences between ${dirA} and ${dirB}`)
    return
  }
  console.log(`${diffs.length} difference(s) between ${dirA} and ${dirB}:\n`)
  for (const d of diffs) console.log(d)
  process.exitCode = 1
}

main().catch((err) => {
  console.error(err)
  process.exitCode = 1
})
