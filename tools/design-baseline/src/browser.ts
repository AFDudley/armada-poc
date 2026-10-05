// ABOUTME: Launches Chromium from whatever revision is already cached in
// ABOUTME: ~/.cache/ms-playwright — avoids depending on headless_shell matching
// ABOUTME: the exact @playwright/test patch version (host only has the full chrome binary cached).

import { existsSync, readdirSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { chromium, type Browser } from '@playwright/test'

function findCachedChromiumExecutable(): string | undefined {
  const cacheDir = path.join(os.homedir(), '.cache', 'ms-playwright')
  if (!existsSync(cacheDir)) return undefined
  const revisions = readdirSync(cacheDir)
    .filter((name) => /^chromium-\d+$/.test(name))
    .sort()
    .reverse() // highest revision first
  for (const revision of revisions) {
    const exe = path.join(cacheDir, revision, 'chrome-linux64', 'chrome')
    if (existsSync(exe)) return exe
  }
  return undefined
}

/** Launches Chromium, preferring the full `chrome-linux64/chrome` binary
 *  already cached on this host over Playwright's own headless_shell download
 *  (which may be a revision newer than what is cached). Falls back to
 *  Playwright's default resolution if nothing is found locally. */
export async function launchChromium(): Promise<Browser> {
  const executablePath = findCachedChromiumExecutable()
  return chromium.launch(executablePath ? { executablePath } : {})
}
