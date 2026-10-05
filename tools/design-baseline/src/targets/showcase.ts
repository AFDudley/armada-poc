// ABOUTME: @armada/ui showcase target — one static layout build, plus hover/focus
// ABOUTME: interaction states on its real primitives (Button, NavBar, Tooltip).

import type { Page } from '@playwright/test'
import { VIEWPORTS, INTERACTION_VIEWPORTS } from '../breakpoints.ts'
import type { Viewport } from '../breakpoints.ts'
import { tabTo } from '../interactions.ts'

export const SHOWCASE_WORKSPACE = '@armada/ui-showcase'
export const SHOWCASE_DIR = 'packages/ui/showcase'

export interface ShowcaseState {
  name: string
  viewports: readonly Viewport[]
  prepare?: (page: Page) => Promise<void>
  description: string
}

export const SHOWCASE_STATES: readonly ShowcaseState[] = [
  {
    name: 'base',
    viewports: VIEWPORTS,
    description: 'Default render — every primitive at rest, no interaction.',
  },
  {
    name: 'button-primary-hover',
    viewports: INTERACTION_VIEWPORTS,
    prepare: async (page) => {
      await page.getByRole('button', { name: 'Medium', exact: true }).first().hover()
    },
    description: 'Mouse hover over the first "Medium" button (Buttons > Primary row).',
  },
  {
    name: 'button-primary-focus',
    viewports: INTERACTION_VIEWPORTS,
    prepare: async (page) => {
      await page.locator('body').click({ position: { x: 2, y: 2 } })
      await tabTo(page, 'Medium')
    },
    description: 'Real Tab-key focus (not .focus()) onto the first "Medium" button, so :focus-visible activates.',
  },
  {
    name: 'navitem-hover',
    viewports: INTERACTION_VIEWPORTS,
    prepare: async (page) => {
      await page.getByRole('button', { name: 'My position', exact: true }).first().hover()
    },
    description: 'Mouse hover over the first "My position" NavBar item.',
  },
  {
    name: 'tooltip-centered-open',
    viewports: INTERACTION_VIEWPORTS,
    prepare: async (page) => {
      await page.getByRole('button', { name: 'Centered', exact: true }).hover()
    },
    description: 'Hover the "Centered" Tooltip trigger — reveals the single-line tooltip popover.',
  },
  {
    name: 'tooltip-rich-open',
    viewports: INTERACTION_VIEWPORTS,
    prepare: async (page) => {
      await page.locator('body').click({ position: { x: 2, y: 2 } })
      await tabTo(page, 'Rich')
    },
    description: 'Real Tab-key focus onto the "Rich" Tooltip trigger — reveals the title+bullets popover.',
  },
] as const
