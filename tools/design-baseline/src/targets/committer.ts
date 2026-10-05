// ABOUTME: Committer target — two production builds (pre-launch, live-with-no-manifest),
// ABOUTME: each a single chain-free, deterministic state. See design-baseline/README.md "Unreachable states".

import { VIEWPORTS } from '../breakpoints.ts'
import type { Viewport } from '../breakpoints.ts'

export const COMMITTER_WORKSPACE = '@armada/crowdfund-committer'
export const COMMITTER_DIR = 'crowdfund-ui/packages/committer'

export interface CommitterState {
  /** Output state name — also the build id (one state per build here). */
  name: string
  path: string
  viewports: readonly Viewport[]
  /** VITE_* build-time env for this build (merged over process.env). */
  env: Record<string, string>
  description: string
}

/**
 * Both states are built WITHOUT touching a chain: `prelaunch` reads no RPC at
 * all (PreLaunchApp — see src/PreLaunchApp.tsx), and `deploy-error` never gets
 * past App.tsx's `loadDeployment()` 404 (no `public/api/deployments/` file is
 * written for this build) so it never reaches the hooks that would call
 * `createProvider(getHubRpcUrls())` against `http://localhost:8545`.
 *
 * Every other committer state (live network view with real sale data, wallet
 * connect, Participate/Claim/Details modals, My position) requires a reachable
 * local chain at `localhost:8545` — hardcoded with no override in
 * `src/config/wagmi.ts` and `crowdfund-ui/packages/shared/src/lib/network.ts`
 * (`resolveHubRpcUrls`) — and is documented as NOT reachable in this baseline;
 * see design-baseline/README.md.
 */
export const COMMITTER_STATES: readonly CommitterState[] = [
  {
    name: 'prelaunch',
    path: '/',
    viewports: VIEWPORTS,
    env: {
      VITE_NETWORK: 'local',
      // RainbowKit's wagmi config (src/config/wagmi.ts) requires a non-empty
      // projectId in every PRODUCTION build regardless of network mode —
      // validateEnv's "local is exempt" leniency does not reach wagmi.ts,
      // which falls back to '' (not the dev placeholder) once import.meta.env.PROD
      // is true. A placeholder is sufficient: nothing in any captured state
      // actually opens the WalletConnect modal.
      VITE_WALLETCONNECT_PROJECT_ID: 'design-baseline-placeholder',
      // Fixed far-future instant — any value is fine (no chain reads it), but
      // fixed keeps the build byte-reproducible across regenerate runs.
      VITE_PRELAUNCH_OPENS_AT: '2099-01-01T00:00:00Z',
    },
    description:
      'Countdown-only pre-launch build (VITE_PRELAUNCH_OPENS_AT set) — PreLaunchApp renders the ' +
      "hero's pre-open state (OPENS SOON, countdown, empty network) with no wallet/RPC/indexer reads.",
  },
  {
    name: 'deploy-error',
    path: '/',
    viewports: VIEWPORTS,
    env: {
      VITE_NETWORK: 'local',
      VITE_WALLETCONNECT_PROJECT_ID: 'design-baseline-placeholder',
    },
    description:
      'Live build (no VITE_PRELAUNCH_OPENS_AT) with no deployment manifest present — ' +
      "loadDeployment() 404s against the committer's own /api/deployments/crowdfund-hub.json " +
      '(same-origin, no chain involved) and App.tsx renders its "Deployment Not Found" error screen.',
  },
] as const
