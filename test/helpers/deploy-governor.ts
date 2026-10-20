// ABOUTME: Shared test helper for deploying Governor behind an ERC1967 UUPS proxy.
// ABOUTME: Used by all Hardhat test files that need a governor instance.

import { ethers } from "hardhat";

/**
 * Deploy Governor implementation + ERC1967Proxy and return the proxied contract instance.
 * Matches the production deployment pattern in scripts/deploy_governance.ts.
 */
export async function deployGovernorProxy(
  armTokenAddress: string,
  timelockAddress: string,
  treasuryAddress: string,
) {
  const Governor = await ethers.getContractFactory("Governor");
  const impl = await Governor.deploy();
  await impl.waitForDeployment();

  const initData = Governor.interface.encodeFunctionData("initialize", [
    armTokenAddress,
    timelockAddress,
    treasuryAddress,
  ]);

  const ERC1967Proxy = await ethers.getContractFactory("ERC1967Proxy");
  const proxy = await ERC1967Proxy.deploy(await impl.getAddress(), initData);
  await proxy.waitForDeployment();

  const governor = Governor.attach(await proxy.getAddress());

  // Extended selectors are hardcoded in initialize() — no setup step needed.

  return governor;
}
