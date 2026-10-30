/**
 * Chain Configuration for Local Devnet
 *
 * Defines chain parameters for our local Anvil instances.
 * These chains are not in the SDK's default network config,
 * so we define them manually.
 *
 * Supports three chains:
 * - Hub Chain (31338) - Where the privacy pool is deployed
 * - Client Chain A (31337) - User-facing chain for deposits/withdrawals
 * - Client Chain B (31339) - Second client chain for multi-chain testing
 */

import { ChainType, Chain } from "@railgun-community/shared-models";

// ============ Chain Definitions ============

/**
 * Hub Chain - Where the privacy pool is deployed
 * Anvil instance on port 8546
 */
export const HUB_CHAIN: Chain = {
  type: ChainType.EVM,
  id: 31338,
};

/**
 * Client Chain A - User-facing chain for deposits/withdrawals
 * Anvil instance on port 8545
 */
export const CLIENT_CHAIN: Chain = {
  type: ChainType.EVM,
  id: 31337,
};

/**
 * Client Chain B - Second client chain for multi-chain testing
 * Anvil instance on port 8547
 */
export const CLIENT_CHAIN_B: Chain = {
  type: ChainType.EVM,
  id: 31339,
};

// ============ RPC Configuration ============

// arn-e7a c5: the RPC base URLs are configurable, not pinned to a fixed host port.
// The e2e job exports HUB_RPC (the deployment's compose service name); the chain
// config follows that env var and falls back to the service name (not localhost:8545).
const gethRpc = process.env.HUB_RPC ?? "http://armada-fixturenet-geth:8545";

export const HUB_RPC = gethRpc;
export const CLIENT_RPC = process.env.CLIENT_RPC ?? gethRpc;
export const CLIENT_B_RPC = process.env.CLIENT_B_RPC ?? gethRpc;

// ============ Helper Functions ============

/**
 * Get chain by ID
 */
export function getChainById(chainId: number): Chain | undefined {
  if (chainId === HUB_CHAIN.id) return HUB_CHAIN;
  if (chainId === CLIENT_CHAIN.id) return CLIENT_CHAIN;
  if (chainId === CLIENT_CHAIN_B.id) return CLIENT_CHAIN_B;
  return undefined;
}

/**
 * Get RPC URL for chain
 */
export function getRpcUrl(chain: Chain): string {
  if (chain.id === HUB_CHAIN.id) return HUB_RPC;
  if (chain.id === CLIENT_CHAIN.id) return CLIENT_RPC;
  if (chain.id === CLIENT_CHAIN_B.id) return CLIENT_B_RPC;
  throw new Error(`Unknown chain ID: ${chain.id}`);
}
