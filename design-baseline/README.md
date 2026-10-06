# design-baseline

Rendered-style baseline for the `armada-ui` design-system migration (branch
`design/interactive-baseline`, base `origin/main` =
`caf640903d013b2b5122b5fc6b5f5a0aaa741afc`). Generated entirely from
**production builds** (`vite build` + `vite preview`) of two targets,
captured with the Playwright tooling in `tools/design-baseline/`:

- **committer** — `crowdfund-ui/packages/committer`
- **showcase** — `packages/ui/showcase` (`@armada/ui-showcase`)

No app/component source was modified. The committer's chain-dependent states
(sale-open, Participate, invites, finalize, Claim, cancel/refund) are driven
against a **real, freshly deployed crowdfund on an in-container Anvil** — see
"Isolation guarantee" below for why that's safe to run on a shared host, and
"Unreachable states" for the small remainder that still cannot be captured.

## Running it

```bash
tools/design-baseline/docker/run.sh
```

That single command is the only supported entry point. It:

1. Builds `design-baseline-runner:local` from `tools/design-baseline/docker/Dockerfile`.
2. Runs the image with **only** the worktree, the main repo clone's `.git`
   directory (for the worktree's `gitdir:` pointer to resolve), and the
   host's `~/.cache/ms-playwright` (read-only, so Chromium isn't
   re-downloaded) bind-mounted — see "Isolation guarantee".
3. Inside the container, `docker/entrypoint.sh` installs dependencies fresh
   (native addons must match the container's own Node ABI) and execs
   `tools/design-baseline/src/pipeline.ts`, which runs, in order:
   - the two chain-free committer builds (`prelaunch`, `deploy-error`) and
     the showcase capture — no Anvil involved;
   - the three interactive scenarios (`main`, `canceled`, `refund`), each a
     fresh Anvil + fresh crowdfund deploy.
4. Writes every `.json`/`.png` under `design-baseline/{committer,showcase}/`
   and a run record to `design-baseline/runs/<UTC-timestamp>/summary.json`
   (gitHead, docker image id, Anvil's asserted chain identity, pass/fail and
   element counts per state×viewport, duration). `run.sh` also tees the
   container's full stdout/stderr to `<run-dir>/run.log` (gitignored —
   `design-baseline/.gitignore`; `summary.json` stays tracked).

Flags, forwarded straight to `pipeline.ts`: `--scenario=main|canceled|refund`
(interactive debugging — skips the chain-free captures and runs one
scenario only) and `--out=<dir>` (write the whole pipeline's output
elsewhere, used below for the determinism proof — `<dir>` must be inside the
bind-mounted worktree, since nothing else is visible to the container).

### Isolation guarantee

`docker/run.sh` never publishes a container port and never uses
`--network host` (`--network bridge` only). Nothing this tool does can ever
reach `http://127.0.0.1:8545` on the **host** — that port is already bound by
an unrelated, concurrently-running fixturenet container on this shared
machine, and must never be touched by this tool (hard constraint). Inside
the container, `127.0.0.1:8545` is the container's own network namespace —
Anvil started there is a different `8545` entirely, unreachable from, and
unaware of, the host's.

Before any deploy transaction, `anvil.ts`'s `assertChainIdentity()` queries
the RPC endpoint this process is about to use and asserts `eth_chainId ===
"0x7a69"` (31337) **and** `web3_clientVersion` contains `"anvil"`, aborting
the whole pipeline otherwise. This is the hard safety gate for "is this
really the Anvil I just started, not some other process that happens to
answer on the port" — it is recorded in every run's `summary.json` as
`anvilIdentity`.

No mnemonic or private key is written anywhere in this tool's source.
`startAnvil()` passes neither `--mnemonic` nor `--mnemonic-seed-unsafe` —
Anvil's own built-in default (used whenever neither flag is given)
deterministically derives the same well-known test accounts every start,
which happens to be the same account `config/local.env`'s already-committed
`DEPLOYER_PRIVATE_KEY` controls. `getAccounts()` reads the resulting
addresses back via `eth_accounts` rather than deriving or duplicating them.

### Wallet-injection approach

Interactive states need a "connected wallet" without any real browser
extension or client-side cryptography. `wallet.ts`'s `installInjectedWallet`
installs a thin `window.ethereum` shim (as a Playwright init script, active
across every navigation) that mimics just enough of Rainbow's injected-wallet
fingerprint (`isRainbow: true`) for RainbowKit's `rainbowWallet` connector to
treat it as installed. The shim answers the handful of methods a real wallet
answers locally (accounts, chain id, chain-switch no-ops) and forwards
everything else — `eth_sendTransaction`, `personal_sign`,
`eth_signTypedData_v4` included — verbatim to Anvil's own JSON-RPC endpoint,
which holds the real private key for every one of its mnemonic-derived
accounts and signs/sends directly. No seed phrase ever touches the browser
page. The same module also installs a deterministic replacement for
`crypto.getRandomValues` so the invite-link flow's EIP-712 nonce doesn't
introduce its own run-to-run variance.

