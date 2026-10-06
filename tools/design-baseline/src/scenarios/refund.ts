// ABOUTME: Refund-mode scenario — a single small commit, window closes with capped demand below
// ABOUTME: MIN_SALE, finalize() enters refundMode (phase stays Finalized, not Canceled); captures
// ABOUTME: the refund hero/position state and its refund-claim flow.

import type { Browser } from '@playwright/test'
import { VIEWPORTS, INTERACTION_VIEWPORTS } from '../breakpoints.ts'
import { freezeMotion } from '../freeze.ts'
import { installInjectedWallet } from '../wallet.ts'
import { openCommitter, captureAcrossViewports } from '../scenarioHelpers.ts'
import type { CaptureResult } from '../capture.ts'
import { connectWallet, openParticipate, passParticipateIntroIfPresent, fillMaxAmountAndReview, approveAndCommit, logVisibleHeadings } from '../flows.ts'
import { runChainPlan } from '../chainPlan.ts'
import { ANVIL_RPC_URL, getAccounts } from '../anvil.ts'

const HUB_CHAIN_ID = 31337

export async function runRefundScenario(
  repoRoot: string,
  browser: Browser,
  previewUrl: string,
  outDir: string,
): Promise<CaptureResult[]> {
  const results: CaptureResult[] = []
  const capture = async (page: Parameters<typeof captureAcrossViewports>[0], state: string, viewports: typeof VIEWPORTS) => {
    results.push(...(await captureAcrossViewports(page, outDir, state, viewports)))
  }

  const accounts = await getAccounts()
  const walletZ = accounts[1]

  runChainPlan(repoRoot, [
    { op: 'advanceToWindowStart' },
    { op: 'addSeeds', indices: [1] },
  ])

  const ctx = await browser.newContext()
  const page = await ctx.newPage()
  await freezeMotion(page)
  await installInjectedWallet(page, { rpcUrl: ANVIL_RPC_URL, address: walletZ, chainId: HUB_CHAIN_ID })
  await openCommitter(page, previewUrl, '/')
  await connectWallet(page)
  await openParticipate(page)
  await logVisibleHeadings(page, 'refund scenario — participate opened')
  await passParticipateIntroIfPresent(page)
  // Single $15,000 hop-0 commit, no bulk background participants — total committed stays well
  // under MIN_SALE ($1M), so finalize() below enters refundMode instead of allocating ARM.
  await fillMaxAmountAndReview(page)
  await approveAndCommit(page)

  runChainPlan(repoRoot, [
    { op: 'advancePastWindowEnd' },
    { op: 'finalize' },
    { op: 'printState' },
  ])

  await openCommitter(page, previewUrl, '/')
  await connectWallet(page)
  await capture(page, 'refund-mode-hero', VIEWPORTS)

  await openCommitter(page, previewUrl, '/?view=claim')
  await connectWallet(page)
  await logVisibleHeadings(page, 'refund scenario — claim intro')
  await capture(page, 'refund-mode-claim-intro', INTERACTION_VIEWPORTS)

  await page.getByRole('button', { name: /^Claim .* refund$/ }).click()
  await page.getByRole('button', { name: 'Done', exact: true }).waitFor({ timeout: 30_000 })
  await capture(page, 'refund-mode-claim-done', INTERACTION_VIEWPORTS)

  await openCommitter(page, previewUrl, '/?view=myposition')
  await capture(page, 'refund-mode-my-position', VIEWPORTS)

  await ctx.close()
  return results
}
