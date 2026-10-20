// ABOUTME: Baal-era governance deploy: one Gnosis Safe (the treasury) is deployed before
// ABOUTME: ArmadaToken and is its immutable timelock. No custom governor, timelock or
// ABOUTME: wind-down. Deploys ArmadaToken (ARM), RevenueLock, AdapterRegistry,
// ABOUTME: ShieldPauseController and RevenueReserveDistributor, and writes the manifest.

/**
 * Deploy Armada Governance (Baal era)
 *
 * Deploys:
 * - Gnosis Safe (template + proxy factory + MultiSend + proxy) — the treasury
 * - ArmadaToken (ARM) with the Safe as the immutable timelock
 * - RevenueLock (immutable, team + airdrop token release)
 * - AdapterRegistry
 * - ShieldPauseController
 * - RevenueReserveDistributor (when the reserve is configured)
 *
 * The Safe is the treasury AND the governance executor. Where a reader needs a
 * governance-executor address, it receives the Safe. No custom governor, timelock or
 * wind-down contract is deployed.
 *
 * Usage (local):
 *   npx hardhat run scripts/deploy_governance.ts --network hub
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { execFileSync } from "child_process";
import {
  getNetworkConfig,
  getChainRole,
  getChainByRole,
  getGovernanceDeploymentFile,
  getPrivacyPoolDeploymentFile,
  isLocal,
} from "../config/networks";
import {
  createNonceManager,
  loadDeployment,
  rejectAnvilAddresses,
  saveDeployment,  saveDeploymentInProgress,
  assertDeploymentComplete,
} from "./deploy-utils";
import {
  assertAllocatorDistinct,
  assertAllocatorMultisig,
  revenueLockSchedule,
  validateReservePlan,
  type RevenueLockConstructorArgs,
} from "./revenue-reserve";

const REPO_ROOT = path.join(__dirname, "..");
const FORGE_OUT_DIR = path.join(REPO_ROOT, "forge-out");

interface ForgeArtifact {
  abi: any[];
  bytecode: { object: string };
}

function loadForgeArtifact(sourceFile: string, contractName: string): ForgeArtifact {
  // The forge build produces version-specific artifacts (e.g. `GnosisSafe.0.8.20.json`).
  // Try the higher version first, then the lower.
  const versionSuffixes = [".0.8.20", ".0.8.17", ""];
  for (const suffix of versionSuffixes) {
    const artifactPath = path.join(FORGE_OUT_DIR, sourceFile, `${contractName}${suffix}.json`);
    if (fs.existsSync(artifactPath)) {
      const parsed = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
      return { abi: parsed.abi, bytecode: parsed.bytecode };
    }
  }
  const fallbackPath = path.join(FORGE_OUT_DIR, sourceFile, `${contractName}.json`);
  throw new Error(`Forge artifact not found: ${fallbackPath}. Run 'forge build' first.`);
}

interface GovernanceDeployment {
  revenueLockConstructorArgs: RevenueLockConstructorArgs;
  revenueLockDeploymentTransaction: string;
  revenueReserveDistributorDeploymentTransaction?: string;
  chainId: number;
  deployer: string;
  deployerNonceAfterGovernance?: number;
  deployBlock: number;
  contracts: {
    /** The Gnosis Safe (the treasury and the governance executor). */
    treasury: string;
    armToken: string;
    revenueLock: string;
    adapterRegistry: string;
    shieldPauseController: string;
    revenueCounter: string;
    /** The Safe — the governance executor. No custom timelock. */
    timelockController: string;
    /** The Safe — no custom governor. */
    governor: string;
    revenueReserveDistributor?: string;
  };
  config: { totalSupply: string };
  timestamp: string;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  const config = getNetworkConfig();
  const nm = await createNonceManager(deployer);
  const role = getChainRole(chainId);
  if (!role) {
    console.error(`Unknown chain ID: ${chainId}`);
    process.exit(1);
  }

  console.log("=== Deploying Armada Governance (Baal era) ===");
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`Environment: ${config.env}`);
  console.log("");

  const outputFile = getGovernanceDeploymentFile();
  const progress: {
    contracts: Record<string, string>;
    [field: string]: unknown;
  } = {
    chainId,
    deployer: deployer.address,
    contracts: {},
  };
  const recordProgress = (contracts: Record<string, string>, extra: object = {}) => {
    Object.assign(progress.contracts, contracts);
    Object.assign(progress, extra);
    saveDeploymentInProgress(outputFile, progress);
  };
  recordProgress({});

  // Ensure the vendored Baal/Safe forge artifacts are current.
  console.log("Running 'forge build' to refresh vendored contract artifacts...");
  execFileSync("forge", ["build"], { cwd: REPO_ROOT, stdio: "inherit" });

  // 1. Deploy the vendored Gnosis Safe (template, factory, multisend).
  console.log("1. Deploying Gnosis Safe (template, factory, multisend)...");
  const safeArtifact = loadForgeArtifact("GnosisSafe.sol", "GnosisSafe");
  const safeFactoryArtifact = loadForgeArtifact(
    "GnosisSafeProxyFactory.sol",
    "GnosisSafeProxyFactory",
  );
  const multisendArtifact = loadForgeArtifact("MultiSend.sol", "MultiSend");

  const SafeTemplateFactory = new ethers.ContractFactory(
    safeArtifact.abi,
    safeArtifact.bytecode.object,
    deployer,
  );
  const safeTemplate = await SafeTemplateFactory.deploy(nm.override());
  await safeTemplate.deploymentTransaction()!.wait();
  const safeTemplateAddress = await safeTemplate.getAddress();

  const SafeProxyFactoryFactory = new ethers.ContractFactory(
    safeFactoryArtifact.abi,
    safeFactoryArtifact.bytecode.object,
    deployer,
  );
  const safeProxyFactory = await SafeProxyFactoryFactory.deploy(nm.override());
  await safeProxyFactory.deploymentTransaction()!.wait();

  const MultiSendFactory = new ethers.ContractFactory(
    multisendArtifact.abi,
    multisendArtifact.bytecode.object,
    deployer,
  );
  const multisend = await MultiSendFactory.deploy(nm.override());
  await multisend.deploymentTransaction()!.wait();

  // 2. Deploy the Safe proxy with EMPTY setup data (zero owners, threshold 0 — the Safe is
  //    not yet a functioning Safe; no owner of any kind exists yet).
  console.log("2. Deploying the Safe proxy (uninitialized — no owners yet)...");
  const createProxyTx = await (safeProxyFactory as any).createProxy(
    safeTemplateAddress,
    "0x",
    nm.override(),
  );
  const createProxyReceipt = await createProxyTx.wait();
  const proxyCreationEvent = createProxyReceipt!.logs
    .map((log: any) => {
      try {
        return safeProxyFactory.interface.parseLog(log);
      } catch {
        return null;
      }
    })
    .find((parsed: any) => parsed?.name === "ProxyCreation");
  const safeAddress: string = proxyCreationEvent!.args.proxy;
  // The Safe is the treasury AND ArmadaToken's immutable timelock (Baal-era wiring).
  const governanceDeployBlock = createProxyReceipt!.blockNumber;
  recordProgress({ treasury: safeAddress }, { deployBlock: governanceDeployBlock });
  console.log(`   GnosisSafe proxy (the treasury): ${safeAddress} (block ${governanceDeployBlock})`);

  // 3. Deploy ArmadaToken (ARM) with the Safe as the immutable timelock.
  console.log("3. Deploying ArmadaToken (ARM, Safe as immutable timelock)...");
  const ArmadaToken = await ethers.getContractFactory("ArmadaToken");
  const armToken = await ArmadaToken.deploy(deployer.address, safeAddress, nm.override());
  await armToken.deploymentTransaction()!.wait();
  const armTokenAddress = await armToken.getAddress();
  recordProgress({ armToken: armTokenAddress });
  console.log(`   ArmadaToken (ARM): ${armTokenAddress}`);

  // 4. Deploy AdapterRegistry (standalone, owned by the Safe — the executor).
  console.log("4. Deploying AdapterRegistry...");
  const AdapterRegistry = await ethers.getContractFactory("AdapterRegistry");
  const adapterRegistry = await AdapterRegistry.deploy(safeAddress, nm.override());
  await adapterRegistry.deploymentTransaction()!.wait();
  const adapterRegistryAddress = await adapterRegistry.getAddress();
  recordProgress({ adapterRegistry: adapterRegistryAddress });
  console.log(`   AdapterRegistry: ${adapterRegistryAddress}`);

  // 5. Deploy ShieldPauseController (Baal era: the governor + timelock args are the Safe).
  console.log("5. Deploying ShieldPauseController...");
  const ShieldPauseController = await ethers.getContractFactory("ShieldPauseController");
  const shieldPause = await ShieldPauseController.deploy(safeAddress, safeAddress, nm.override());
  await shieldPause.deploymentTransaction()!.wait();
  const shieldPauseAddress = await shieldPause.getAddress();
  recordProgress({ shieldPauseController: shieldPauseAddress });
  console.log(`   ShieldPauseController: ${shieldPauseAddress}`);

  // 6. Deploy RevenueCounter (UUPS proxy).
  console.log("6. Deploying RevenueCounter (UUPS proxy)...");
  const RevenueCounter = await ethers.getContractFactory("RevenueCounter");
  const revenueCounterImpl = await RevenueCounter.deploy(nm.override());
  await revenueCounterImpl.deploymentTransaction()!.wait();
  const revenueCounterImplAddress = await revenueCounterImpl.getAddress();
  const initData = RevenueCounter.interface.encodeFunctionData("initialize", [safeAddress]);
  const ERC1967Proxy = await ethers.getContractFactory("ERC1967Proxy");
  const revenueCounterProxy = await ERC1967Proxy.deploy(revenueCounterImplAddress, initData, nm.override());
  await revenueCounterProxy.deploymentTransaction()!.wait();
  const revenueCounterAddress = await revenueCounterProxy.getAddress();
  recordProgress({ revenueCounter: revenueCounterAddress });
  console.log(`   RevenueCounter (proxy): ${revenueCounterAddress}`);

  // 7. Deploy RevenueLock (immutable — holds team + airdrop ARM, reads pool cumulativeFees).
  console.log("7. Deploying RevenueLock...");
  const revenueLockAllocation = ethers.parseUnits(config.armDistribution.revenueLock, 18);
  const beneficiaryConfig = config.revenueLockBeneficiaries;
  let revenueReserveDistributor: string | undefined;
  let reserveDeploymentTransaction: string | undefined;
  if (config.revenueReserve) {
    rejectAnvilAddresses([config.revenueReserve.allocator], "Reserve allocator");
    if (!isLocal()) {
      await assertAllocatorMultisig(config.revenueReserve.allocator);
      assertAllocatorDistinct(config.revenueReserve.allocator, [
        { label: "deployer", address: deployer.address },
      ]);
    }
  }

  const reserveCap = validateReservePlan(
    config.revenueLockBeneficiaries,
    revenueLockAllocation,
    config.revenueReserve,
  );
  if (config.revenueReserve) {
    const Distributor = await ethers.getContractFactory("RevenueReserveDistributor");
    const reserve = await Distributor.deploy(
      armTokenAddress,
      config.revenueReserve.allocator,
      reserveCap,
      nm.override(),
    );
    await reserve.deploymentTransaction()!.wait();
    reserveDeploymentTransaction = reserve.deploymentTransaction()!.hash;
    // The Reserve distributor holds the reserve cap amount of ARM and distributes it
    // via a revenue-gated release curve.
  }
  const { addresses: revenueLockBeneficiaries, amounts: revenueLockAmounts } = revenueLockSchedule(
    beneficiaryConfig,
    revenueReserveDistributor
      ? { address: revenueReserveDistributor, cap: reserveCap }
      : undefined,
  );
  // Guard: reject Anvil default addresses on non-local environments.
  rejectAnvilAddresses(revenueLockBeneficiaries, "RevenueLock beneficiaries");

  const MAX_REVENUE_INCREASE_PER_DAY = ethers.parseUnits(config.revenueLockMaxIncreasePerDayUsd, 18);

  // The pool address comes from the privacy pool deployment manifest (the PrivacyPool contract).
  // The asset is the USDC token.
  const poolFilename = getPrivacyPoolDeploymentFile(role);
  const poolDeployment = loadDeployment(poolFilename);
  if (!poolDeployment) {
    throw new Error(
      `PrivacyPool deployment not found (${poolFilename}). Run deploy_privacy_pool first.`,
    );
  }
  const poolAddress = poolDeployment.contracts.privacyPool;
  const assetAddress = getChainByRole(role).usdc;
  console.log(`   USDC asset: ${assetAddress}`);
  const RevenueLock = await ethers.getContractFactory("RevenueLock");
  const revenueLockContract = await RevenueLock.deploy(
    armTokenAddress,
    poolAddress,
    assetAddress,
    revenueLockBeneficiaries,
    revenueLockAmounts,
    nm.override(),
  );
  await revenueLockContract.deploymentTransaction()!.wait();
  const revenueLockAddress = await revenueLockContract.getAddress();
  const revenueLockConstructorArgs: RevenueLockConstructorArgs = [
    armTokenAddress,
    poolAddress,
    assetAddress,
    revenueLockBeneficiaries,
    revenueLockAmounts.map((amount) => amount.toString()),
  ];
  const revenueLockDeploymentTransaction = revenueLockContract.deploymentTransaction()!.hash;
  recordProgress({ revenueLock: revenueLockAddress }, {
    revenueLockConstructorArgs,
    revenueLockDeploymentTransaction: revenueLockDeploymentTransaction,
  });
  console.log(`   RevenueLock: ${revenueLockAddress}`);

  // 8. Save the complete Baal-era manifest.
  const deployment: GovernanceDeployment = {
    revenueLockConstructorArgs,
    revenueLockDeploymentTransaction,
    ...(reserveDeploymentTransaction
      ? { revenueReserveDistributorDeploymentTransaction: reserveDeploymentTransaction }
      : {}),
    chainId,
    deployer: deployer.address,
    deployBlock: governanceDeployBlock,
    contracts: {
      treasury: safeAddress,
      armToken: armTokenAddress,
      revenueLock: revenueLockAddress,
      adapterRegistry: adapterRegistryAddress,
      shieldPauseController: shieldPauseAddress,
      revenueCounter: revenueCounterAddress,
      timelockController: safeAddress,
      governor: safeAddress,
      ...(revenueReserveDistributor ? { revenueReserveDistributor } : {}),
    },
    config: { totalSupply: "12000000" },
    timestamp: new Date().toISOString(),
  };
  saveDeployment(outputFile, deployment);
  console.log(`\nDeployment saved to: deployments/${outputFile}`);
  console.log("\n=== Baal-era governance deployment complete ===");
  console.log(`Treasury (Gnosis Safe): ${safeAddress}`);
  console.log("Next: run summon-baal-safe.ts to summon the Baal (reusing this Safe), then the six readers.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