## State matrix

### Viewports swept

Same breakpoint derivation as before (grepped `@media` thresholds across
`packages/ui/src/**`, `crowdfund-ui/packages/shared/src/**`,
`crowdfund-ui/packages/committer/src/**`; full citations in
`tools/design-baseline/src/breakpoints.ts`):

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

Two viewport **sets** are used, defined in `breakpoints.ts`:

- `VIEWPORTS` — all nine widths above, for layout states (hero, My Position,
  canceled/refund hero).
- `INTERACTION_VIEWPORTS` — just `375` and `1920`, for interaction/modal
  states (Participate review/confirmation, invite screens, Claim steps)
  where sweeping all nine mostly re-proves the same result since hover/focus
  do not themselves change at most layout breakpoints.

### Captured states

**committer**, `design-baseline/committer/<state>@<viewport>.json`:

| state | viewport set | how it's reached |
|---|---|---|
| `prelaunch` | all 9 | Chain-free build, `VITE_PRELAUNCH_OPENS_AT=2099-01-01T00:00:00Z` — `PreLaunchApp` renders the hero's pre-open countdown state. No RPC/manifest/indexer reads. |
| `deploy-error` | all 9 | Chain-free build, live config, **no deployment manifest present** — `loadDeployment()` 404s against the committer's own same-origin `/api/deployments/crowdfund-hub.json` and `App.tsx` renders "Deployment Not Found". `captureCommitter` removes any `public/api/deployments/` directory before this build so a stale manifest left by an earlier interactive run can never leak in (see "Determinism" below — this was a real bug found and fixed in this pass). |
| `sale-open` | all 9 | **main** scenario: fresh deploy, chain advanced past `windowStart`, nobody has committed yet, wallet disconnected. |
| `wallet-connected-no-position` | all 9 | **main**: wallet connects before being whitelisted. |
| `participate-review` | interaction | **main**: wallet seeded (`addSeeds`), Participate flow opened, max amount filled, Review screen. |
| `participate-confirmation` | interaction | **main**: `approveAndCommit()` — real `approve` + `commit` transactions through the injected wallet, then the post-commit confirmation screen. |
| `my-position-seeded` | all 9 | **main**: `/?view=myposition` after the real commit above. |
| `invite-method-picker` | interaction | **main**: My Position → the hop's "N invite(s) left" button → share-method menu. |
| `invite-link-generated` | interaction | **main**: "Share link" → "Create link" → EIP-712-signed invite link extracted from the confirmation screen (read immediately — it auto-dismisses). |
| `invite-redemption-landing` | all 9 | **main**: a second wallet opens the generated `/invite?...` URL (standalone chrome, no header/wallet pill of its own). |
| `invite-redemption-review` | interaction | **main**: "Join now" → Review, after passing the on-chain USDC-balance gate (`fundUsdc`). |
| `invite-redemption-confirmation` | interaction | **main**: real commit through the invite flow. |
| `finalized-success` | all 9 | **main**: after pushing real demand past `MIN_SALE` and finalizing — see "hop-0 47% cap" below. |
| `claim-intro` / `claim-delegate` / `claim-review` / `claim-done` | interaction | **main**: `/?view=claim`'s four-step Claim flow, each a real on-chain action (delegate choice → review → `Claim ARM` tx → done). |
| `my-position-claimed` | all 9 | **main**: `/?view=myposition` after claiming. |
| `canceled-hero` | all 9 | **canceled**: fresh deploy, one real commit, then `ArmadaCrowdfund.cancel()` (security-council action) mid-window — `phase === Canceled`. |
| `canceled-claim-intro` / `canceled-claim-done` | interaction | **canceled**: the resulting USDC-refund Claim flow. |
| `canceled-my-position` | all 9 | **canceled**: `/?view=myposition` after the refund claim. |
| `refund-mode-hero` | all 9 | **refund**: fresh deploy, a single small commit (well under `MIN_SALE`), window closes naturally, `finalize()` enters `refundMode` (`phase` stays `Finalized`, distinct code path from `canceled`). |
| `refund-mode-claim-intro` / `refund-mode-claim-done` | interaction | **refund**: the refund Claim flow. |
| `refund-mode-my-position` | all 9 | **refund**: `/?view=myposition` after the refund claim. |

