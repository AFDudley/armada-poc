// ABOUTME: Runs `vite build` synchronously and manages a `vite preview` child process,
// ABOUTME: polling until the HTTP port answers before handing control back to the caller.

import { spawn, spawnSync, type ChildProcess } from 'node:child_process'

function delay(ms: number): Promise<void> {
  const { promise, resolve } = Promise.withResolvers<void>()
  setTimeout(resolve, ms)
  return promise
}

export interface PreviewServer {
  port: number
  stop: () => Promise<void>
}

/** Runs `npm run build --workspace=<workspace>` from the repo root with the
 *  given extra env vars layered over the current process env. Throws with the
 *  captured output on a non-zero exit so a broken build fails loudly. */
export function runBuild(repoRoot: string, workspace: string, env: Record<string, string>): void {
  const result = spawnSync(
    'npm',
    ['run', 'build', '--workspace', workspace],
    {
      cwd: repoRoot,
      env: { ...process.env, ...env },
      encoding: 'utf-8',
      stdio: 'pipe',
    },
  )
  if (result.status !== 0) {
    throw new Error(
      `build failed for ${workspace} (exit ${result.status}):\n${result.stdout}\n${result.stderr}`,
    )
  }
}

async function assertPortFree(port: number): Promise<void> {
  try {
    await fetch(`http://127.0.0.1:${port}/`)
  } catch {
    return // nothing answered — free to use
  }
  throw new Error(
    `port ${port} already has something answering on it (not started by this tool) — ` +
    `refusing to reuse it. Pick a different port or free it first.`,
  )
}

/** Polls until `port` answers AND the process we spawned (`child`) is still
 *  alive at that moment — if the child already exited, whatever answered the
 *  port is NOT the server we started (a foreign process raced us onto the
 *  same port), so this throws rather than treating that as success. */
async function waitForOwnPort(
  child: ChildProcess,
  port: number,
  timeoutMs: number,
): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`process exited (code ${child.exitCode}) before port ${port} came up`)
    }
    try {
      const res = await fetch(`http://127.0.0.1:${port}/`)
      if (res.status > 0 && child.exitCode === null) return
    } catch {
      // not up yet
    }
    await delay(200)
  }
  throw new Error(`preview server on port ${port} did not come up within ${timeoutMs}ms`)
}

/** Starts `vite preview --port <port>` for `workspace` and waits until it
 *  answers HTTP requests. The returned `stop()` kills the process group. */
export async function startPreview(
  repoRoot: string,
  workspace: string,
  port: number,
): Promise<PreviewServer> {
  await assertPortFree(port)

  const child = spawn(
    'npm',
    ['run', 'preview', '--workspace', workspace, '--', '--port', String(port), '--strictPort'],
    {
      cwd: repoRoot,
      env: { ...process.env },
      stdio: 'pipe',
      detached: true,
    },
  )
  let out = ''
  child.stdout?.on('data', (d) => (out += String(d)))
  child.stderr?.on('data', (d) => (out += String(d)))

  const stop = async (): Promise<void> => {
    if (child.pid) {
      try {
        process.kill(-child.pid, 'SIGTERM')
      } catch {
        // already dead
      }
    }
    await delay(150)
  }

  try {
    await waitForOwnPort(child, port, 30_000)
  } catch (err) {
    await stop()
    throw new Error(`${(err as Error).message}\noutput so far:\n${out}`)
  }

  return { port, stop }
}
