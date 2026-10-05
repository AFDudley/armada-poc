// ABOUTME: Strips animation/transition noise so computed-style snapshots are
// ABOUTME: deterministic regardless of when, during a transition, the page is sampled.

import type { Page } from '@playwright/test'

const FREEZE_CSS = `
  *, *::before, *::after {
    animation-duration: 0s !important;
    animation-delay: 0s !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0s !important;
    transition-delay: 0s !important;
    scroll-behavior: auto !important;
    caret-color: transparent !important;
  }
`

/**
 * `tsx`'s esbuild transform injects `__name(fn, "fnName")` calls into
 * compiled output (name-preservation across its internal bundling) — those
 * calls survive when Playwright serializes an imported, already-compiled
 * function via `.toString()` for `page.evaluate`, but the browser page has no
 * `__name` global, so without this shim every such call throws
 * `ReferenceError: __name is not defined`. A permissive polyfill (assign the
 * name and return the function) satisfies every call site generically.
 */
async function installNamePolyfill(page: Page): Promise<void> {
  await page.addInitScript(() => {
    ;(globalThis as Record<string, unknown>).__name = (fn: unknown, name: string) => {
      try {
        Object.defineProperty(fn as object, 'name', { value: name, configurable: true })
      } catch {
        // some targets (e.g. frozen functions) reject redefinition — fine, best-effort
      }
      return fn
    }
  })
}

/** Call once per page, before navigation (survives subsequent navigations on
 *  the same page via addStyleTag re-injection per-navigation in `gotoFrozen`). */
export async function freezeMotion(page: Page): Promise<void> {
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await installNamePolyfill(page)
}

/** Navigate then inject the freeze stylesheet (addStyleTag only applies to the
 *  current document, so it must run after each goto). */
export async function gotoFrozen(page: Page, url: string): Promise<void> {
  await page.goto(url, { waitUntil: 'networkidle' })
  await page.addStyleTag({ content: FREEZE_CSS })
}
