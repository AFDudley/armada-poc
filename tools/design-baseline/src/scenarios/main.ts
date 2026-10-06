// ABOUTME: Main interactive scenario — sale-open through a successful finalize + ARM claim,
// ABOUTME: driving the real committer UI (wallet connect, Participate flow, invite-link flow,
// ABOUTME: Claim flow) against a freshly deployed crowdfund on the in-container Anvil.

import type { Browser } from '@playwright/test'
import { VIEWPORTS, INTERACTION_VIEWPORTS } from '../breakpoints.ts'
import { freezeMotion } from '../freeze.ts'
import { installInjectedWallet } from '../wallet.ts'
import { openCommitter, captureAcrossViewports } from '../scenarioHelpers.ts'
import {
  connectWallet,
  openParticipate,
  fillMaxAmountAndReview,
  approveAndCommit,
  logVisibleHeadings,
  passParticipateIntroIfPresent,
  extractInviteLinkFromPage,
} from '../flows.ts'
import { runChainPlan, type ChainAction } from '../chainPlan.ts'
import { ANVIL_RPC_URL, getAccounts } from '../anvil.ts'

const HUB_CHAIN_ID = 31337

export async function runMainScenario(
  repoRoot: string,
  browser: Browser,
  previewUrl: string,
  outDir: string,
): Promise<void> {
  const accounts = await getAccounts()
  const walletX = accounts[1] // "Seed A" — the scenario's hero participant
  const inviteeHop1 = accounts[4] // "Hop-1 A" — redeems walletX's invite link

  // ---- Window open, nobody has committed yet ------------------------------------------------
  runChainPlan(repoRoot, [{ op: 'advanceToWindowStart' }, { op: 'printState' }])

  const ctxDisconnected = await browser.newContext()
  const pageDisconnected = await ctxDisconnected.newPage()
  await freezeMotion(pageDisconnected)
  await openCommitter(pageDisconnected, previewUrl, '/')
  await captureAcrossViewports(pageDisconnected, outDir, 'sale-open', VIEWPORTS)
  await ctxDisconnected.close()

  // ---- Wallet X connects, before being whitelisted — "no position yet" ----------------------
  const ctxX = await browser.newContext()
  const pageX = await ctxX.newPage()
  await freezeMotion(pageX)
  await installInjectedWallet(pageX, { rpcUrl: ANVIL_RPC_URL, address: walletX, chainId: HUB_CHAIN_ID })
  await openCommitter(pageX, previewUrl, '/')
  await connectWallet(pageX)
  await captureAcrossViewports(pageX, outDir, 'wallet-connected-no-position', VIEWPORTS)

  // ---- Seed wallet X, then drive a REAL commit through the UI --------------------------------
  const addSeedPlan: ChainAction[] = [{ op: 'addSeeds', indices: [1] }]
  runChainPlan(repoRoot, addSeedPlan)
  await openCommitter(pageX, previewUrl, '/') // reload — picks up the new on-chain whitelist state
  await connectWallet(pageX)
  await openParticipate(pageX)
  await logVisibleHeadings(pageX, 'participate opened (wallet X, newly seeded)')
  await passParticipateIntroIfPresent(pageX)

  await fillMaxAmountAndReview(pageX)
  await captureAcrossViewports(pageX, outDir, 'participate-review', INTERACTION_VIEWPORTS)

  await approveAndCommit(pageX)
  await logVisibleHeadings(pageX, 'post-commit')
  await captureAcrossViewports(pageX, outDir, 'participate-confirmation', INTERACTION_VIEWPORTS)

  await openCommitter(pageX, previewUrl, '/?view=myposition')
  await captureAcrossViewports(pageX, outDir, 'my-position-seeded', VIEWPORTS)

  // ---- Invite flow (inviter side): My Position → Invite → Share link ------------------------
  await pageX.getByRole('button', { name: 'Invite', exact: true }).first().click()
  await captureAcrossViewports(pageX, outDir, 'invite-method-picker', INTERACTION_VIEWPORTS)
  await pageX.getByRole('menuitem', { name: /Share link/ }).click()
  await captureAcrossViewports(pageX, outDir, 'invite-link-generated', INTERACTION_VIEWPORTS)
  const inviteUrl = await extractInviteLinkFromPage(pageX)
  console.log(`[main] generated invite link: ${inviteUrl}`)
  await ctxX.close()

  // ---- Invite flow (recipient side): a different wallet redeems the link --------------------
  const inviteUrlPath = new URL(inviteUrl).pathname + new URL(inviteUrl).search
  const ctxInvitee = await browser.newContext()
  const pageInvitee = await ctxInvitee.newPage()
  await freezeMotion(pageInvitee)
  await installInjectedWallet(pageInvitee, { rpcUrl: ANVIL_RPC_URL, address: inviteeHop1, chainId: HUB_CHAIN_ID })
  await openCommitter(pageInvitee, previewUrl, inviteUrlPath)
  await captureAcrossViewports(pageInvitee, outDir, 'invite-redemption-landing', VIEWPORTS)
  await logVisibleHeadings(pageInvitee, 'invite redemption landing')

  await pageInvitee.getByRole('button', { name: /^Join$/ }).click().catch(() => undefined)
  await connectWallet(pageInvitee)
  await logVisibleHeadings(pageInvitee, 'invite redemption after connect')
  await passParticipateIntroIfPresent(pageInvitee)
  await fillMaxAmountAndReview(pageInvitee)
  await captureAcrossViewports(pageInvitee, outDir, 'invite-redemption-review', INTERACTION_VIEWPORTS)
  await approveAndCommit(pageInvitee)
  await captureAcrossViewports(pageInvitee, outDir, 'invite-redemption-confirmation', INTERACTION_VIEWPORTS)
  await ctxInvitee.close()

  // ---- Push total committed above MIN_SALE via background participants, then finalize -------
  runChainPlan(repoRoot, [
    { op: 'bulkCommit', startIndex: 20, count: 70, hop: 0, capUsd: 15_000 },
    { op: 'advancePastWindowEnd' },
    { op: 'finalize' },
    { op: 'printState' },
  ])

  // ---- Finalized success + claim flow (wallet X) ---------------------------------------------
  const ctxClaim = await browser.newContext()
  const pageClaim = await ctxClaim.newPage()
  await freezeMotion(pageClaim)
  await installInjectedWallet(pageClaim, { rpcUrl: ANVIL_RPC_URL, address: walletX, chainId: HUB_CHAIN_ID })
  await openCommitter(pageClaim, previewUrl, '/')
  await connectWallet(pageClaim)
  await captureAcrossViewports(pageClaim, outDir, 'finalized-success', VIEWPORTS)

  await openCommitter(pageClaim, previewUrl, '/?view=claim')
  await connectWallet(pageClaim)
  await logVisibleHeadings(pageClaim, 'claim intro')
  await captureAcrossViewports(pageClaim, outDir, 'claim-intro', INTERACTION_VIEWPORTS)

  await pageClaim.getByRole('button', { name: 'Start', exact: true }).click()
  await captureAcrossViewports(pageClaim, outDir, 'claim-delegate', INTERACTION_VIEWPORTS)

  await pageClaim.getByRole('button', { name: 'Review', exact: true }).click()
  await captureAcrossViewports(pageClaim, outDir, 'claim-review', INTERACTION_VIEWPORTS)

  await pageClaim.getByRole('button', { name: 'Claim ARM', exact: true }).click()
  await pageClaim.getByRole('button', { name: 'Done', exact: true }).waitFor({ timeout: 30_000 })
  await captureAcrossViewports(pageClaim, outDir, 'claim-done', INTERACTION_VIEWPORTS)

  await openCommitter(pageClaim, previewUrl, '/?view=myposition')
  await captureAcrossViewports(pageClaim, outDir, 'my-position-claimed', VIEWPORTS)
  await ctxClaim.close()
}
