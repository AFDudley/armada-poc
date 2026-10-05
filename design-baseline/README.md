# design-baseline

Rendered-style baseline for the `armada-ui` design-system migration (branch
`design/rendered-baseline`, base `origin/main` = `caf640903d013b2b5122b5fc6b5f5a0aaa741afc`).
Generated entirely from **production builds** (`vite build` + `vite preview`)
of two targets, captured with the Playwright tooling in `tools/design-baseline/`:

- **committer** — `crowdfund-ui/packages/committer`
- **showcase** — `packages/ui/showcase` (`@armada/ui-showcase`)

No app/component source was modified. No chain (Anvil/Hardhat) was used —
see "Unreachable states" below for why, and what that cost in coverage.

## Running it

```bash
cd tools/design-baseline
npm install                 # once
npx tsx src/run.ts          # regenerates design-baseline/{committer,showcase}/*.json + *.png
npx tsx src/vocabulary.ts   # regenerates VOCABULARY.md + vocabulary.json
```

Flags: `--target=committer|showcase` to run one target only, `--out=<dir>` to
write elsewhere (used below to prove determinism without clobbering the
committed output).

### Determinism proof

```bash
npx tsx src/run.ts --out=/tmp/run2
npx tsx src/compare.ts ../../design-baseline /tmp/run2
```

**committer: byte-identical.** Both committer states (`prelaunch`,
`deploy-error`) × all 9 viewports compared with zero diffs across two full
rebuild+recapture runs.

**showcase: one known-flaky element.** `NavBar`'s active-thumb slider
(`packages/ui/src/components/NavBar/NavBar.tsx`) re-measures its position via
`ResizeObserver` after a viewport resize. The capture tool's `settle()`
(`tools/design-baseline/src/capture.ts`) polls until two consecutive
animation frames produce an identical full-page rect fingerprint specifically
to close this race, and it closes it for the vast majority of
state×viewport×run combinations — but not all of them: a rerun can still show
the thumb's `rect.width` / `styles.right` / `styles.transformOrigin` /
`styles.width` off by sub-pixel amounts (and occasionally one of the two
`<NavBar>` instances mounted on the showcase page — the `Header`'s internal
nav and the standalone "Nav" section demo — settles a frame later than the
other). This is the **only** element affected; every other captured element
(409 of 415 showcase elements) and every committer element is stable. The
compare script correctly flags it — that is the tool working as intended, not
a bug in the compare logic. Documented here rather than silently excluded.
If you need a clean showcase diff, exclude paths containing the NavBar thumb
(the sibling `div:nth-of-type(2)` under each `section:nth-of-type(5)` NavBar
row) before comparing.

## State matrix

### Breakpoints (viewports swept)

Every `@media` width/height threshold actually present, grepped from
`packages/ui/src/**`, `crowdfund-ui/packages/shared/src/**`,
`crowdfund-ui/packages/committer/src/**` on the base SHA above (full
derivation + file citations: `tools/design-baseline/src/breakpoints.ts`):

| id | width×height | probes |
|---|---|---|
| `375` | 375×900 | representative narrow phone, below every threshold |
| `720` | 720×900 | `max-width:720` exact (ParticipantsTable `.tr`) |
| `767` | 767×900 | `max-width:767` exact (pervasive mobile cutover) |
| `768` | 768×900 | `min-width:768` exact (complement of 767) |
| `900` | 900×900 | `max-width:900` exact (MyPosition `.topRow`) |
| `920` | 920×900 | `max-width:920` exact (ParticipantsTable `.headerRow`) |
| `1100` | 1100×900 | `max-width:1100` exact (rightCorner/leftCorner) |
| `1440` | 1440×900 | `max-width:1440` exact (outer shell width caps) |
| `1920` | 1920×900 | representative wide desktop, above every threshold |
| `1024x760` | 1024×760 | `max-height:799` probe (base cascade only — see below) |

`prefers-reduced-motion: reduce` also appears throughout but is not a layout
breakpoint — every capture forces it (`page.emulateMedia`) plus an injected
`animation-duration:0s;transition-duration:0s` stylesheet
(`tools/design-baseline/src/freeze.ts`), so it is never swept as a state axis.

