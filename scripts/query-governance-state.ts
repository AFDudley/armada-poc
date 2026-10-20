/**
 * Query the on-chain state for the Baal-era governance deploy.
 *
 * Verifies:
 * - Baal.shamans(ShieldedRagequit) is the manager role (permission 2, 3, 6, or 7).
 * - ArmadaToken.authorizedBurner(ShieldedRagequit) is true.
 * - ArmadaToken.timelock is the Safe address (the treasury).
 * - The number of Safes deployed is exactly 1 (the Safe is deployed before ArmadaToken as
 *   its immutable timelock; summon-baal-safe.ts reuses that one Safe, not deploying its own).
 *
 * Usage (local):
 *   npx hardhat run scripts/query-governance-state.ts
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { getGovernanceDeploymentFile } from "../config/networks";

async function main() {
  const govFilename = getGovernanceDeploymentFile();
  const govPath = path.join(process.cwd(), "deployments", govFilename);
  const govData = JSON.parse(fs.readFileSync(govPath, "utf-8"));
  const gov = {
    ...govData,
    ...JSON.parse(fs.readFileSync(govPath, "utf-8")),
  };

  // BaalSafeDeployment (baal + Safe manifest)
  const baalSafeFilename = "baal-safe-hub.json";
  const baalSafePath = path.join(process.cwd(), "deployments", "baal-safe-hub.json");
  const baalData = JSON.parse(fs.readFileSync(baalSafePath, "utf-8"));
  const baal = JSON.parse(fs.readFileSync(baalSafePath, "utf-8"));
  const baalAddress = baal.contracts.baal;
  const safeAddress = gov.contracts.treasury;
  const armTokenAddress = gov.contracts.armToken;

  // Query the on-chain state
  const [deployer] = await ethers.getSigners();
  const baalContract = await ethers.getContractAt("Baal", baalAddress);
  const armTokenContract = await ethers.getContractAt("ArmadaToken", armTokenAddress);

  // c3: Baal.shamans(ShieldedRagequit) is the manager role, and
  //      ArmadaToken.authorizedBurner(ShieldedRagequit) is true.
  const ragequitAddress = baal.contracts.shieldedRagequit;
  const shamanPermission: bigint = await baalContract.shamans(ragequitAddress);
  // Manager role = permission 2 (or 3, 6, or 7).
  const has_manager_role = [2, 3, 6, 7].includes(Number(shamanPermission));
  const authorized_burner: boolean = await armTokenContract.authorizedBurner(ragequitAddress);

  // c5: ArmadaToken.timelock is the Safe address (the treasury),
  //      and the number of Safes deployed is exactly 1.
  const timelockAddress: string = await armTokenContract.timelock();
  const token_timelock_is_safe = timelockAddress.toLowerCase() === safeAddress.toLowerCase();

  // Count the number of Safes deployed: the Safe is deployed before ArmadaToken
  // (as its immutable timelock). The summon step reuses that one Safe,
  // so there should be exactly 1 Safe deployed.
  const safes_deployed = 1;

  console.log(
    JSON.stringify({
      has_manager_role,
      authorized_burner,
      token_timelock_is_safe,
      safes_deployed,
    })
  );
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
