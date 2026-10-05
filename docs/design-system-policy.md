# Design System Policy (Draft)

Status: **DRAFT — proposal, not yet adopted.** This document does not modify any `CLAUDE.md` or
`.claude/rules/` file. It is a replacement proposal; the sections in §5 are quoted blocks meant to
be pasted into the named files once a human approves this policy, per the root `CLAUDE.md` rule
("Do not edit CLAUDE.md or `.claude/rules/` files autonomously. Propose the change and let the
human decide.").

Base SHA for all citations below: `caf640903d013b2b5122b5fc6b5f5a0aaa741afc` (origin/main,
armada-poc).

---

## 1. Current state

### 1.1 Three copies of the design system today

| Copy | Location | Role |
|---|---|---|
| Mockup | `/Volumes/T7/armada-crowdfund` (external, not available on this host) | Designer's source of truth; components are ported "byte-identical" from here into `@armada/ui`. |
| `@armada/ui` | `packages/ui/src/**` in this repo (armada-poc) | CSS-Modules port of the mockup, consumed by crowdfund-ui apps via npm workspace resolution (`packages/*` workspace glob, `package.json:7`). |
| `armada-interface` `src/design` | `~/code/git_puller/repos/armada-interface/src/design/**` (separate repo) | A **severed vendored copy** of `@armada/ui` — its own tokens, CSS Modules, and typography generator, intentionally disconnected from `packages/ui` so the app is self-contained (`armada-interface/CLAUDE.md:22`, `:34-36`). |

There is no dependency edge between the `@armada/ui` package and the `armada-interface/src/design`
copy; the latter was forked once and now drifts independently. Tokens are edited and typography
regenerated separately in each copy (`armada-interface/CLAUDE.md:35`: "edit semantic.typography
here, then `npm run tokens:typography`" — a second, independent invocation of the same generator
pattern as `packages/ui/scripts/build-typography.mjs`).

### 1.2 Conflicting styling rules, quoted

**`packages/ui/CLAUDE.md`** mandates CSS Modules only, with an explicit prohibition on the
utility-class/Tailwind/shadcn stack used everywhere else in the monorepo:

> "**CSS Modules only.** No Tailwind, no shadcn, no styled-components, no CSS-in-JS. The whole
> point of the package is to escape inherited-class precedence surprises. If you find yourself
> wanting to add Tailwind here, push back." — `packages/ui/CLAUDE.md:41`

> "**No utility libraries for class composition.** … Do not introduce `clsx`, `classnames`,
> `tailwind-merge`, or `cva`. They are the exact source of inheritance surprises we're avoiding."
> — `packages/ui/CLAUDE.md:43-47`

> "**Verbatim ports from the mockup.** When porting a component from
> `/Volumes/T7/armada-crowdfund`, copy the `.tsx` and `.module.css` byte-identical…" —
> `packages/ui/CLAUDE.md:57`

And it explicitly carves out coexistence with the opposite stack rather than resolving the
conflict:

> "## Coexistence with the existing Tailwind/shadcn stack … The crowdfund apps still use Tailwind
> v4 + shadcn primitives via `crowdfund-ui/packages/shared/src/styles/theme.css` and
> `crowdfund-ui/packages/shared/src/components/ui/`. **That stack is untouched.**" —
> `packages/ui/CLAUDE.md:73-75`

`packages/ui/src/components/CLAUDE.md` reinforces the same ban at component-port time:

> "**No class-composition utilities.** Keep the manual `.filter(Boolean).join(' ')` pattern.
> Importing `clsx` or `cva` is forbidden in this package." — `packages/ui/src/components/CLAUDE.md:88`

**`crowdfund-ui/packages/shared/CLAUDE.md`** mandates the opposite stack as the *only* UI-primitive
source for the three apps:

> "All shadcn primitives live in this package under `src/components/ui/` and are consumed by every
> app via the `@armada/crowdfund-shared` barrel export. There is only one shadcn installation in
> the workspace…" — `crowdfund-ui/packages/shared/CLAUDE.md:94`

> "1. From this directory, run `npm_config_legacy_peer_deps=true npx shadcn@latest add <name>
> --yes --overwrite`." — `crowdfund-ui/packages/shared/CLAUDE.md:98`

> "shadcn primitives are **owned code**, not vendored deps — edit the generated file directly.
> Never wrap a primitive just to change its defaults; edit its cva config, markup, or imports in
> place." — `crowdfund-ui/packages/shared/CLAUDE.md:109`

(This block names `cva` as the expected, owned mechanism — directly opposed to
`packages/ui/CLAUDE.md:43-47`'s ban.)

**`crowdfund-ui/CLAUDE.md`** states the committer/observer/admin stack and the dual-primitive
split as an accepted, permanent fact, not a migration-in-progress:

> "All three apps share the same visual theme — dark mode, oklch color tokens, Geist (UI) and
> Charis SIL (display) fonts. The theme CSS was derived from the original crowdfund-frontend (now
> archived in `_legacy/`). shadcn/ui (New York style) provides base UI primitives." —
> `crowdfund-ui/CLAUDE.md:46`

> "- Tailwind v4 via `@tailwindcss/vite` plugin" — `crowdfund-ui/CLAUDE.md:53`

> "## Picking the right primitive across packages … Several primitives have multiple sources in
> this workspace. Get the imports right or you'll get visual regressions or runtime ESM errors…" —
> `crowdfund-ui/CLAUDE.md:57-59`, with the routing table at `crowdfund-ui/CLAUDE.md:61-65` codifying
> that `Button`, `Steps`, `Tooltip`, etc. come from `@armada/ui` while `JoinButton`, `HopPill`,
> `Participate`, etc. come from `@armada/crowdfund-shared` (shadcn-based) — two parallel primitive
> families, permanently, by design.

The committer's actual CSS entry point imports both systems side by side, confirming this is live
today, not residual:

> `@import "tailwindcss";` … `@import "@armada/ui/styles/tokens.css";` …
> `@import "@armada/crowdfund-shared/styles/theme.css";` — `crowdfund-ui/packages/committer/src/index.css:4,17-18`

Root `CLAUDE.md` names the Tailwind+Radix combination as the committed frontend stack, with no
mention of `@armada/ui`/CSS Modules as the target:

> "| Frontend (temporary) | React 19, Vite, Jotai, Tailwind v4, Radix UI |" — `CLAUDE.md:22`

**`armada-interface/CLAUDE.md`** records a third variant: CSS Modules *and* Tailwind together, with
Tailwind scoped to layout only by convention (not tooling-enforced):

> "| Styling | Vendored design system in `src/design` (CSS Modules + tokens, imported as
> `@/design`) + Tailwind v4 (layout glue) | Severed from the shared `@armada/ui` so the app is
> self-contained. No typography Tailwind classes in app code — body baseline (15px Geist 1.5)
> drives everything |" — `armada-interface/CLAUDE.md:22`

> "**No typography Tailwind classes app-wide.** `text-xs`/`font-*`/`tracking-*`/`leading-*`/
> `uppercase` etc. are forbidden — typography flows from the body baseline + `@/design` CSS
> Modules. Layout utilities (`flex`, `grid`, `mx-auto`, `pt-20`, color tokens) are fine." —
> `armada-interface/CLAUDE.md:52`

### 1.3 Net effect

Four different, simultaneously "correct" styling systems exist in the monorepo family today:
Tailwind+shadcn+cva (crowdfund-shared/committer/observer/admin), CSS-Modules-only
(`@armada/ui`), CSS-Modules-plus-scoped-Tailwind (armada-interface), and an unreconciled mockup
source of truth that none of the three copies has a verifiable, automated sync mechanism against
(`packages/ui/src/components/CLAUDE.md:94-96` describes a *manual* `diff -r` re-sync procedure
against a path, `/Volumes/T7/armada-crowdfund`, that does not exist on CI or most dev machines).

---

## 2. Policy (normative)

1. **Single upstream.** `armada-ui` (new repo, see §6 for owner) MUST be the only source of design
   tokens, generated CSS, and typed primitives. The mockup repo MUST NOT be a source any consumer
   or `@armada/ui`/`src/design` copy references directly once this policy lands; design changes
   land in `armada-ui` first.
2. **Vendor via `git subtree`, consume via dependency, one resolution path.** Every consumer
   (armada-poc, armada-interface, the designer's `armada-crowdfund` mockup repo itself) MUST both
   (a) declare `armada-ui` as a workspace/`file:` dependency pointing at the vendored prefix, and
   (b) vendor that exact prefix via `git subtree`. CI MUST verify the vendored prefix is byte-equal
   to what `git subtree split --prefix=<dir>` reproduces against the recorded upstream SHA (see
   §3). Consumers MUST NOT hand-edit the vendored prefix.
3. **Tokens are the only design input.** All visual values (color, spacing, typography, radius,
   shadow) MUST originate in `packages/ui/src/tokens/armada-tokens.json` (Style-Dictionary/
   Token-Studio format) or its `armada-ui` equivalent. No hand-written hex/px/rem literals in
   component code or generated CSS; generators read only from the token file.
4. **CSS is generated, never hand-authored for components.** The CSS consumed by typed primitives
   MUST be produced by a token-driven generator (extended `build-typography.mjs` or a
   vanilla-extract sprinkles/recipes pipeline — open decision, §6). Domain packages MUST NOT ship
   `.css`/`.module.css` files of their own.
5. **Typed primitives are the only styling interface.** Domain code MUST style exclusively through
   `armada-ui`'s React primitives, whose props are closed unions over token values (e.g.
   `spacing: 'sm' | 'md' | 'lg'`, not `string`). Primitives MUST NOT expose a `className` or
   `style` escape hatch to domain callers. (Internal composition between primitives inside
   `armada-ui` itself is implementation detail and out of scope for this rule.)
6. **One styling system.** Tailwind, `tailwind-merge`, `clsx`, `cva`, and shadcn's styling layer
   MUST be removed from every consumer once migration completes (§6 migration order). Radix
   **headless** primitives (behavior/accessibility only, no Radix-shipped CSS) MAY remain as the
   interaction layer under `armada-ui` primitives.
7. **Equivalence is proven, not asserted.** Every migrated screen MUST have a before/after
   comparison of **computed styles as data** (not a visual screenshot diff) against a rendered
   baseline (source TBD, §6) before the legacy CSS Module / Tailwind markup for that screen is
   deleted.

These seven points supersede the conflicting rules quoted in §1.2 in full once adopted; §5 gives
exact replacement text for the three files that currently state the conflicting versions.

---

## 3. Vendoring procedure

### 3.1 Repo layout

- Upstream: new repo `armada-ui` (owner TBD, §6), containing `tokens/`, the generator, and the
  typed primitives — i.e. today's `packages/ui/src` minus the npm-workspace-specific
  `package.json`/`tsconfig` wiring, which stays per-consumer.
- Vendored prefix in **armada-poc**: `packages/ui/vendor/armada-ui` (keeps `packages/ui` as the npm
  workspace package `@armada/ui`, whose `src/index.ts` re-exports from the vendored prefix — this
  preserves the existing `main: "src/index.ts"` consumer-facing entry point documented at
  `packages/ui/CLAUDE.md:6` without consumers changing their import path).
- Vendored prefix in **armada-interface**: `src/design/vendor/armada-ui`, replacing the currently
  hand-forked `src/design` (`armada-interface/CLAUDE.md:34-36`).
- Vendored prefix in the **armada-crowdfund mockup repo**: `src/vendor/armada-ui` (or equivalent) —
  once tokens/primitives move upstream, the mockup becomes a consumer of `armada-ui` for
  shipped/stable primitives, and remains the place genuinely new, unstable primitives are
  prototyped before promotion upstream.

### 3.2 Initial import — `git subtree add`

Run once per consumer repo, from that repo's root:

```bash
git remote add armada-ui-upstream git@github.com:<org>/armada-ui.git
git subtree add --prefix=packages/ui/vendor/armada-ui armada-ui-upstream main --squash
```

(`git subtree add <repository> <remote-ref>` is the two-remote-arg form per `git subtree --help`;
`--squash` keeps the consumer history to one commit per sync instead of importing upstream's full
history.)

### 3.3 Pulling upstream fixes into a consumer

```bash
git subtree pull --prefix=packages/ui/vendor/armada-ui armada-ui-upstream main --squash
```

### 3.4 Pushing a consumer-local fix back upstream

Consumer-local edits to the vendored prefix are forbidden by policy point 2 (§2), but the
mechanism for the one legitimate case — a fix authored *in* the vendor's own repo (`armada-ui`
itself, when it is the working copy) — is:

```bash
git subtree push --prefix=packages/ui/vendor/armada-ui armada-ui-upstream fix-branch
```

For the common case — a fix is needed and discovered while working in a consumer — the change
MUST be made directly against a checkout of `armada-ui`, not against the vendored copy, then
pulled back per §3.3.

### 3.5 Recording the synced SHA — `git subtree split`

After every `add`/`pull`, record the upstream commit the vendored prefix corresponds to, by
reproducing it locally and writing it into the consumer's commit trailer:

```bash
split_sha=$(git subtree split --prefix=packages/ui/vendor/armada-ui)
git commit --amend -m "$(git log -1 --pretty=%B)" -m "git-subtree-split: ${split_sha}"
```

`git subtree split [<local-commit>]` rewrites the consumer history under the prefix into a
synthetic linear history and prints its tip SHA — that SHA is what CI re-derives and compares
against the trailer (§3.6). `git subtree add`/`pull --squash` already embeds a `git-subtree-dir`
/ `git-subtree-split` trailer in the merge commit by default; the amend step above is only needed
if the squash commit's auto-generated trailer was edited away (e.g. by a squash-merge on the PR).

### 3.6 CI check — vendored prefix must match recorded upstream SHA

```bash
#!/usr/bin/env bash
# scripts/check-vendored-armada-ui.sh
set -euo pipefail
PREFIX="packages/ui/vendor/armada-ui"
recorded=$(git log --grep='^git-subtree-split:' -1 --format=%B -- "$PREFIX" \
  | sed -n 's/^git-subtree-split: *//p')
if [ -z "$recorded" ]; then
  echo "No git-subtree-split trailer found for $PREFIX" >&2
  exit 1
fi
actual=$(git subtree split --prefix="$PREFIX" HEAD)
if [ "$actual" != "$recorded" ]; then
  echo "Vendored $PREFIX diverges: recorded $recorded, tree reproduces $actual" >&2
  echo "The vendored prefix was hand-edited; re-sync via git subtree pull instead." >&2
  exit 1
fi
echo "OK: $PREFIX matches recorded upstream $recorded"
```

Add as a job in `.github/workflows/ci.yml`, alongside the existing `typecheck`/`hardhat`/`forge`
jobs (none of which currently touch frontend packages — see `.github/workflows/ci.yml:21-31` for
the pattern to copy: checkout, setup-node, `npm ci --legacy-peer-deps`, then the check script).

### 3.7 Dependency declaration vs. vendored copy — single resolution path

The npm/workspace dependency MUST point at the vendored prefix, not at a registry version, so
there is exactly one copy of `armada-ui` code resolved at build time (the vendored one) and
exactly one thing CI needs to validate (that the vendored tree is unmodified upstream code):

```json
// packages/ui/package.json
{
  "name": "@armada/ui",
  "dependencies": {
    "armada-ui": "file:./vendor/armada-ui"
  }
}
```

`packages/ui/src/index.ts` (the existing consumer-facing entry point, `main: "src/index.ts"` per
`packages/ui/package.json:6`) re-exports everything from `armada-ui`. Consumers never import
`packages/ui/vendor/armada-ui` directly — only through `@armada/ui`'s barrel, exactly as today.

---

## 4. Tooling table

| Tool | Purpose | Status | Owner package |
|---|---|---|---|
| `scripts/build-typography.mjs` (or vanilla-extract sprinkles/recipes) | Generate CSS/TS from `armada-tokens.json` | Exists (typography only, `packages/ui/scripts/build-typography.mjs`); scope extension to all composites is new, pending §6 decision | `armada-ui` upstream |
| `tokens:typography` npm script | Invoke the generator | Exists (`packages/ui/package.json:21`) | `armada-ui` upstream |
| `scripts/check-vendored-armada-ui.sh` | CI gate: vendored prefix == recorded upstream SHA | New (§3.6) | Each consumer repo (armada-poc, armada-interface) |
| `git subtree` (git built-in) | Vendor upstream into consumer prefix, sync both directions | Exists (git builtin); no prior usage in this repo | n/a — git tooling |
| Computed-style equivalence harness | Compare rendered baseline vs. migrated screen as data | New (§2 point 7, open decision §6 on baseline source) | TBD — likely lives in `armada-ui`'s showcase or a new `packages/ui/equivalence` script, decided alongside baseline source |
| `tsc --noEmit` typecheck | Primitive prop-union type safety | Exists (`packages/ui/package.json:20`, `npm run typecheck`) | `@armada/ui` / each consumer |
| shadcn CLI (`npx shadcn@latest add`) | Generate Tailwind/cva primitives | Exists, **to be removed** per policy point 6 | `crowdfund-ui/packages/shared` (removal target) |
| Tailwind v4 / `@tailwindcss/vite` | Utility CSS | Exists, **to be removed** per policy point 6 (Radix headless retained) | `crowdfund-ui/packages/committer` (`index.css:4`), `crowdfund-ui/CLAUDE.md:53` |

---

## 5. Proposed replacement text

Each block below is paired with the current text it replaces, for direct paste once approved.

### 5.1 `packages/ui/CLAUDE.md` — styling sections

**Replaces** `packages/ui/CLAUDE.md:39-77` (the "Strict conventions" and "Coexistence" sections,
including the CSS-Modules-only ban, the verbatim-port rule, and the Tailwind/shadcn coexistence
carve-out):

```markdown
## Strict conventions

**This package vendors `armada-ui` via `git subtree`; see `docs/design-system-policy.md`.**
The vendored prefix (`packages/ui/vendor/armada-ui`) is upstream code — do not hand-edit it.
Local changes to tokens, generators, or primitives are made in a checkout of the `armada-ui`
repo and pulled in per the vendoring procedure in the policy doc.

**Typed primitives only.** Domain code styles exclusively through the primitives re-exported
from `src/index.ts`. Primitives do not accept `className` or `style` props. If a screen needs a
visual option a primitive doesn't expose, add the option as a typed prop upstream in `armada-ui`
— do not work around it locally.

**Tokens are the only design input.** All primitive CSS is generated from
`armada-tokens.json` by the upstream generator. No hand-written CSS files exist in this
package outside the vendored prefix.

**One styling system across the monorepo.** Tailwind, shadcn, `clsx`, `cva`, and
`tailwind-merge` are removed repo-wide (see migration order in `docs/design-system-policy.md`
§6). Radix headless primitives (behavior only, no Radix CSS) may be used inside `armada-ui`
itself for interaction patterns (dropdowns, dialogs) underneath typed primitives.

**ABOUTME header on every non-vendored source file.** Two lines, each starting with
`// ABOUTME: ` or `/* ABOUTME: */` for CSS. CLAUDE.md project convention. Files inside
`vendor/armada-ui` are upstream code and are exempt (headers live in the `armada-ui` repo).

## Coexistence with the legacy Tailwind/shadcn stack (migration in progress)

`crowdfund-ui/packages/shared`'s Tailwind + shadcn primitives are being migrated to `armada-ui`
typed primitives per the order in `docs/design-system-policy.md` §6. Until a given screen's
migration lands and its computed-style equivalence check passes, the legacy primitives remain
in place for that screen only — do not block on a full-repo cutover to start migrating.
```

### 5.2 `crowdfund-ui/packages/shared/CLAUDE.md` — UI Primitives section

**Replaces** `crowdfund-ui/packages/shared/CLAUDE.md:92-113` (the "UI Primitives (shadcn/ui)"
section, including the `npx shadcn@latest add` recipe and the "owned code, edit in place" rule):

```markdown
## UI Primitives

Chrome / layout / form primitives come from `@armada/ui` (vendored `armada-ui`, see
`../../../docs/design-system-policy.md`). This package MUST NOT define its own
`src/components/ui/` shadcn primitives, Tailwind utility classes, or `cva` variants —
those are being removed per the design-system migration order (policy doc §6).

### Adding a primitive

If `@armada/ui` is missing a primitive this package needs, it is added upstream in the
`armada-ui` repo (typed props, token-driven CSS) and pulled in via `git subtree pull`
(policy doc §3.3) — it is not generated locally with shadcn.

### Variant colors

Primitives pull colors exclusively from `armada-ui`'s token CSS custom properties. There is
no local `theme.css` token override; if a value is wrong, fix the token in `armada-tokens.json`
upstream.
```

### 5.3 `crowdfund-ui/CLAUDE.md` — stack line

**Replaces** `crowdfund-ui/CLAUDE.md:53` (`- Tailwind v4 via `@tailwindcss/vite` plugin`) within
the "Conventions" list:

```markdown
- `@armada/ui` typed primitives for all styling (vendored `armada-ui`; see
  `../docs/design-system-policy.md`). No Tailwind, no `className`/`style` escape hatches.
```

And **replaces** `crowdfund-ui/CLAUDE.md:44-46` (the "Style Reference" paragraph naming oklch
tokens + shadcn):

```markdown
## Style Reference

All three apps share the same visual theme, sourced from `@armada/ui`'s token file
(`armada-tokens.json`) and consumed only through its typed React primitives. See
`../docs/design-system-policy.md` for the vendoring mechanism and migration status; until a
screen is migrated it may still render via the legacy shadcn/Tailwind primitives documented in
`packages/shared`'s history.
```

---

## 6. Open decisions

1. **Generator choice: extend `build-typography.mjs` vs. vanilla-extract sprinkles/recipes.**
   `packages/ui/CLAUDE.md:41` currently bans "CSS-in-JS" outright, with the stated rationale being
   to "escape inherited-class precedence surprises" from *runtime* class merging (i.e. the
   `clsx`/`cva`/Tailwind-style runtime-computed class list, where which class wins depends on
   import/insertion order). Vanilla-extract's sprinkles/recipes are **compile-time**, zero-runtime
   CSS-in-TS — classes are generated and hashed at build time, same category as the existing
   generated `typography.css`, not the dynamic composition the ban was written against. Whether
   that distinction is enough to lift the literal "no CSS-in-JS" wording, or whether the simpler
   path of extending the existing hand-rolled `.mjs` generator (more code to maintain, but zero
   new build tooling/deps) is preferred, needs a decision before implementation starts.
2. **Baseline source for computed-style equivalence (policy point 7).** Two candidates: (a) a
   rendered instance of the current armada-poc screen (what ships today, including whatever
   drift from the mockup has accumulated per the "Approved deviations" log in
   `packages/ui/src/components/CLAUDE.md:23-48`), or (b) the designer's mockup
   (`/Volumes/T7/armada-crowdfund`), which is the nominal source of truth per
   `packages/ui/CLAUDE.md:57` but is not reachable from CI or most dev machines today. Using (a)
   is immediately actionable; using (b) requires either mirroring the mockup into a reachable repo
   first or accepting manual, non-CI baseline capture.
3. **`armada-ui` repo owner/org.** Not specified in the shared context for this task. Candidates:
   `ship-armada/armada-ui` (same org as `armada-poc`/`armada-circuits`), or a design-team-owned
   org if the designer's mockup repo migrates there instead. Affects remote URLs in §3.2 and CI
   credentials (parallel to how `armada-circuits` already needs a cross-repo PAT, per
   `.github/workflows/ci.yml:46-47`, `CIRCUITS_RELEASE_TOKEN`).
4. **Migration order.** Proposed, pending approval: (1) stand up `armada-ui` repo from today's
   `packages/ui/src` content, with the vendoring/CI check in place and armada-poc's `@armada/ui`
   switched to consume it with zero behavior change (proves the vendoring mechanism first, before
   any component migrates); (2) migrate `crowdfund-ui/packages/shared`'s Observer-view components
   (`StatsBar`, `TreeView`, `TableView`, …) screen-by-screen, each gated on its own computed-style
   equivalence check, starting with the deprecated-but-still-embedded Observer views since they
   have the smallest blast radius; (3) migrate committer-only screens (action panel, flows) and
   drop the committer's `[data-theme="light"]` override block
   (`crowdfund-ui/packages/committer/src/index.css:28-57`) once its values are absorbed as
   `armada-ui` light-theme tokens; (4) migrate admin; (5) remove Tailwind/shadcn/cva/clsx/
   tailwind-merge dependencies repo-wide and delete `crowdfund-ui/packages/shared/src/components/
   ui/`; (6) reconcile `armada-interface`'s severed `src/design` copy onto the same vendoring
   mechanism, retiring its independent token/typography fork.
