// ABOUTME: Vocabulary report — collects every distinct captured style value across the
// ABOUTME: baseline, resolves @armada/ui's tokens.css (dark theme) in a real browser, and
// ABOUTME: matches each observed value to a token (or flags it unmatched). Writes
// ABOUTME: design-baseline/VOCABULARY.md + vocabulary.json.

import { readFile, readdir, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { launchChromium } from './browser.ts'
import { VIEWPORTS, SHORT_HEIGHT_VIEWPORT } from './breakpoints.ts'
import { stableStringify } from './stableJson.ts'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.resolve(__dirname, '../../..')
const TOKENS_CSS_PATH = path.join(REPO_ROOT, 'packages/ui/src/styles/tokens.css')
const ARMADA_TOKENS_JSON_PATH = path.join(REPO_ROOT, 'packages/ui/src/tokens/armada-tokens.json')
const BASELINE_DIR = path.join(REPO_ROOT, 'design-baseline')

interface TokenEntry {
  name: string
  rawValue: string
}

interface ResolvedToken extends TokenEntry {
  /** Values this token could textually match an observed computed-style value
   *  against (a token can resolve to more than one comparable string — e.g. a
   *  unitless number is tried both bare and as `<n>px`). */
  candidates: string[]
}

interface ElementRecord {
  path: string
  styles: Record<string, string>
}

interface BaselineFile {
  state: string
  viewport: { id: string; width: number; height: number }
  elements: ElementRecord[]
}

// --- tokens.css extraction -----------------------------------------------

/** Pulls the flat `--name: value;` declarations out of the `[data-theme="dark"]`
 *  block. Dark is the only theme either capture target ever applies (showcase
 *  pins `data-theme="dark"` in index.html; the committer forces it at runtime
 *  and never toggles) — see design-baseline/README.md "Light theme". */
function extractDarkThemeTokens(cssText: string): TokenEntry[] {
  const blockMatch = /\[data-theme="dark"\]\s*{([^}]*)}/s.exec(cssText)
  if (!blockMatch) throw new Error('could not find [data-theme="dark"] block in tokens.css')
  const block = blockMatch[1]!
  const entries: TokenEntry[] = []
  const declRe = /--([a-zA-Z0-9-]+):\s*([^;]+);/g
  let m: RegExpExecArray | null
  while ((m = declRe.exec(block)) !== null) {
    entries.push({ name: `--${m[1]}`, rawValue: m[2]!.trim() })
  }
  return entries
}

/** Resolves every token's `candidates` — the set of computed-style strings it
 *  could legitimately produce — by applying `var(--token)` to a disposable DOM
 *  element in a real browser and reading `getComputedStyle` back. This lets the
 *  browser do var()-chain resolution, `color-mix()`, and unit math instead of
 *  re-implementing a CSS value resolver by hand. */
async function resolveTokens(tokens: TokenEntry[]): Promise<ResolvedToken[]> {
  const cssText = await readFile(TOKENS_CSS_PATH, 'utf-8')
  const browser = await launchChromium()
  try {
    const page = await browser.newPage()
    await page.setContent('<!doctype html><html data-theme="dark"><body></body></html>')
    await page.addStyleTag({ content: cssText })

    const resolved = await page.evaluate((tokenList: TokenEntry[]) => {
      const out: { name: string; rawValue: string; candidates: string[] }[] = []
      for (const { name, rawValue } of tokenList) {
        const probe = document.createElement('div')
        probe.style.position = 'absolute'
        probe.style.visibility = 'hidden'
        probe.style.fontSize = '100px' // fixed context for em/% ratio tokens
        document.body.appendChild(probe)
        const candidates: string[] = []

        probe.style.setProperty('background-color', `var(${name})`)
        const bg = getComputedStyle(probe).backgroundColor
        if (bg && bg !== 'rgba(0, 0, 0, 0)') candidates.push(bg)

        probe.style.setProperty('color', `var(${name})`)
        const color = getComputedStyle(probe).color
        if (color) candidates.push(color)

        probe.style.setProperty('font-size', `calc(var(${name}) * 1px)`)
        const px = getComputedStyle(probe).fontSize
        if (px && px !== 'NaNpx') candidates.push(px)
        probe.style.fontSize = '100px'

        probe.style.setProperty('line-height', `var(${name})`)
        const lh = getComputedStyle(probe).lineHeight
        if (lh && lh !== 'normal') candidates.push(`ratio:${(parseFloat(lh) / 100).toFixed(4)}`)
        probe.style.lineHeight = ''

        probe.style.setProperty('letter-spacing', `var(${name})`)
        const ls = getComputedStyle(probe).letterSpacing
        if (ls && ls !== 'normal') candidates.push(`ratio:${(parseFloat(ls) / 100).toFixed(4)}`)
        probe.style.letterSpacing = ''

        candidates.push(rawValue)
        document.body.removeChild(probe)
        out.push({ name, rawValue, candidates: Array.from(new Set(candidates)) })
      }
      return out
    }, tokens)

    return resolved
  } finally {
    await browser.close()
  }
}

