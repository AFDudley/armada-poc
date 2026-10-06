// ABOUTME: Injected EIP-1193 wallet provider for the interactive committer baseline — a thin
// ABOUTME: shim that forwards every RPC call straight to the in-container Anvil (which holds the
// ABOUTME: real private keys for its mnemonic-derived accounts), so "connecting a wallet" and
// ABOUTME: signing/sending transactions needs no client-side cryptography at all.

import type { Page } from '@playwright/test'

/**
 * Installed as `window.ethereum` before every navigation. Mimics just enough of Rainbow's
 * injected-wallet fingerprint (`isRainbow: true`) for RainbowKit's `rainbowWallet` connector to
 * mark it "installed" and use wagmi's plain `injected()` connector against it directly —
 * deliberately NOT masquerading as MetaMask, which RainbowKit instead routes through
 * `@metamask/sdk` (extra detection/handshake machinery this shim doesn't need and that adds
 * nondeterminism risk for no benefit here).
 *
 * `request()` special-cases only the handful of methods a real wallet answers locally
 * (accounts, chainId, chain-switch no-ops); everything else — including
 * `eth_sendTransaction`, `personal_sign`, and `eth_signTypedData_v4` — is forwarded verbatim to
 * Anvil's JSON-RPC endpoint, which holds the actual private key for every one of its
 * mnemonic-derived accounts and signs/sends directly. No seed phrase, no local ECDSA, no
 * extension — just a passthrough.
 */
function installInjectedWalletInBrowser(opts: { rpcUrl: string; address: string; chainIdHex: string }): void {
  const { rpcUrl, address, chainIdHex } = opts
  type Listener = (...args: unknown[]) => void
  const listeners: Record<string, Listener[]> = {}
  let nextId = 1

  const provider = {
    isRainbow: true,
    chainId: chainIdHex,
    networkVersion: String(parseInt(chainIdHex, 16)),
    selectedAddress: address,
    isConnected: () => true,
    on(event: string, handler: Listener) {
      ;(listeners[event] ??= []).push(handler)
    },
    removeListener(event: string, handler: Listener) {
      const arr = listeners[event]
      if (!arr) return
      const idx = arr.indexOf(handler)
      if (idx >= 0) arr.splice(idx, 1)
    },
    async request({ method, params }: { method: string; params?: unknown[] }): Promise<unknown> {
      if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [address]
      if (method === 'eth_chainId') return chainIdHex
      if (method === 'wallet_switchEthereumChain' || method === 'wallet_addEthereumChain') return null
      if (method === 'wallet_revokePermissions') return null

      const res = await fetch(rpcUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: nextId++, method, params: params ?? [] }),
      })
      const json = (await res.json()) as { result?: unknown; error?: { code: number; message: string; data?: unknown } }
      if (json.error) {
        const err = new Error(json.error.message) as Error & { code?: number; data?: unknown }
        err.code = json.error.code
        err.data = json.error.data
        throw err
      }
      return json.result
    },
  }

  // Named binding first (not an inline cast-then-access) — `window` has no `ethereum`
  // property in TS's DOM lib, so this widens it to a type that does before assigning.
  const win = window as typeof window & { ethereum: unknown }
  win.ethereum = provider
}

/**
 * Deterministic replacement for `crypto.getRandomValues` — the invite-link nonce
 * (`lib/inviteLinks.ts randomSafeNonce()`) is the only call site in the captured flows that
 * consumes real randomness. A fixed, counting byte stream makes every generated nonce (and
 * therefore the generated invite link's exact bytes) identical across repeated pipeline runs,
 * without touching `Date.now()`/timers (left real — see `README.md` "Determinism" for why
 * freezing those was rejected: the commit-window countdown's `setTimeout`-driven step
 * transitions would never fire under a paused virtual clock).
 */
function installDeterministicRandomInBrowser(): void {
  let counter = 0
  crypto.getRandomValues = (<T extends ArrayBufferView | null>(array: T): T => {
    if (array === null) return array
    const view = new Uint8Array(array.buffer, array.byteOffset, array.byteLength)
    for (let i = 0; i < view.length; i++) {
      view[i] = (counter++ * 2654435761) % 256
    }
    return array
  }) as typeof crypto.getRandomValues
}

/**
 * Installs the injected wallet + deterministic RNG shims on `page`, active for every subsequent
 * navigation (Playwright re-runs init scripts on each new document). Call once per
 * `BrowserContext` (or per `Page` — either survives navigations) before the first `goto`.
 */
export async function installInjectedWallet(
  page: Page,
  opts: { rpcUrl: string; address: string; chainId: number },
): Promise<void> {
  const chainIdHex = '0x' + opts.chainId.toString(16)
  await page.addInitScript(installDeterministicRandomInBrowser)
  await page.addInitScript(installInjectedWalletInBrowser, { rpcUrl: opts.rpcUrl, address: opts.address, chainIdHex })
}
