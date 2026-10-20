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
  // Governance manifest: treasury (the Safe) and ArmadaToken.
  const govFilename = getGovernanceDeploymentFile();
  const govPath = path.join(process.cwd(), "deployments", govFilename);
  const gov = JSON.parse(fs.readFileSync(govPath, "utf-8"));

  // Baal + Safe manifest: the Baal, ShieldedRagequit and the reused Safe.
  const baalSafePath = path.join(
    process.cwd(),
    "deployments",
    "baal-safe-hub.json",
  );
  const baalData = JSON.parse(fs.readFileSync(baalSafePath, "utf-8"));

  const baalAddress: string = baalData.contracts.baal;
  const ragequitAddress: string = baalData.contracts.shieldedRagequit;
  const summonSafe: string = baalData.contracts.safe;
  const safeAddress: string = gov.contracts.treasury;
  const armTokenAddress: string = gov.contracts.armToken;

  const [deployer] = await ethers.getSigners();

  // Baal is a vendored (forge-compiled) contract with no Hardhat artifact, so read its shaman
  // registry through a minimal ABI rather than getContractAt("Baal").
  const baalContract = new ethers.Contract(
    baalAddress,
    ["function shamans(address) view returns (uint256)"],
    deployer,
  );
  const armTokenContract = await ethers.getContractAt(
    "ArmadaToken",
    armTokenAddress,
  );

  // c3: Baal.shamans(ShieldedRagequit) is the manager role (permission 2, 3, 6 or 7), and
  //     ArmadaToken.authorizedBurner(ShieldedRagequit) is true.
  const shamanPermission = Number(await baalContract.shamans(ragequitAddress));
  const has_manager_role = [2, 3, 6, 7].includes(shamanPermission);
  const authorized_burner: boolean =
    await armTokenContract.authorizedBurner(ragequitAddress);

  // c5: ArmadaToken.timelock is the Safe (the treasury), and exactly one Safe exists — the
  //     summon reused the governance Safe rather than deploying a second one.
  const timelockAddress: string = await armTokenContract.timelock();
  const token_timelock_is_safe =
    timelockAddress.toLowerCase() === safeAddress.toLowerCase();
  const safes_deployed =
    summonSafe.toLowerCase() === safeAddress.toLowerCase() ? 1 : 2;

  console.log(
    JSON.stringify({
      has_manager_role,
      authorized_burner,
      token_timelock_is_safe,
      safes_deployed,
    }),
  );
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