// --- observed-value aggregation from the baseline -------------------------

interface ObservedValue {
  value: string
  count: number
  states: Set<string>
}

interface Vocabulary {
  colors: Map<string, ObservedValue>
  fontTuples: Map<string, ObservedValue>
  spacing: Map<string, ObservedValue>
  radii: Map<string, ObservedValue>
  shadows: Map<string, ObservedValue>
}

const COLOR_PROPS = [
  'color', 'backgroundColor',
  'borderTopColor', 'borderRightColor', 'borderBottomColor', 'borderLeftColor',
  'outlineColor',
]
const SPACING_PROPS = [
  'marginTop', 'marginRight', 'marginBottom', 'marginLeft',
  'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
  'gap', 'rowGap', 'columnGap',
]
const RADIUS_PROPS = [
  'borderTopLeftRadius', 'borderTopRightRadius', 'borderBottomRightRadius', 'borderBottomLeftRadius',
]

function record(map: Map<string, ObservedValue>, value: string, state: string): void {
  if (!value || value === '0px' || value === 'none' || value === 'normal') return
  const existing = map.get(value)
  if (existing) {
    existing.count += 1
    existing.states.add(state)
  } else {
    map.set(value, { value, count: 1, states: new Set([state]) })
  }
}

async function listBaselineFiles(): Promise<string[]> {
  const out: string[] = []
  for (const target of ['committer', 'showcase']) {
    const dir = path.join(BASELINE_DIR, target)
    let entries: string[] = []
    try {
      entries = await readdir(dir)
    } catch {
      continue
    }
    for (const entry of entries) {
      if (entry.endsWith('.json')) out.push(path.join(dir, entry))
    }
  }
  return out.sort()
}

async function buildVocabulary(): Promise<Vocabulary> {
  const vocab: Vocabulary = {
    colors: new Map(),
    fontTuples: new Map(),
    spacing: new Map(),
    radii: new Map(),
    shadows: new Map(),
  }
  const files = await listBaselineFiles()
  for (const file of files) {
    const data = JSON.parse(await readFile(file, 'utf-8')) as BaselineFile
    const stateLabel = `${path.basename(path.dirname(file))}/${data.state}@${data.viewport.id}`
    for (const el of data.elements) {
      for (const prop of COLOR_PROPS) {
        const v = el.styles[prop]
        if (v) record(vocab.colors, v, stateLabel)
      }
      for (const prop of SPACING_PROPS) {
        const v = el.styles[prop]
        if (v) record(vocab.spacing, v, stateLabel)
      }
      for (const prop of RADIUS_PROPS) {
        const v = el.styles[prop]
        if (v) record(vocab.radii, v, stateLabel)
      }
      const shadow = el.styles['boxShadow']
      if (shadow) record(vocab.shadows, shadow, stateLabel)

      const fontSize = el.styles['fontSize']
      const fontFamily = el.styles['fontFamily']
      if (fontSize && fontFamily) {
        const tuple = [
          fontFamily,
          fontSize,
          el.styles['fontWeight'] ?? '',
          el.styles['lineHeight'] ?? '',
          el.styles['letterSpacing'] ?? '',
        ].join(' / ')
        record(vocab.fontTuples, tuple, stateLabel)
      }
    }
  }
  return vocab
}

// --- matching ---------------------------------------------------------------

function fontSizeLetterSpacingRatio(fontSize: string, letterSpacing: string): string | null {
  const fs = parseFloat(fontSize)
  const ls = parseFloat(letterSpacing)
  if (!Number.isFinite(fs) || fs === 0 || !Number.isFinite(ls)) return null
  return `ratio:${(ls / fs).toFixed(4)}`
}

function fontSizeLineHeightRatio(fontSize: string, lineHeight: string): string | null {
  const fs = parseFloat(fontSize)
  const lh = parseFloat(lineHeight)
  if (!Number.isFinite(fs) || fs === 0 || !Number.isFinite(lh)) return null
  return `ratio:${(lh / fs).toFixed(4)}`
}