The `max-height:799` rules (`CrowdfundLeftColumn.module.css`,
`InvitesCard.module.css`, `MyPositionSplit`) are all gated behind a *compound*
class (e.g. `.shellOpen.shellShortCardDone`) added only after a JS-driven
interaction (invites list opened, then its enter animation completes) that no
captured state reaches — see "Unreachable states". The `1024x760` viewport is
still swept everywhere so the gap is visible in the data, not just asserted.

### Captured states

**committer** (`design-baseline/committer/<state>@<viewport>.json`), 2 states × 9 viewports = 18:

| state | build env | what it shows |
|---|---|---|
| `prelaunch` | `VITE_NETWORK=local`, `VITE_PRELAUNCH_OPENS_AT=2099-01-01T00:00:00Z`, `VITE_WALLETCONNECT_PROJECT_ID=<placeholder>` | `PreLaunchApp` — the hero's pre-open state (OPENS SOON, "OPENS IN …" countdown, empty network, `PreOpenCard`). No wallet button, no Participate/My-position/Claim. Reads no RPC, no manifest, no indexer — purely `import.meta.env`-driven. |
| `deploy-error` | `VITE_NETWORK=local`, `VITE_WALLETCONNECT_PROJECT_ID=<placeholder>` | Live build (no prelaunch var) with **no deployment manifest written** (`public/api/deployments/` left empty, matching `.gitignore`'s own description of that dir as netlify-build-generated). `loadDeployment()`'s `fetch('/api/deployments/crowdfund-hub.json')` resolves against `vite preview`'s own SPA fallback (an HTML document, not JSON) — `App.tsx`'s `deployError` branch renders "Deployment Not Found". Same-origin fetch only; no chain touched. |

**showcase** (`design-baseline/showcase/<state>@<viewport>.json`), 1 layout state × 9 viewports + 5 interaction states × 2 viewports (375, 1920) = 19:

| state | prepare | what it shows |
|---|---|---|
| `base` | — | Every primitive at rest: Buttons (4 variants × sizes), Tags, NavItem/NavBar, Progress (3 variants), WalletButton, BarTrackTicks, Steps (3 states), Tooltip triggers (closed), WalletItem, color-token swatches. |
| `button-primary-hover` | hover the first "Medium" button | `:hover` on `Button` primary/medium. |
| `button-primary-focus` | real `Tab` keypresses (not `.focus()`) to the first "Medium" button | `:focus-visible` — programmatic `.focus()` does not reliably trigger Chromium's focus-visible heuristic for buttons, so this walks focus with the keyboard instead. |
| `navitem-hover` | hover the first "My position" NavBar item | `:hover` on `NavItem`. |
| `tooltip-centered-open` | hover the "Centered" trigger | Reveals `Tooltip` (`variant="centered"`) — +2 elements vs `base`. |
| `tooltip-rich-open` | Tab-focus the "Rich" trigger | Reveals `Tooltip` (`variant="rich"`, title+description+bullets) — +13 elements vs `base`. |

Total: **37 state×viewport captures**, one `.json` + one full-page `.png` each.

### Unreachable states (and why)

Everything below requires a reachable chain at `http://localhost:8545` —
hardcoded with **no env override** in `crowdfund-ui/packages/committer/src/config/wagmi.ts`
(`anvilChain.rpcUrls`) and `crowdfund-ui/packages/shared/src/lib/network.ts`
(`resolveHubRpcUrls`, local mode). In this run, port 8545 was already bound by
an unrelated, concurrently-running fixturenet container on the shared host —
not a port this tool is allowed to repoint to or commandeer (see the incident
note below) — so none of the following were captured:

- **Live "open" network view** with real sale data (`App.tsx`'s normal
  non-error, non-prelaunch path) — `windowOpen`/`contractState` come from
  `useContractState`, which reads the chain.
- **Wallet connected / disconnected toggle beyond the default disconnected
  state** — RainbowKit's connect flow needs a real or injected EIP-1193
  provider; none was set up (out of scope once the chain itself was
  unreachable — connecting a wallet to a chain with no deployed crowdfund
  contracts would not reach any interesting state anyway).
- **Participate flow** (`ParticipateFlowModal` / `ParticipateFlowV2`) beyond
  its first screen — `openParticipate()` is gated on `windowOpen`, itself
  chain-derived; with no chain, `windowOpen` is never true.
- **Claim flow**, **Details modal** (`ObserveDetailsModal` — gated behind
  `isHeroPage`'s `contractState.loading` bypass, which needs a deployment),
  **My Position** (ready/no-position states — `disconnected` would be the
  only reachable sub-state, and even that needs `windowOpen` to unlock the
  nav tab).
- **Invite-link flow** (`/invite?...`) — pre-validates against chain state.
- **`max-height:799` compound-class layout** (see Breakpoints above) — needs
  an in-app interaction sequence no reachable state exercises.
- **`MockCommitterApp` (`?mock=stressN`)** — `getMockSizeFromUrl()`
  (`src/appNav.tsx`) hard-returns `0` whenever `import.meta.env.DEV` is
  false, i.e. in every production build; this harness is dev-server-only by
  design and cannot be reached from `vite preview`.
- **Light theme** (`[data-theme="light"]` in `tokens.css`) — both targets pin
  dark unconditionally. The showcase's `index.html` hardcodes
  `data-theme="dark"`; the committer's `index.html` inline script forces
  `data-theme="dark"` every load and actively clears any saved `"light"`
  preference. Neither has a toggle. Light theme tokens exist in `tokens.css`
  but are current dead code from this baseline's perspective.

**Incident note:** an initial attempt to stand up a local Anvil + crowdfund
deploy for the live states hit `localhost:8545` already bound by another
agent's fixturenet Docker container on the shared host; `anvil` silently
failed to bind and two `hardhat run --network hub` deploy commands went to
that live chain by mistake before this was caught. Reported to the
dispatching agent; no further chain interaction was attempted after. This is
why the chain-dependent states above are documented as unreachable rather
than attempted via a workaround.

## Vocabulary

See `VOCABULARY.md` (+ machine-readable `vocabulary.json`) — distinct colors,
font tuples, spacing, radii, shadows and breakpoints observed across all 37
captures, matched against `@armada/ui`'s `tokens.css` (`[data-theme="dark"]`,
the only theme ever applied) via real-browser token resolution. Headline
numbers as of this run: **109 distinct values**, **21 unmatched** (no token
produces that exact computed value) — see the file for the full per-category
breakdown, methodology, and known limitations (no `--*-shadow-*` tokens exist
at all; no breakpoint tokens exist at all; Tailwind/shadcn-sourced colors in
the committer, e.g. `oklch(...)` strings from `crowdfund-ui/packages/shared/src/styles/theme.css`,
are correctly unmatched since `tokens.css` never defines them — a real,
separate color system, not a baseline bug).

## Extractor

`tools/design-baseline/src/extract.ts` walks every visible element under
`<body>` (display≠none, visibility≠hidden, non-zero rect) and records:

- **path** — `#id` / `[data-testid]` (global, stops the climb) or
  `role=<role>[name="<accessible name>"]` (only when unique among same-tag
  siblings) per segment, else `tag:nth-of-type(n)`, joined from `body`. ARIA
  live-region roles (`timer`, `status`, `alert`, `log`) never use their name
  as a path segment — a ticking countdown's accessible name changes every
  capture, which made the *path itself* non-deterministic until this was
  excluded.
- **rect** — `getBoundingClientRect()`, rounded to 2 decimals.
- **styles** — the fixed, sorted property list in `src/properties.ts` (color,
  background, border/radius/shadow, typography, spacing, layout, opacity,
  transform, transition — ~85 properties).

Determinism hardening in `capture.ts`'s `settle()`: wait `document.fonts.ready`
(remote Geist/Charis SIL loads were the dominant source of sub-pixel
text-width jitter before this), then poll animation frames until a full-page
rect fingerprint stops changing (closes most, not all, `ResizeObserver` races
— see "Determinism proof" above).
