// ABOUTME: Canceled scenario — a participant commits, then the security council cancels the
// ABOUTME: sale mid-window (ArmadaCrowdfund.cancel()); captures the canceled hero/position state
// ABOUTME: and the resulting refund-claim flow (phase === Canceled, not refundMode-below-min).

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

export async function runCanceledScenario(
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
  const walletY = accounts[1]

  runChainPlan(repoRoot, [
    { op: 'advanceToWindowStart' },
    { op: 'addSeeds', indices: [1] },
  ])

  const ctx = await browser.newContext()
  const page = await ctx.newPage()
  await freezeMotion(page)
  await installInjectedWallet(page, { rpcUrl: ANVIL_RPC_URL, address: walletY, chainId: HUB_CHAIN_ID })
  await openCommitter(page, previewUrl, '/')
  await connectWallet(page)
  await openParticipate(page)
  await logVisibleHeadings(page, 'canceled scenario — participate opened')
  await passParticipateIntroIfPresent(page)
  await fillMaxAmountAndReview(page)
  await approveAndCommit(page)

  runChainPlan(repoRoot, [{ op: 'cancel' }, { op: 'printState' }])

  await openCommitter(page, previewUrl, '/')
  await connectWallet(page)
  await capture(page, 'canceled-hero', VIEWPORTS)

  await openCommitter(page, previewUrl, '/?view=claim')
  await connectWallet(page)
  await logVisibleHeadings(page, 'canceled scenario — claim intro')
  await capture(page, 'canceled-claim-intro', INTERACTION_VIEWPORTS)

  await page.getByRole('button', { name: /^Claim .* refund$/ }).click()
  await page.getByRole('button', { name: 'Done', exact: true }).waitFor({ timeout: 30_000 })
  await capture(page, 'canceled-claim-done', INTERACTION_VIEWPORTS)

  await openCommitter(page, previewUrl, '/?view=myposition')
  await capture(page, 'canceled-my-position', VIEWPORTS)

  await ctx.close()
  return results
}