function findMatch(value: string, tokens: ResolvedToken[]): string[] {
  const matches: string[] = []
  for (const token of tokens) {
    if (token.candidates.includes(value)) matches.push(token.name)
  }
  return matches
}

interface MatchedEntry {
  value: string
  count: number
  states: string[]
  matchedTokens: string[]
}

function matchMap(map: Map<string, ObservedValue>, tokens: ResolvedToken[]): MatchedEntry[] {
  return Array.from(map.values())
    .map((ov) => ({
      value: ov.value,
      count: ov.count,
      states: Array.from(ov.states).sort(),
      matchedTokens: findMatch(ov.value, tokens),
    }))
    .sort((a, b) => b.count - a.count || a.value.localeCompare(b.value))
}

/** Recursively counts Style-Dictionary/Token-Studio leaf tokens (objects with
 *  a `value` key) in armada-tokens.json — used only as an independent
 *  structural sanity count alongside the live-resolved tokens.css figure, so
 *  a drift between the two sources (CLAUDE.md: "keep armada-tokens.json in
 *  sync when editing tokens.css") is visible in the report. */
function countJsonLeafTokens(node: unknown): number {
  if (node === null || typeof node !== 'object') return 0
  const obj = node as Record<string, unknown>
  if ('value' in obj && 'type' in obj) return 1
  let total = 0
  for (const key of Object.keys(obj)) total += countJsonLeafTokens(obj[key])
  return total
}

// --- report -------------------------------------------------------------

function mdTable(rows: MatchedEntry[], valueLabel: string): string {
  const lines = [
    `| ${valueLabel} | Occurrences | States | Matched token(s) |`,
    '|---|---|---|---|',
  ]
  for (const row of rows) {
    const statesCell = row.states.length > 6
      ? `${row.states.slice(0, 6).join(', ')}, … (${row.states.length} total)`
      : row.states.join(', ')
    const matchCell = row.matchedTokens.length > 0 ? row.matchedTokens.join(', ') : '**UNMATCHED**'
    lines.push(`| \`${row.value}\` | ${row.count} | ${statesCell} | ${matchCell} |`)
  }
  return lines.join('\n')
}