**showcase**, `design-baseline/showcase/<state>@<viewport>.json`, unchanged
from the chain-free baseline — 1 layout state × 9 viewports + 5 interaction
states × 2 viewports:

| state | prepare | what it shows |
|---|---|---|
| `base` | — | Every primitive at rest: Buttons, Tags, NavItem/NavBar, Progress, WalletButton, BarTrackTicks, Steps, Tooltip triggers (closed), WalletItem, color-token swatches. |
| `button-primary-hover` | hover the first "Medium" button | `:hover` on `Button` primary/medium. |
| `button-primary-focus` | real `Tab` keypresses to the first "Medium" button | `:focus-visible` (programmatic `.focus()` doesn't reliably trigger Chromium's heuristic for buttons). |
| `navitem-hover` | hover the first "My position" NavBar item | `:hover` on `NavItem`. |
| `tooltip-centered-open` | hover the "Centered" trigger | Reveals `Tooltip` (`variant="centered"`). |
| `tooltip-rich-open` | Tab-focus the "Rich" trigger | Reveals `Tooltip` (`variant="rich"`, title+description+bullets). |

**Total: 155 committer state×viewport captures + 19 showcase = 174**, one
`.json` + one full-page `.png` each.

### The hop-0 47% allocation cap and the `inviteAndCommit` workaround

Reaching `finalized-success` (and everything downstream of it — Claim) needs
total **allocated** demand above `MIN_SALE` ($1,000,000), not just committed
demand. `ArmadaCrowdfund._computeHopAllocations` ceiling-caps hop-0's own
allocation at 47% of `saleSize` regardless of oversubscription — at
`BASE_SALE` that ceiling is only $564,000, under `MIN_SALE` on its own no
matter how many hop-0 participants commit. Crossing the threshold requires
genuine hop-1 demand too, and hop-1 participation is gated on an **on-chain
`invite()`** from an already-eligible hop-0 address — there is no way to
fund a hop-1 commit without first inviting that address for real.

The `main` scenario's `chainPlan.ts` therefore runs a two-step
`runChainPlan`: `bulkCommit` seeds 40 hop-0 participants at $15,000 each
($600,000), then `inviteAndCommit` has each of those 40 invite 3 fresh
addresses on-chain and commits each invitee at the $4,000 hop-1 cap (120
participants × $4,000 = $480,000) — $1,099,000 total allocated, clearing
`MIN_SALE`. Participant indices are kept within `hardhat.config.ts`'s `hub`
network account limit (`count: 200`): `bulkCommit` uses indices 20–59,
`inviteAndCommit`'s invitees use 60–179.

## Unreachable states (and why)

With a real chain now reachable, only two gaps remain from the chain-free
baseline:

- **Light theme** (`[data-theme="light"]` in `tokens.css`) — both targets pin
  dark unconditionally. The showcase's `index.html` hardcodes
  `data-theme="dark"`; the committer's `index.html` inline script forces
  `data-theme="dark"` every load and actively clears any saved `"light"`
  preference. Neither has a toggle. Light theme tokens exist in `tokens.css`
  but are dead code from this baseline's perspective.
- **`MockCommitterApp` (`?mock=stressN`)** — `getMockSizeFromUrl()`
  (`src/appNav.tsx`) hard-returns `0` whenever `import.meta.env.DEV` is
  false, i.e. in every production build; this harness is dev-server-only by
  design and cannot be reached from `vite preview` regardless of chain
  availability.

The `max-height:799` compound-class layout gap from the chain-free baseline
is also still unreached (no captured state opens then collapses the invites
list, the specific interaction sequence that adds the compound class) — not
re-litigated here since it was already documented and the gap is unchanged.

## Determinism

### Chain-free states vs. the original a73fd11b baseline

Compared with `compare.ts` against the `prelaunch`/`deploy-error` captures
committed at `a73fd11b` (the first chain-free baseline, same build config):

- **`deploy-error`: byte-identical**, all 9 viewports, zero diffs. This
  required a real fix: a stale `public/api/deployments/crowdfund-hub.json`
  left on disk by an *earlier, unrelated* interactive session (not
  gitignored out of existence, since `.gitignore` only excludes it from
  tracking, not from persisting on disk) made the `deploy-error` build find
  a manifest and render the live app instead of its 404 screen — a
  determinism bug independent of this run's own code. `captureCommitter`
  (`src/run.ts`) now unconditionally removes `public/api/deployments/`
  before either chain-free build, so the output no longer depends on what
  ran on the host before it.
