// ABOUTME: Core per-state capture: resize viewport, let layout settle, extract every
// ABOUTME: visible element's computed style, write the JSON baseline + a full-page screenshot.

import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'
import type { Page } from '@playwright/test'
import { CSS_PROPERTIES } from './properties.ts'
import { extractInBrowser, type ExtractedElement } from './extract.ts'
import { stableStringify } from './stableJson.ts'
import type { Viewport } from './breakpoints.ts'

export interface CaptureResult {
  state: string
  viewport: string
  elementCount: number
  jsonPath: string
  screenshotPath: string
}
async function settle(page: Page): Promise<void> {
  // document.fonts.ready first: Geist/Charis SIL are remote Google Fonts:
  // text-width-dependent layout is sub-pixel sensitive to whether the real
  // font or its fallback is still painting.
  await page.evaluate(() => document.fonts.ready)
  // Poll until layout stops moving, rather than a fixed frame count. Several
  // primitives (NavBar's active-thumb slider) re-measure themselves via
  // ResizeObserver after a viewport resize, which is NOT guaranteed to have
  // flushed within a fixed 1-2 rAF budget — that raced non-deterministically
  // (same build, same input, different captured widths across runs) until
  // this was changed to "wait for two consecutive frames with an identical
  // full-page rect fingerprint" instead of a fixed wait.
  await page.evaluate(() => {
    const fingerprint = () => {
      let out = ''
      for (const el of document.body.querySelectorAll('*')) {
        const r = el.getBoundingClientRect()
        out += r.x + ',' + r.y + ',' + r.width + ',' + r.height + ';'
      }
      return out
    }
    const nextFrame = () => {
      const { promise, resolve } = Promise.withResolvers<void>()
      requestAnimationFrame(() => resolve())
      return promise
    }
    return (async () => {
      const MAX_ATTEMPTS = 20
      let previous = fingerprint()
      for (let i = 0; i < MAX_ATTEMPTS; i++) {
        await nextFrame()
        const current = fingerprint()
        if (current === previous) return
        previous = current
      }
    })()
  })
}

/**
 * Captures the current page DOM at `viewport` into `outDir/<state>@<id>.json`
 * plus a matching `.png` full-page screenshot. The caller is responsible for
 * navigation before calling this. `prepare`, when given, runs AFTER the
 * viewport resize settles and BEFORE extraction — e.g. hover/focus/click a
 * locator to reach an interaction state at the already-correct geometry.
 */
export async function captureState(
  page: Page,
  outDir: string,
  state: string,
  viewport: Viewport,
  prepare?: (page: Page) => Promise<void>,
): Promise<CaptureResult> {
  await page.setViewportSize({ width: viewport.width, height: viewport.height })
  await settle(page)

  if (prepare) {
    await prepare(page)
    await settle(page)
  }

  const elements: ExtractedElement[] = await page.evaluate(extractInBrowser, CSS_PROPERTIES)

  await mkdir(outDir, { recursive: true })
  const base = `${state}@${viewport.id}`
  const jsonPath = path.join(outDir, `${base}.json`)
  const screenshotPath = path.join(outDir, `${base}.png`)

  const record = {
    state,
    viewport: { id: viewport.id, width: viewport.width, height: viewport.height },
    elementCount: elements.length,
    elements,
  }
  await writeFile(jsonPath, stableStringify(record))
  await page.screenshot({ path: screenshotPath, fullPage: true })

  return { state, viewport: viewport.id, elementCount: elements.length, jsonPath, screenshotPath }
}
