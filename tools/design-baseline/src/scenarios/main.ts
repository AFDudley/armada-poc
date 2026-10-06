// ABOUTME: Main interactive scenario — sale-open through a successful finalize + ARM claim,
// ABOUTME: driving the real committer UI (wallet connect, Participate flow, invite-link flow,
// ABOUTME: Claim flow) against a freshly deployed crowdfund on the in-container Anvil.

import type { Browser } from '@playwright/test'
import { VIEWPORTS, INTERACTION_VIEWPORTS } from '../breakpoints.ts'
import { freezeMotion } from '../freeze.ts'
import { installInjectedWallet } from '../wallet.ts'
import { openCommitter, captureAcrossViewports } from '../scenarioHelpers.ts'
import type { CaptureResult } from '../capture.ts'
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
): Promise<CaptureResult[]> {
  const results: CaptureResult[] = []
  const capture = async (page: Parameters<typeof captureAcrossViewports>[0], state: string, viewports: typeof VIEWPORTS) => {
    results.push(...(await captureAcrossViewports(page, outDir, state, viewports)))
  }

  const accounts = await getAccounts()
  const walletX = accounts[1] // "Seed A" — the scenario's hero participant
  const inviteeHop1 = accounts[4] // "Hop-1 A" — redeems walletX's invite link

  // ---- Window open, nobody has committed yet ------------------------------------------------
  runChainPlan(repoRoot, [{ op: 'advanceToWindowStart' }, { op: 'printState' }])

  const ctxDisconnected = await browser.newContext()
  const pageDisconnected = await ctxDisconnected.newPage()
  await freezeMotion(pageDisconnected)
  await openCommitter(pageDisconnected, previewUrl, '/')
  await capture(pageDisconnected, 'sale-open', VIEWPORTS)
  await ctxDisconnected.close()

  // ---- Wallet X connects, before being whitelisted — "no position yet" ----------------------
  const ctxX = await browser.newContext()
  const pageX = await ctxX.newPage()
  await freezeMotion(pageX)
  await installInjectedWallet(pageX, { rpcUrl: ANVIL_RPC_URL, address: walletX, chainId: HUB_CHAIN_ID })
  await openCommitter(pageX, previewUrl, '/')
  await connectWallet(pageX)
  await capture(pageX, 'wallet-connected-no-position', VIEWPORTS)

  // ---- Seed wallet X, then drive a REAL commit through the UI --------------------------------
  const addSeedPlan: ChainAction[] = [{ op: 'addSeeds', indices: [1] }]
  runChainPlan(repoRoot, addSeedPlan)
  await openCommitter(pageX, previewUrl, '/') // reload — picks up the new on-chain whitelist state
  await connectWallet(pageX)
  await openParticipate(pageX)
  await logVisibleHeadings(pageX, 'participate opened (wallet X, newly seeded)')
  await passParticipateIntroIfPresent(pageX)

  await fillMaxAmountAndReview(pageX)
  await capture(pageX, 'participate-review', INTERACTION_VIEWPORTS)

  await approveAndCommit(pageX)
  await logVisibleHeadings(pageX, 'post-commit')
  await capture(pageX, 'participate-confirmation', INTERACTION_VIEWPORTS)

  await openCommitter(pageX, previewUrl, '/?view=myposition')
  await capture(pageX, 'my-position-seeded', VIEWPORTS)

  // ---- Invite flow (inviter side): My Position → Invite → Share link → Create link ----------
  // The per-hop invite button's accessible NAME is its `aria-label` ("<hop label>, N invite(s)
  // left"), not its visible text ("N invite(s) left") — matched by suffix since the hop label
  // prefix varies.
  await pageX.getByRole('button', { name: /invites? left$/i }).first().click()
  await capture(pageX, 'invite-method-picker', INTERACTION_VIEWPORTS)
  await pageX.getByRole('menuitem', { name: /Share link/ }).click()
  await pageX.getByRole('button', { name: 'Create link', exact: true }).click()
  // Signing the invite link (EIP-712, via the injected wallet shim) is async — wait for the
  // confirmation screen's "Copy link" CTA, then extract the link IMMEDIATELY (the confirmation
  // auto-dismisses on its own; waiting until after the multi-viewport capture loop below races
  // that dismissal and intermittently reads the "Your invites" list's row instead — stripped of
  // origin for display — rather than the confirmation box's full absolute link).
  await pageX.getByRole('button', { name: 'Copy link', exact: true }).waitFor({ timeout: 15_000 })
  const inviteUrl = await extractInviteLinkFromPage(pageX)
  await capture(pageX, 'invite-link-generated', INTERACTION_VIEWPORTS)
  console.log(`[main] generated invite link: ${inviteUrl}`)
  await ctxX.close()

  // ---- Invite flow (recipient side): a different wallet redeems the link --------------------
  // Not whitelisted via `addSeeds` (the signed link itself is the invitee's eligibility proof),
  // but the shared Step2Commit UI still gates "Review" on an actual on-chain USDC balance.
  runChainPlan(repoRoot, [{ op: 'fundUsdc', indices: [4] }])
  const inviteUrlPath = new URL(inviteUrl).pathname + new URL(inviteUrl).search
  const ctxInvitee = await browser.newContext()
  const pageInvitee = await ctxInvitee.newPage()
  await freezeMotion(pageInvitee)
  await installInjectedWallet(pageInvitee, { rpcUrl: ANVIL_RPC_URL, address: inviteeHop1, chainId: HUB_CHAIN_ID })
  await openCommitter(pageInvitee, previewUrl, inviteUrlPath)
  await capture(pageInvitee, 'invite-redemption-landing', VIEWPORTS)
  await logVisibleHeadings(pageInvitee, 'invite redemption landing')

  // The /invite landing page is standalone chrome (no header/nav, no wallet pill) — it has no
  // "Connect Wallet" button of its own either: InviteLinkFlowController starts at its 'wallet'
  // step only when `wallet.connected` is false, which the injected shim's auto-reconnect already
  // satisfies, so "Join now" advances straight past it to StepBeforeYouStart.
  await pageInvitee.getByRole('button', { name: 'Join now', exact: true }).click().catch(() => undefined)
  await logVisibleHeadings(pageInvitee, 'invite redemption after join')
  await passParticipateIntroIfPresent(pageInvitee)
  await fillMaxAmountAndReview(pageInvitee)
  await capture(pageInvitee, 'invite-redemption-review', INTERACTION_VIEWPORTS)
  await approveAndCommit(pageInvitee)
  await capture(pageInvitee, 'invite-redemption-confirmation', INTERACTION_VIEWPORTS)
  await ctxInvitee.close()

  // ---- Push total ALLOCATED (not just committed) USDC above MIN_SALE, then finalize ----------
  // Hop-0's allocation is ceiling-capped at 47% of saleSize regardless of oversubscription
  // (ArmadaCrowdfund._computeHopAllocations) — at BASE_SALE that's only $564,000, under MIN_SALE
  // ($1M) on its own. Real hop-1 demand is required too, which needs an on-chain `invite()` from
  // an already-eligible hop-0 address before each hop-1 participant can commit — 40 hop-0 bulk
  // participants each invite 3 fresh addresses (HOP0_MAX_INVITES), giving 120 hop-1 participants
  // at the $4,000 hop-1 cap ($480,000 of genuine hop-1 demand). Participant indices are kept
  // within hardhat.config.ts's `hub` network account limit (`count: 200`, i.e. indices 0-199) —
  // bulkCommit uses 20-59, inviteAndCommit's invitees use 60-179.
  runChainPlan(repoRoot, [
    { op: 'bulkCommit', startIndex: 20, count: 40, hop: 0, capUsd: 15_000 },
    {
      op: 'inviteAndCommit',
      inviterIndices: Array.from({ length: 40 }, (_, i) => 20 + i),
      inviterHop: 0,
      inviteesPerInviter: 3,
      inviteeStartIndex: 60,
      hop: 1,
      capUsd: 4_000,
    },
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
  await capture(pageClaim, 'finalized-success', VIEWPORTS)

  await openCommitter(pageClaim, previewUrl, '/?view=claim')
  await connectWallet(pageClaim)
  await logVisibleHeadings(pageClaim, 'claim intro')
  await capture(pageClaim, 'claim-intro', INTERACTION_VIEWPORTS)

  await pageClaim.getByRole('button', { name: 'Start', exact: true }).click()
  await capture(pageClaim, 'claim-delegate', INTERACTION_VIEWPORTS)

  await pageClaim.getByRole('button', { name: 'Review', exact: true }).click()
  await capture(pageClaim, 'claim-review', INTERACTION_VIEWPORTS)

  await pageClaim.getByRole('button', { name: 'Claim ARM', exact: true }).click()
  await pageClaim.getByRole('button', { name: 'Done', exact: true }).waitFor({ timeout: 30_000 })
  await capture(pageClaim, 'claim-done', INTERACTION_VIEWPORTS)

  await openCommitter(pageClaim, previewUrl, '/?view=myposition')
  await capture(pageClaim, 'my-position-claimed', VIEWPORTS)
  await ctxClaim.close()

  return results
}
