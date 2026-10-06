// ABOUTME: Small shared helpers scenario scripts use between chain-plan steps and
// ABOUTME: `captureState` calls — navigation + multi-viewport capture loops.

import type { Page } from '@playwright/test'
import { gotoFrozen } from './freeze.ts'
import { captureState, type CaptureResult } from './capture.ts'
import type { Viewport } from './breakpoints.ts'

/** Navigates to `${previewUrl}${pathSuffix}` with the freeze stylesheet re-applied (see
 *  freeze.ts — required after every navigation, not just once). */
export async function openCommitter(page: Page, previewUrl: string, pathSuffix = '/'): Promise<void> {
  await gotoFrozen(page, `${previewUrl}${pathSuffix}`)
}

/** Captures the page's CURRENT state at every viewport in `viewports`, resizing between each —
 *  no navigation/interaction in between, so this only suits already-settled screens (reached via
 *  a single flow action run once beforehand, not per-viewport). Returns one result per viewport
 *  so callers (scenario scripts, the pipeline run-record) can aggregate state×viewport counts. */
export async function captureAcrossViewports(
  page: Page,
  outDir: string,
  state: string,
  viewports: readonly Viewport[],
): Promise<CaptureResult[]> {
  const results: CaptureResult[] = []
  for (const viewport of viewports) {
    const result = await captureState(page, outDir, state, viewport)
    console.log(`[capture] ${state}@${viewport.id} — ${result.elementCount} elements`)
    results.push(result)
  }
  return results
}
