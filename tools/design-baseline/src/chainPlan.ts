// ABOUTME: Shell-out helpers for the interactive baseline's chain side — reuses the repo's own
// ABOUTME: `npm run deploy:*` scripts verbatim (via `source config/local.env`) for CCTP/governance/
// ABOUTME: crowdfund deployment, and drives `tools/design-baseline/chain/exec.ts` for every
// ABOUTME: scenario-specific mutation (seeding, time-warp, bulk commits, finalize, cancel).

import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import path from 'node:path'

export interface CrowdfundDeploymentManifest {
  chainId: number
  deployer: string
  deployBlock?: number
  contracts: {
    armToken: string
    usdc: string
    crowdfund: string
    treasury?: string
    governor?: string
  }
  config: {
    baseSale: string
    maxSale: string
    minSale: string
    armPrice: string
    armFunded: string
  }
  timestamp: string
}

export type ChainAction =
  | { op: 'addSeeds'; indices: number[] }
  | { op: 'advanceToWindowStart' }
  | { op: 'advancePastWindowEnd' }
  | { op: 'bulkCommit'; startIndex: number; count: number; hop: number; capUsd: number }
  | { op: 'finalize' }
  | { op: 'cancel' }
  | { op: 'printState' }

/** Runs `command` through a login-ish bash that first sources `config/local.env`, exactly the
 *  way a human running this repo's local dev workflow would (`source config/local.env && npm run
 *  setup`) — reuses that file as the single source of local deploy config instead of
 *  re-declaring it here. */
function runWithLocalEnv(repoRoot: string, command: string): void {
  execFileSync('bash', ['-lc', `source config/local.env && ${command}`], {
    cwd: repoRoot,
    stdio: 'inherit',
  })
}

/** Deploys CCTP (mock USDC) + governance (ARM token/treasury) + crowdfund to the hub, in the
 *  order `npm run setup:crowdfund` uses — reusing those exact scripts, not reimplementing them. */
export function deployCrowdfundScenario(repoRoot: string): void {
  runWithLocalEnv(repoRoot, 'npm run deploy:cctp:hub')
  runWithLocalEnv(repoRoot, 'npm run deploy:governance')
  runWithLocalEnv(repoRoot, 'npm run deploy:crowdfund')
}

export function readCrowdfundDeployment(repoRoot: string): CrowdfundDeploymentManifest {
  const file = path.join(repoRoot, 'deployments', 'crowdfund-hub.json')
  return JSON.parse(readFileSync(file, 'utf-8')) as CrowdfundDeploymentManifest
}

/** Executes an ordered plan of chain actions against the currently-deployed crowdfund via
 *  `chain/exec.ts` (see that file for the full action set). */
export function runChainPlan(repoRoot: string, plan: ChainAction[]): void {
  execFileSync(
    'bash',
    ['-lc', 'source config/local.env && npx hardhat run tools/design-baseline/chain/exec.ts --network hub'],
    {
      cwd: repoRoot,
      stdio: 'inherit',
      env: { ...process.env, CHAIN_PLAN: JSON.stringify(plan) },
    },
  )
}
