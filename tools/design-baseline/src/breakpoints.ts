// ABOUTME: Viewport matrix for the rendered-baseline capture, derived from every
// ABOUTME: @media width/height threshold actually present in the swept CSS (see below).

/**
 * Every `@media` width/height threshold found by grepping
 * `packages/ui/src/**`, `crowdfund-ui/packages/shared/src/**` and
 * `crowdfund-ui/packages/committer/src/**` for `@media[^{]+` on 2026-10-05
 * (base SHA caf640903d013b2b5122b5fc6b5f5a0aaa741afc). `prefers-reduced-motion:
 * reduce` also appears throughout but is not a layout breakpoint — every
 * capture forces reduced motion instead (see freeze.ts), so it is not swept
 * as a separate viewport.
 *
 * Width thresholds (ascending), source file(s):
 *   720   max-width  ParticipantsTable.module.css (.tr grid-template-columns)
 *   767   max-width  pervasive "mobile" cutover — Header, Progress, CrowdfundExperience,
 *                     Hero, CrowdfundLeftColumn, HeroParticipantsPanel, InviteFlow screens,
 *                     MyPosition*, ParticipateFlow screens, committer components, mobile-layout.css
 *   768   min-width   complement of 767 — CrowdfundExperience.module.css (.detailsBtnMobileOnly),
 *                     MaxOutBanner.module.css (.inShell)
 *   900   max-width   MyPosition.module.css (.topRow), MyPositionSplit.module.css (.layout)
 *   920   max-width   ParticipantsTable.module.css (.headerRow)
 *   1100  max-width   HeroParticipantsPanel.module.css / MyPositionHero.module.css (.leftCorner),
 *                     CrowdfundExperience.module.css (.rightCorner)
 *   1440  max-width   Progress.module.css, CrowdfundExperience.module.css, Hero.module.css,
 *                     CrowdfundLeftColumn.module.css, HeroParticipantsPanel.module.css (all `.card`/
 *                     `.progressWrap`/`.leftCorner`/`.column` outer-shell width caps)
 *
 * Height threshold:
 *   799   max-height  CrowdfundLeftColumn.module.css, InvitesCard.module.css, MyPositionSplit —
 *                      all gated behind a compound class (e.g. `.shellOpen.shellShortCardDone`)
 *                      that is only added after a JS-driven interaction (invites list opened then
 *                      collapsed). Not reached by any state in this baseline — see README
 *                      "Unreachable states".
 */
export interface Viewport {
  /** Capture id suffix — appears in the output filename as `@<id>`. */
  id: string
  width: number
  height: number
  /** Which threshold(s) this viewport is chosen to exercise. */
  note: string
}

const STANDARD_HEIGHT = 900

/**
 * Nine widths: one exactly AT each of the seven thresholds above (so the
 * exact-match arm of every `max-width`/`min-width` rule is exercised), plus
 * one representative width below the smallest threshold and one above the
 * largest, matching real device classes.
 */
export const VIEWPORTS: readonly Viewport[] = [
  { id: '375', width: 375, height: STANDARD_HEIGHT, note: 'representative narrow phone, below every threshold' },
  { id: '720', width: 720, height: STANDARD_HEIGHT, note: 'max-width:720 exact (ParticipantsTable .tr)' },
  { id: '767', width: 767, height: STANDARD_HEIGHT, note: 'max-width:767 exact (mobile cutover, pervasive)' },
  { id: '768', width: 768, height: STANDARD_HEIGHT, note: 'min-width:768 exact (complement of 767)' },
  { id: '900', width: 900, height: STANDARD_HEIGHT, note: 'max-width:900 exact (MyPosition .topRow)' },
  { id: '920', width: 920, height: STANDARD_HEIGHT, note: 'max-width:920 exact (ParticipantsTable .headerRow)' },
  { id: '1100', width: 1100, height: STANDARD_HEIGHT, note: 'max-width:1100 exact (rightCorner/leftCorner)' },
  { id: '1440', width: 1440, height: STANDARD_HEIGHT, note: 'max-width:1440 exact (outer shell width caps)' },
  { id: '1920', width: 1920, height: STANDARD_HEIGHT, note: 'representative wide desktop, above every threshold' },
] as const

/**
 * Extra short-viewport capture exercising the max-height:799 threshold's
 * ordinary (non-compound-class) cascade. Width chosen mid-range (1024) so it
 * does not also cross a width threshold. See the height-threshold doc comment
 * above for why the compound-class behavior itself is not reachable.
 */
export const SHORT_HEIGHT_VIEWPORT: Viewport = {
  id: '1024x760',
  width: 1024,
  height: 760,
  note: 'max-height:799 probe — base cascade only, compound-class variants unreachable',
}

/** Smaller viewport set used for interaction states (hover/focus/modal), where
 *  sweeping all nine widths would mostly re-prove the same layout-state result
 *  (hover/focus do not themselves change at most of the layout breakpoints).
 *  Narrow + wide bound the behavior; hover is not meaningful on a touch-sized
 *  viewport but focus-visible and modals still are, so both ends are kept. */
export const INTERACTION_VIEWPORTS: readonly Viewport[] = [
  VIEWPORTS[0]!, // 375
  VIEWPORTS[VIEWPORTS.length - 1]!, // 1920
] as const
