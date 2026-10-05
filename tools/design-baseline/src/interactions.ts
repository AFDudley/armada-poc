// ABOUTME: Keyboard-driven focus helper — real Tab presses so Chromium's
// ABOUTME: focus-visible heuristic activates (a programmatic .focus() does not, for buttons).

import type { Page } from '@playwright/test'

/** Presses Tab (from whatever currently has focus — call `page.locator('body').click()`
 *  first if you need a known starting point) until `document.activeElement`'s
 *  text content contains `matchText`, or throws after `maxTabs`. */
export async function tabTo(page: Page, matchText: string, maxTabs = 100): Promise<void> {
  for (let i = 0; i < maxTabs; i++) {
    await page.keyboard.press('Tab')
    const matched = await page.evaluate((text) => {
      const el = document.activeElement
      return el !== null && (el.textContent ?? '').includes(text)
    }, matchText)
    if (matched) return
  }
  throw new Error(`tabTo: could not reach an element containing "${matchText}" within ${maxTabs} Tab presses`)
}