- **`prelaunch`: one small pre-existing residual**, unrelated to the fix
  above — the countdown widget's digit glyphs render with a ~0.14px
  sub-pixel width difference (`166.438px` vs `166.297px`) between this
  container's font rendering and the one that produced `a73fd11b`, cascading
  into a matching sub-pixel shift of one sibling element's `x`. 6–7 diff
  lines per viewport, all `rect.width` / `styles.width` /
  `styles.transformOrigin` / `rect.x` — never content, color, or structural.
  Same residual class as below.

### Two full pipeline runs, same host (this pass)

`docker/run.sh` was run twice end-to-end (`design-baseline/runs/
2026-10-06T21-47-19Z` and `2026-10-06T22-00-50Z`), the second with
`--out=` pointed at a scratch directory, then diffed with `compare.ts`:

- **Zero structural, content, or color differences.** No element
  present/absent in only one run, no text/attribute/color value differs.
- **556 positional/dimensional residuals**, confined entirely to `rect.x`,
  `rect.y`, `rect.width`, and the `styles.{top,left,right,bottom,width,
  transformOrigin}` properties they derive from — never any other style
  property. Maximum delta observed: ~4px. Affected states: `my-position-
  seeded`, `my-position-claimed`, `canceled-my-position`, `refund-mode-
  my-position`, `canceled-hero`, `canceled-claim-intro`, `invite-method-
  picker`, `invite-redemption-confirmation` (committer) and `base`,
  `button-primary-hover`, `button-primary-focus`, `navitem-hover`,
  `tooltip-centered-open`, `tooltip-rich-open` (showcase).
- **Root cause: sub-pixel font-shaping jitter**, the same class as the
  `prelaunch` residual above — a run-to-run difference in exactly how
  headless Chromium's text shaper measures certain glyph runs (most visibly
  numeric/formatted text: USDC amounts, wallet addresses, countdown digits),
  which then cascades through flex/absolute layout into a uniform small
  shift of everything positioned relative to that text. It is below the
  layer `freeze.ts`'s animation/transition freeze and `capture.ts`'s
  `document.fonts.ready` + animation-frame settle loop can address — those
  close every *timing* race (confirmed: zero diffs on every purely-static
  chain-free element, in both the `a73fd11b` comparison and this one) but
  not font-cache-state variance between container invocations.
- Not fixable by further freezing: the same font files, the same frozen
  animations, the same settled-fingerprint gate — only the measured glyph
  width itself varies by a sub-pixel amount between runs. Documented here
  rather than silently excluded; re-run `compare.ts` between any two
  `design-baseline/runs/*` output trees to reproduce.

## Vocabulary

See `VOCABULARY.md` (+ machine-readable `vocabulary.json`) — distinct
colors, font tuples, spacing, radii, shadows observed across all 174
committer + showcase captures, matched against `@armada/ui`'s `tokens.css`
(`[data-theme="dark"]`, the only theme ever applied) via real-browser token
resolution. Headline numbers as of this run: **170 distinct values, 48
unmatched** (up from the chain-free-only baseline's 109 distinct / 21
unmatched at `a73fd11b` — the +61 distinct values come almost entirely from
newly-captured interactive states: wallet addresses, USDC/ARM amount
formatting, invite-link text, and the many new component instances in
Participate/Invite/Claim/My-Position screens that chain-free captures never
rendered). See the file for the full per-category breakdown, methodology,
and known limitations (no `--*-shadow-*` tokens exist at all; no breakpoint
tokens exist at all; Tailwind/shadcn-sourced colors in the committer, e.g.
`oklch(...)` strings from `crowdfund-ui/packages/shared/src/styles/theme.css`,
are correctly unmatched since `tokens.css` never defines them).

## Run records

Every `docker/run.sh` invocation writes `design-baseline/runs/<UTC-
timestamp>/summary.json` — git HEAD, the built Docker image id, Anvil's
asserted chain identity, per-phase pass/fail with per-state×viewport element
counts, and total duration. `run.log` (the container's full stdout/stderr,
tee'd by `run.sh`) sits alongside it but is gitignored
(`design-baseline/.gitignore`) — large and non-deterministic throughout, the
structured `summary.json` is the record that's committed.

Runs on disk as of this pass: `2026-10-06T21-32-43Z` (first full run — found
the stale-manifest bug described above), `2026-10-06T21-47-19Z` (full run
after the fix, this is the committed capture data), `2026-10-06T22-00-50Z`
(second full run, `--out=` scratch dir, used for the determinism proof
above; its own captures were not kept — only its `summary.json`).

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
rect fingerprint stops changing. This closes every timing-dependent race
(`ResizeObserver`, font-load, entrance-animation) — the residual sub-pixel
differences documented above are a separate, font-shaping-level source this
settle loop cannot close (see "Determinism").
