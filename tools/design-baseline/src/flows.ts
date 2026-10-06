// ABOUTME: Reusable Playwright click-through helpers for the committer's wallet-connected
// ABOUTME: screens — connect, open Participate/Claim, fill+review+confirm a commit, drive the
// ABOUTME: invite-link flow. Scenario scripts (src/scenarios/*.ts) compose these between
// ABOUTME: `captureState` calls; nothing here captures on its own.

import type { Page } from '@playwright/test'

/** Waits for the connected wallet pill to appear — in practice the injected shim (wallet.ts)
 *  already has `eth_accounts` return a non-empty array, so wagmi's injected connector silently
 *  auto-reconnects on mount (standard wagmi behavior for a provider that reports an existing
 *  authorized account) and the "Connect Wallet" button never renders at all. Falls back to the
 *  real RainbowKit click-through (Connect Wallet → Rainbow) on the rare page where it doesn't. */
export async function connectWallet(page: Page): Promise<void> {
  const pill = page.getByRole('button', { name: /^0x[0-9a-fA-F]{4}\.\.\.[0-9a-fA-F]{4}$/ })
  if (await pill.isVisible().catch(() => false)) return

  const connectBtn = page.getByRole('button', { name: 'Connect Wallet', exact: true })
  const connectVisible = await connectBtn
    .waitFor({ state: 'visible', timeout: 5_000 })
    .then(() => true)
    .catch(() => false)
  if (connectVisible) {
    await connectBtn.click()
    await page.getByText('Rainbow', { exact: true }).first().click()
  }
  await pill.waitFor({ timeout: 15_000 })
}

/** Opens the Participate modal via the header CTA (the header banner's "Participate" button —
 *  disambiguated from the "Join the fleet" hero card, which also has a same-named button when
 *  no position exists yet). */
export async function openParticipate(page: Page): Promise<void> {
  await page.getByRole('banner').getByRole('button', { name: 'Participate', exact: true }).click()
}

/** Logs the modal/card's current visible heading-ish text to stdout — used while developing each
 *  scenario to see which step actually rendered without guessing blind. Safe to leave in: cheap,
 *  stdout only. */
export async function logVisibleHeadings(page: Page, label: string): Promise<void> {
  const headings = await page.locator('h1, h2, h3').allTextContents()
  console.log(`[flow] ${label} — headings: ${JSON.stringify(headings)}`)
}

/** Clicks past the Participate flow's optional intro steps — Step0Invite's "Join now" splash,
 *  then StepBeforeYouStart's "Commit" — both shown to a seed whitelisted directly (not via an
 *  invite link) on their first participate. Each is a timed, best-effort wait: a returning
 *  participant with an existing position skips straight to Step2Commit, so neither button ever
 *  appears for them. */
export async function passParticipateIntroIfPresent(page: Page): Promise<void> {
  const joinNow = page.getByRole('button', { name: 'Join now', exact: true })
  const joinNowVisible = await joinNow
    .waitFor({ state: 'visible', timeout: 3_000 })
    .then(() => true)
    .catch(() => false)
  if (joinNowVisible) await joinNow.click()

  const commitIntro = page.getByRole('button', { name: 'Commit', exact: true })
  const commitIntroVisible = await commitIntro
    .waitFor({ state: 'visible', timeout: 3_000 })
    .then(() => true)
    .catch(() => false)
  if (commitIntroVisible) await commitIntro.click()
}

/** Step2Commit (single-hop, new participant): clicks the deterministic max-fill button — its
 *  accessible name is its `aria-label` ("Fill maximum $X USDC"), NOT its visible text ("MAX $X
 *  USDC") — then "Review". Deterministic vs. a typed amount: same effect, zero input-timing
 *  nondeterminism. */
export async function fillMaxAmountAndReview(page: Page): Promise<void> {
  await page.getByRole('button', { name: /^Fill maximum [\d,]+ USDC$/ }).click()
  await page.getByRole('button', { name: 'Review', exact: true }).click()
}

/** Step3Review: "Approve and commit" submits the approve+commit pipeline (both txs land on our
 *  own Anvil, auto-mined near-instantly). Waits for the flow to reach its confirmation screen. */
export async function approveAndCommit(page: Page): Promise<void> {
  await page.getByRole('button', { name: 'Approve and commit', exact: true }).click()
  await page.getByText('Confirmed', { exact: false }).first().waitFor({ timeout: 30_000 }).catch(() => undefined)
}

/** Reads the generated invite link's full ABSOLUTE URL straight from the DOM. The confirmation
 *  screen's `.createdLinkPath` element carries it as `title={createdLink.link}` (the visible text
 *  is just the path — `inviteLinkPath()` in InviteActionScreen.tsx strips the origin for
 *  display). The My Position "Your invites" list (`InvitesCard.tsx`) ALSO renders a `title`
 *  attribute for the same pending invite via `MiddleTruncateText`, but with the PATH ONLY (no
 *  origin) — both are visible simultaneously, so matching on "starts with http" (not just
 *  "contains /invite?") is required to land on the confirmation screen's element, not that one.
 *  Reading the attribute directly also sidesteps `document.body.innerText`, which can insert a
 *  spurious line break mid-string for long unbroken hex runs under this screen's `word-break`
 *  CSS. */
export async function extractInviteLinkFromPage(page: Page): Promise<string> {
  const result = await page.evaluate(() => {
    const all: string[] = []
    for (const el of document.querySelectorAll<HTMLElement>('[title]')) {
      const title = el.getAttribute('title') ?? ''
      if (/\/invite\?/.test(title)) all.push(title)
    }
    return { all, link: all.find((t) => /^https?:\/\//.test(t)) ?? null }
  })
  if (!result.link) {
    throw new Error(`no invite link found. candidate titles: ${JSON.stringify(result.all)}`)
  }
  return result.link
}
