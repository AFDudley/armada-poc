// ABOUTME: Writes the per-scenario crowdfund deployment manifest into the committer's served
// ABOUTME: tree. The manifest is fetched at RUNTIME (`loadDeployment()` in
// ABOUTME: src/config/deployments.ts), not baked into the JS bundle, so swapping it on disk
// ABOUTME: between scenarios lets one `vite build` + one `vite preview` serve every scenario —
// ABOUTME: only `public/api/deployments/crowdfund-hub.json` (pre-build) / `dist/api/deployments/
// ABOUTME: crowdfund-hub.json` (post-build, what `vite preview` actually serves) changes.

import { mkdirSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { COMMITTER_DIR } from './targets/committer.ts'
import type { CrowdfundDeploymentManifest } from './chainPlan.ts'

const MANIFEST_FILENAME = 'crowdfund-hub.json'

function writeManifestTo(repoRoot: string, subdir: 'public' | 'dist', manifest: CrowdfundDeploymentManifest): void {
  const dir = path.join(repoRoot, COMMITTER_DIR, subdir, 'api', 'deployments')
  mkdirSync(dir, { recursive: true })
  writeFileSync(path.join(dir, MANIFEST_FILENAME), JSON.stringify(manifest, null, 2))
}

/** Pre-build copy — `vite build` copies `public/` into `dist/` verbatim, so this only needs to
 *  exist (any well-formed scenario manifest) before the one build the whole pipeline runs. */
export function writeManifestForBuild(repoRoot: string, manifest: CrowdfundDeploymentManifest): void {
  writeManifestTo(repoRoot, 'public', manifest)
}

/** Post-build swap — overwrites the file `vite preview` actually serves, so each new scenario's
 *  contract addresses take effect on the NEXT navigation without rebuilding or restarting the
 *  preview server (the committer re-fetches the manifest fresh on every full page load — see
 *  `config/deployments.ts`'s module-level `cachedDeployment`, which resets with the JS module
 *  graph on each navigation). */
export function writeManifestForPreview(repoRoot: string, manifest: CrowdfundDeploymentManifest): void {
  writeManifestTo(repoRoot, 'dist', manifest)
}
