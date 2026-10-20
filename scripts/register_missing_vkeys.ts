// ABOUTME: One-shot script — registers every (nullifiers, commitments) verification key in
// ABOUTME: TESTING_ARTIFACT_CONFIGS against a live PrivacyPool deployment, skipping any pair
// ABOUTME: already on-chain. Idempotent: safe to re-run, no redeploy required.
//
// Problem this exists for: `PrivacyPool: Verification key not set` reverts when a user
// transact() proof has a (N, M) shape the deployer never registered. Adding new pairs at
// runtime is owner-only but otherwise plumbing-free — VerifierModule.setVerificationKey
// goes through the proxy's delegatecall surface, mutating the proxy's storage.
//
// Usage:
//   VITE_NETWORK=local|sepolia npm run vkeys:register
// (Or via the dedicated env-bound npm scripts; see package.json.)

import { ethers } from "hardhat";
import {
  formatVKeyForSolidity,
  getVKey,
  TESTING_ARTIFACT_CONFIGS,
  type ArtifactConfig,
} from "../lib/artifacts";
import { createNonceManager, loadDeployment } from "./deploy-utils";
import {
  getDeployEnv,
  getPrivacyPoolDeploymentFile,
  isLocal,
} from "../config/networks";

async function main(): Promise<void> {
  const env = getDeployEnv();
  const filename = getPrivacyPoolDeploymentFile("hub");
  const manifest = loadDeployment(filename);
  if (!manifest) {
    throw new Error(
      `No PrivacyPool hub deployment found at deployments/${filename}. Run the hub deploy first.`,
    );
  }
  const privacyPoolAddr = manifest.contracts?.privacyPool;
  if (!privacyPoolAddr) {
    throw new Error(`${filename} missing contracts.privacyPool`);
  }

  console.log("=".repeat(60));
  console.log("  VerifyingKey Registrar");
  console.log(`  Environment: ${env}${isLocal() ? " (local Anvil)" : ""}`);
  console.log(`  PrivacyPool: ${privacyPoolAddr}`);
  console.log("=".repeat(60));

  const [signer] = await ethers.getSigners();
  console.log(`  Signer:      ${signer.address}`);

  // Attach to the PrivacyPool proxy. The pool exposes both `getVerificationKey` and
  // `setVerificationKey` as forwarders to VerifierModule (delegatecall), so the PrivacyPool
  // ABI is the right typing here — same pattern as `load_verification_key_1x1.ts`.
  const pool = await ethers.getContractAt(
    "PrivacyPool",
    privacyPoolAddr,
    signer,
  );

  // Pre-scan: which pairs already have a vkey? `alpha1.x === 0` is the same sentinel the
  // contract's `require` uses for "not set". Use a fresh provider call per pair (cheap) so
  // a partially-applied state from a prior run is detected accurately.
  const toRegister: ArtifactConfig[] = [];
  console.log("\n[1/2] Checking current on-chain state...");
  for (const cfg of TESTING_ARTIFACT_CONFIGS) {
    const existing = await pool.getVerificationKey(
      cfg.nullifiers,
      cfg.commitments,
    );
    if (existing.alpha1.x === 0n) {
      toRegister.push(cfg);
      console.log(
        `  (${cfg.nullifiers}x${cfg.commitments}) — NOT registered, will set`,
      );
    } else {
      console.log(
        `  (${cfg.nullifiers}x${cfg.commitments}) — already on chain, skip`,
      );
    }
  }

  if (toRegister.length === 0) {
    console.log(
      "\nNothing to do. All configured verification keys are on chain.",
    );
    return;
  }

  console.log(
    `\n[2/2] Registering ${toRegister.length} verification key(s)...`,
  );
  // Nonce manager: explicit on testnet (Sepolia load-balanced RPCs drop stale-pending on
  // backend drift), no-op on local Anvil. Mirrors the pattern in deploy_privacy_pool.ts.
  const nm = await createNonceManager(signer);

  for (let i = 0; i < toRegister.length; i++) {
    const cfg = toRegister[i];
    const vkey = getVKey(cfg.nullifiers, cfg.commitments);
    const solidityVKey = formatVKeyForSolidity(
      vkey,
      cfg.nullifiers,
      cfg.commitments,
    );

    console.log(
      `  [${i + 1}/${toRegister.length}] setVerificationKey(${cfg.nullifiers}, ${cfg.commitments})...`,
    );
    const tx = await pool.setVerificationKey(
      cfg.nullifiers,
      cfg.commitments,
      solidityVKey,
      nm.override(),
    );
    const receipt = await tx.wait();
    console.log(
      `     tx ${receipt?.hash} mined in block ${receipt?.blockNumber}`,
    );
  }

  console.log("\nDone.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