async function main(): Promise<void> {
  const [cssText, tokensJsonText] = await Promise.all([
    readFile(TOKENS_CSS_PATH, 'utf-8'),
    readFile(ARMADA_TOKENS_JSON_PATH, 'utf-8'),
  ])
  const darkTokens = extractDarkThemeTokens(cssText)
  const jsonLeafCount = countJsonLeafTokens(JSON.parse(tokensJsonText))
  const resolved = await resolveTokens(darkTokens)
  const vocab = await buildVocabulary()

  // Font tuples need a bespoke matcher: compare the fontSize-normalized
  // letterSpacing/lineHeight ratios against ratio-kind token candidates,
  // and the fontSize/fontFamily/fontWeight components against their own
  // token kinds — rather than treating the whole tuple as one opaque string.
  const fontTupleRows: MatchedEntry[] = Array.from(vocab.fontTuples.values())
    .map((ov) => {
      const [fontFamily, fontSize, fontWeight, lineHeight, letterSpacing] = ov.value.split(' / ')
      const matched = new Set<string>()
      for (const candidate of [fontFamily, fontSize, fontWeight]) {
        if (!candidate) continue
        for (const m of findMatch(candidate, resolved)) matched.add(m)
      }
      const lhRatio = fontSizeLineHeightRatio(fontSize ?? '', lineHeight ?? '')
      if (lhRatio) for (const m of findMatch(lhRatio, resolved)) matched.add(m)
      const lsRatio = fontSizeLetterSpacingRatio(fontSize ?? '', letterSpacing ?? '')
      if (lsRatio) for (const m of findMatch(lsRatio, resolved)) matched.add(m)
      return {
        value: ov.value,
        count: ov.count,
        states: Array.from(ov.states).sort(),
        matchedTokens: Array.from(matched).sort(),
      }
    })
    .sort((a, b) => b.count - a.count || a.value.localeCompare(b.value))

  const colorRows = matchMap(vocab.colors, resolved)
  const spacingRows = matchMap(vocab.spacing, resolved)
  const radiusRows = matchMap(vocab.radii, resolved)
  // boxShadow is a composite value (offsets + blur + color); tokens.css has no
  // --*-shadow-* entries at all (checked: none exist), so every shadow is
  // unmatched by construction. Still reported so the gap is visible.
  const shadowRows = matchMap(vocab.shadows, resolved)

  const allRows = [...colorRows, ...fontTupleRows, ...spacingRows, ...radiusRows, ...shadowRows]
  const unmatchedCount = allRows.filter((r) => r.matchedTokens.length === 0).length

  const breakpointLines = [...VIEWPORTS, SHORT_HEIGHT_VIEWPORT]
    .map((v) => `- \`${v.width}×${v.height}\` (id \`${v.id}\`) — ${v.note}`)
    .join('\n')

  const md = `# VOCABULARY.md

Generated by \`tools/design-baseline/src/vocabulary.ts\`. Distinct computed-style
values observed across every captured committer + showcase state, matched
against \`@armada/ui\`'s \`[data-theme="dark"]\` tokens in \`packages/ui/src/styles/tokens.css\`
(the only theme either capture target ever applies — see README "Light theme").

Token resolution runs each token through a real browser (\`getComputedStyle\` on
a disposable element with \`var(--token)\` applied) rather than a hand-rolled CSS
parser, so \`var()\` chains, \`color-mix()\`, and the unitless-×1px convention
resolve exactly as they do for production components. \`lineHeight\` and
\`letterSpacing\` tokens are relative (\`%\` / \`em\`), so both tokens and observed
values are compared as a **ratio to fontSize** rather than an absolute px string.

Methodology notes / known limitations:
- \`fontFamily\` / \`boxShadow\` matching is exact-string, not "token value is a
  substring of the computed stack" — a token match there means the computed
  value equals the token's resolved value exactly.
- No \`--*-shadow-*\` tokens exist in \`tokens.css\` at all, so every \`boxShadow\`
  value below is unmatched by construction — a real gap, not a tool limitation.
- No breakpoint tokens exist either (grepped \`tokens.css\` + \`armada-tokens.json\`
  for "breakpoint": zero hits) — every width/height threshold in
  \`src/breakpoints.ts\` is a hardcoded magic number in component CSS.
- All matching below resolves against \`tokens.css\` ONLY (the file every
  component actually imports at runtime). \`armada-tokens.json\` is the
  reference Style-Dictionary source and its leaf-token count is reported
  above for drift visibility, but its values are not independently
  cross-matched against observed styles — per \`packages/ui/CLAUDE.md\`,
  \`tokens.css\` is hand-maintained as the live source of truth and
  \`armada-tokens.json\` is kept in sync manually, so the two should already
  agree.

## Breakpoints swept

${breakpointLines}

No token in \`armada-tokens.json\` / \`tokens.css\` defines any of these — see note above.

## Colors (${colorRows.length} distinct, ${colorRows.filter((r) => r.matchedTokens.length === 0).length} unmatched)

${mdTable(colorRows, 'Color')}

## Font tuples — family / size / weight / lineHeight / letterSpacing (${fontTupleRows.length} distinct, ${fontTupleRows.filter((r) => r.matchedTokens.length === 0).length} unmatched)

${mdTable(fontTupleRows, 'Tuple')}

## Spacing — margin/padding/gap (${spacingRows.length} distinct, ${spacingRows.filter((r) => r.matchedTokens.length === 0).length} unmatched)

${mdTable(spacingRows, 'Spacing')}

## Radii (${radiusRows.length} distinct, ${radiusRows.filter((r) => r.matchedTokens.length === 0).length} unmatched)

${mdTable(radiusRows, 'Radius')}

## Shadows (${shadowRows.length} distinct, ${shadowRows.filter((r) => r.matchedTokens.length === 0).length} unmatched)

${mdTable(shadowRows, 'Shadow')}

## Summary

- ${darkTokens.length} tokens defined in \`tokens.css\` \`[data-theme="dark"]\` (and ${jsonLeafCount} leaf tokens in \`armada-tokens.json\` — a structural count only, not cross-matched value-by-value; see "Methodology notes").
- ${allRows.length} distinct observed values across colors/font-tuples/spacing/radii/shadows.
- ${unmatchedCount} of those have **no matching token**.
`

  await writeFile(path.join(BASELINE_DIR, 'VOCABULARY.md'), md)
  await writeFile(
    path.join(BASELINE_DIR, 'vocabulary.json'),
    stableStringify({
      tokenCount: darkTokens.length,
      armadaTokensJsonLeafCount: jsonLeafCount,
      tokens: resolved,
      colors: colorRows,
      fontTuples: fontTupleRows,
      spacing: spacingRows,
      radii: radiusRows,
      shadows: shadowRows,
      unmatchedCount,
    }),
  )
  console.log(`wrote VOCABULARY.md + vocabulary.json — ${allRows.length} distinct values, ${unmatchedCount} unmatched`)
}

main().catch((err) => {
  console.error(err)
  process.exitCode = 1
})
