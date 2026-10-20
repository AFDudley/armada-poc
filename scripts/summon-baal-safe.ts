// ABOUTME: Deploys one Baal (HausDAO feat/baalZodiac, vendored at lib/baal) backed by one
// ABOUTME: Gnosis Safe (vendored at lib/safe-contracts): the Safe's sole owner is the Baal,
// ABOUTME: threshold 1, no human owner at any point, and Baal's registered shares token
// ABOUTME: is deployed/configured as "ARM" (see the BaalSharesToken finding note below).

/**
 * Summon Baal + Safe (G2/arp-1f1)
 *
 * Deploys:
 * - BaalSharesToken ("ARM") and BaalSharesToken ("LOOT") — see FINDING below
 * - Gnosis Safe (GnosisSafe template + GnosisSafeProxyFactory + MultiSend, vendored)
 * - Baal (template + zodiac ModuleProxyFactory clone, vendored)
 *
 * Wiring, in order (no human Safe owner at any point, even transiently):
 * 1. Deploy the Safe proxy with EMPTY setup data (zero owners, threshold 0 — not yet a
 *    functioning Safe, but critically: no owner of any kind exists yet, human or not).
 * 2. Clone the Baal template via zodiac's ModuleProxyFactory (a cheap view-function call,
 *    `avatar()`, satisfies deployModule's initializer requirement without touching storage).
 * 3. Call safe.setup(owners=[baalClone], threshold=1, ...), enabling the Baal as a Safe
 *    module in the same call (BaalSummoner.configureSafe's own pattern) — the Safe's FIRST
 *    and ONLY owner, from its very first owner-bearing state, is the Baal contract.
 * 4. Call baal.setUp(...), registering the ARM/LOOT BaalSharesToken as Baal's shares/loot
 *    token, with the Safe as Baal's avatar.
 * 5. Transfer ownership of the ARM/LOOT tokens to the Baal (so only Baal can mint/burn/
 *    pause them going forward — BaalSummoner.deployTokens does this for its own freshly
 *    deployed tokens; this script does the same for the tokens it brings).
 *
 * FINDING (read before changing this script or G1's ArmadaToken):
 *   G1's ArmadaToken (contracts/governance/ArmadaToken.sol) CANNOT be Baal's shares token
 *   directly. The vendored Baal core (lib/baal/contracts/Baal.sol) calls sharesToken.paused(),
 *   .pause(), .unpause(), .mint(), .burn() — functions ArmadaToken does not implement (it is
 *   a fixed-supply, non-upgradeable ERC20Votes with no owner-gated mint/burn/pause surface;
 *   see docs/tasks/G1-arm-shares-token.md). BaalSummoner.sol's own comment on bring-your-own
 *   tokens confirms this is by design: "tokens need to be baalTokens". So this script deploys
 *   contracts/governance/BaalSharesToken.sol (a minimal ERC20Votes implementing exactly the
 *   function surface Baal calls), configured name="ARM" symbol="ARM", as the token actually
 *   registered on Baal. G1's real ArmadaToken is deployed separately by deploy_governance.ts
 *   and recorded here (field g1ArmToken) for cross-reference only — it is NOT Baal's shares
 *   token and this script does not call any of its ARM-token functions.
 *
 * Usage (local):
 *   npx hardhat run scripts/summon-baal-safe.ts --network hub
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { execFileSync } from "child_process";
import {
  getGovernanceDeploymentFile,
  getBaalSafeDeploymentFile,
} from "../config/networks";
import {
  createNonceManager,
  loadDeployment,
  saveDeployment,
  saveDeploymentInProgress,
  assertDeploymentComplete,
} from "./deploy-utils";

const REPO_ROOT = path.join(__dirname, "..");
const FORGE_OUT_DIR = path.join(REPO_ROOT, "forge-out");

interface ForgeArtifact {
  abi: unknown[];
  bytecode: { object: string };
}

/** Load a forge-compiled artifact (ABI + bytecode) for a vendored lib/ contract that Hardhat
 *  does not compile (lib/baal and lib/safe-contracts have no hardhat remappings — see
 *  foundry.toml for the forge-side remappings). `forge build` must have populated forge-out/
 *  first; this is run unconditionally below so the artifact is always current. */
function loadForgeArtifact(
  sourceFile: string,
  contractName: string,
): ForgeArtifact {
  const artifactPath = path.join(
    FORGE_OUT_DIR,
    sourceFile,
    `${contractName}.json`,
  );
  if (!fs.existsSync(artifactPath)) {
    throw new Error(
      `Forge artifact not found: ${artifactPath}. Run 'forge build' first (this script does so automatically).`,
    );
  }
  const parsed = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  return { abi: parsed.abi, bytecode: parsed.bytecode };
}

interface BaalSafeDeployment {
  chainId: number;
  deployer: string;
  deployBlock: number;
  contracts: {
    safe: string;
    safeTemplate: string;
    baal: string;
    baalTemplate: string;
    armToken: string;
    lootToken: string;
    multisend: string;
    g1ArmToken: string;
  };
  ownerHistory: Array<{
    step: string;
    owners: string[];
    humanOwners: string[];
  }>;
  timestamp: string;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  const nm = await createNonceManager(deployer);

  console.log("=== Summoning Baal + Safe (G2/arp-1f1) ===");
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Chain ID: ${chainId}`);
  console.log("");

  // 0. Cross-reference G1's real ArmadaToken (not what gets registered on Baal — see the
  //    FINDING note above the imports).
  const govFilename = getGovernanceDeploymentFile();
  const govDeployment = loadDeployment(govFilename);
  if (!govDeployment) {
    throw new Error(
      `Governance deployment not found (${govFilename}). Run deploy_governance first.`,
    );
  }
  assertDeploymentComplete(govDeployment, govFilename);
  const g1ArmTokenAddress: string = govDeployment.contracts.armToken;
  console.log(
    `0. G1 ArmadaToken (reference only, not Baal's shares token): ${g1ArmTokenAddress}`,
  );

  // Ensure the vendored Baal/Safe forge artifacts are current (forge-out/ is not committed).
  console.log(
    "   Running 'forge build' to refresh vendored contract artifacts...",
  );
  execFileSync("forge", ["build"], { cwd: REPO_ROOT, stdio: "inherit" });

  const outputFile = getBaalSafeDeploymentFile();
  const progress: {
    contracts: Record<string, string>;
    [field: string]: unknown;
  } = {
    chainId,
    deployer: deployer.address,
    contracts: {},
  };
  const recordProgress = (
    contracts: Record<string, string>,
    extra: object = {},
  ) => {
    Object.assign(progress.contracts, contracts);
    Object.assign(progress, extra);
    saveDeploymentInProgress(outputFile, progress);
  };
  recordProgress({});

  const ownerHistory: BaalSafeDeployment["ownerHistory"] = [];
  async function recordOwnerHistory(step: string, safeAddress: string) {
    const safeForRead = new ethers.Contract(
      safeAddress,
      loadForgeArtifact("GnosisSafe.sol", "GnosisSafe").abi,
      deployer,
    );
    let owners: string[] = [];
    try {
      owners = await safeForRead.getOwners();
    } catch {
      owners = []; // Safe not yet initialized (threshold == 0) — getOwners() on an empty
      // linked list returns [] in practice, but guard defensively in case of revert.
    }
    const humanOwners: string[] = [];
    for (const owner of owners) {
      const code = await ethers.provider.getCode(owner);
      if (code === "0x") humanOwners.push(owner); // no deployed code => an EOA/human key
    }
    ownerHistory.push({ step, owners, humanOwners });
    console.log(
      `   [owner-history] step=${step} owners=${JSON.stringify(owners)} humanOwners=${JSON.stringify(humanOwners)}`,
    );
  }

  // 1. Deploy the ARM/LOOT BaalSharesToken (see FINDING above). Owner starts as the
  //    deployer (OZ Ownable default); transferred to the Baal clone in step 6.
  console.log("1. Deploying BaalSharesToken (ARM, LOOT)...");
  const BaalSharesToken = await ethers.getContractFactory("BaalSharesToken");
  const armToken = await BaalSharesToken.deploy("ARM", "ARM", nm.override());
  await armToken.deploymentTransaction()!.wait();
  const armTokenAddress = await armToken.getAddress();
  recordProgress({ armToken: armTokenAddress });
  console.log(`   ARM (BaalSharesToken): ${armTokenAddress}`);

  const lootToken = await BaalSharesToken.deploy("LOOT", "LOOT", nm.override());
  await lootToken.deploymentTransaction()!.wait();
  const lootTokenAddress = await lootToken.getAddress();
  recordProgress({ lootToken: lootTokenAddress });
  console.log(`   LOOT (BaalSharesToken): ${lootTokenAddress}`);

  // 2. Deploy the vendored Gnosis Safe template + factory + multisend library.
  console.log("2. Deploying Gnosis Safe (template, factory, multisend)...");
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
  recordProgress({ safeTemplate: safeTemplateAddress });
  console.log(`   GnosisSafe template: ${safeTemplateAddress}`);

  const SafeProxyFactoryFactory = new ethers.ContractFactory(
    safeFactoryArtifact.abi,
    safeFactoryArtifact.bytecode.object,
    deployer,
  );
  const safeProxyFactory = await SafeProxyFactoryFactory.deploy(nm.override());
  await safeProxyFactory.deploymentTransaction()!.wait();
  console.log(
    `   GnosisSafeProxyFactory: ${await safeProxyFactory.getAddress()}`,
  );

  const MultiSendFactory = new ethers.ContractFactory(
    multisendArtifact.abi,
    multisendArtifact.bytecode.object,
    deployer,
  );
  const multisend = await MultiSendFactory.deploy(nm.override());
  await multisend.deploymentTransaction()!.wait();
  const multisendAddress = await multisend.getAddress();
  recordProgress({ multisend: multisendAddress });
  console.log(`   MultiSend: ${multisendAddress}`);

  // 3. Deploy the Safe proxy with EMPTY setup data: no owner of any kind exists yet.
  console.log("3. Deploying the Safe proxy (uninitialized — no owners yet)...");
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
  recordProgress({ safe: safeAddress });
  console.log(`   Safe proxy (uninitialized): ${safeAddress}`);
  await recordOwnerHistory("safe-proxy-created", safeAddress);

  // 4. Deploy the vendored Baal template + zodiac ModuleProxyFactory, then clone the
  //    template — Baal's constructor disables initializers on the template itself, so
  //    setUp() must run against a clone's fresh storage (mirrors BaalSummoner._summonBaal).
  console.log(
    "4. Deploying Baal (template, zodiac ModuleProxyFactory, clone)...",
  );
  const baalArtifact = loadForgeArtifact("Baal.sol", "Baal");
  const moduleProxyFactoryArtifact = loadForgeArtifact(
    "ModuleProxyFactory.sol",
    "ModuleProxyFactory",
  );

  const BaalTemplateFactory = new ethers.ContractFactory(
    baalArtifact.abi,
    baalArtifact.bytecode.object,
    deployer,
  );
  const baalTemplate = await BaalTemplateFactory.deploy(nm.override());
  await baalTemplate.deploymentTransaction()!.wait();
  const baalTemplateAddress = await baalTemplate.getAddress();
  recordProgress({ baalTemplate: baalTemplateAddress });
  console.log(`   Baal template: ${baalTemplateAddress}`);

  const ModuleProxyFactoryFactory = new ethers.ContractFactory(
    moduleProxyFactoryArtifact.abi,
    moduleProxyFactoryArtifact.bytecode.object,
    deployer,
  );
  const moduleProxyFactory = await ModuleProxyFactoryFactory.deploy(
    nm.override(),
  );
  await moduleProxyFactory.deploymentTransaction()!.wait();
  console.log(
    `   zodiac ModuleProxyFactory: ${await moduleProxyFactory.getAddress()}`,
  );

  const avatarGetterSelector = ethers.id("avatar()").slice(0, 10);
  const deployModuleTx = await (moduleProxyFactory as any).deployModule(
    baalTemplateAddress,
    avatarGetterSelector,
    0, // saltNonce
    nm.override(),
  );
  const deployModuleReceipt = await deployModuleTx.wait();
  const moduleProxyCreationEvent = deployModuleReceipt!.logs
    .map((log: any) => {
      try {
        return moduleProxyFactory.interface.parseLog(log);
      } catch {
        return null;
      }
    })
    .find((parsed: any) => parsed?.name === "ModuleProxyCreation");
  const baalAddress: string = moduleProxyCreationEvent!.args.proxy;
  recordProgress({ baal: baalAddress });
  console.log(`   Baal clone: ${baalAddress}`);

  // 5. Call safe.setup(owners=[baal], threshold=1, ...), enabling Baal as a Safe module in
  //    the same call (BaalSummoner.configureSafe's own pattern). This is the Safe's FIRST
  //    owner-bearing state, and its only owner is the Baal contract — never a human key.
  console.log(
    "5. Setting the Safe's sole owner to the Baal, threshold 1, enabling Baal as a module...",
  );
  const safe = new ethers.Contract(safeAddress, safeArtifact.abi, deployer);
  const enableBaalModuleCall = new ethers.Interface([
    "function enableModule(address module)",
  ]).encodeFunctionData("enableModule", [baalAddress]);
  const enableBaalMultisendEntry = ethers.solidityPacked(
    ["uint8", "address", "uint256", "uint256", "bytes"],
    [
      0,
      safeAddress,
      0,
      ethers.getBytes(enableBaalModuleCall).length,
      enableBaalModuleCall,
    ],
  );
  const multisendAction = new ethers.Interface([
    "function multiSend(bytes transactions)",
  ]).encodeFunctionData("multiSend", [enableBaalMultisendEntry]);
  const setupTx = await (safe as any).setup(
    [baalAddress],
    1,
    multisendAddress,
    multisendAction,
    ethers.ZeroAddress,
    ethers.ZeroAddress,
    0,
    ethers.ZeroAddress,
    nm.override(),
  );
  await setupTx.wait();
  await recordOwnerHistory("safe-setup-complete", safeAddress);

  // 6. Register ARM/LOOT as Baal's shares/loot token, now that the Safe (avatar) exists.
  //    Baal.setUp decodes (loot, shares, multisend, avatar, forwarder, initMultisendData);
  //    the multisend data is a real no-op multiSend(bytes("")) call, not raw empty bytes
  //    (raw empty bytes hits MultiSend's nonexistent fallback and reverts).
  console.log("6. Registering ARM as Baal's shares token...");
  const baal = new ethers.Contract(baalAddress, baalArtifact.abi, deployer);
  const noOpMultisend = new ethers.Interface([
    "function multiSend(bytes transactions)",
  ]).encodeFunctionData("multiSend", ["0x"]);
  const baalInitParams = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "address", "address", "address", "bytes"],
    [
      lootTokenAddress,
      armTokenAddress,
      multisendAddress,
      safeAddress,
      ethers.ZeroAddress,
      noOpMultisend,
    ],
  );
  const baalSetupTx = await (baal as any).setUp(baalInitParams, nm.override());
  await baalSetupTx.wait();
  console.log(`   Baal.sharesToken() registered: ${armTokenAddress}`);

  // 7. Transfer ownership of ARM/LOOT to the Baal — only Baal can mint/burn/pause them
  //    going forward (mirrors BaalSummoner.deployTokens's own transferOwnership-to-Baal step
  //    for freshly-deployed tokens).
  console.log("7. Transferring ARM/LOOT ownership to the Baal...");
  await (await armToken.transferOwnership(baalAddress, nm.override())).wait();
  await (await lootToken.transferOwnership(baalAddress, nm.override())).wait();
  console.log(`   ARM/LOOT owner: ${baalAddress}`);

  // ============ Read back and print the three facts ============
  const finalOwners: string[] = await (safe as any).getOwners();
  const finalThreshold: bigint = await (safe as any).getThreshold();
  const isBaalOwner: boolean = await (safe as any).isOwner(baalAddress);
  const registeredSharesToken: string = await (baal as any).sharesToken();
  const humanOwnersFinal: string[] = [];
  for (const owner of finalOwners) {
    const code = await ethers.provider.getCode(owner);
    if (code === "0x") humanOwnersFinal.push(owner);
  }

  console.log("");
  console.log("=== Baal + Safe summon complete ===");
  console.log(`Safe address: ${safeAddress}`);
  console.log(`Safe owners: ${JSON.stringify(finalOwners)}`);
  console.log(`Safe threshold: ${finalThreshold}`);
  console.log(`Safe human owner count: ${humanOwnersFinal.length}`);
  console.log(`Baal address: ${baalAddress}`);
  console.log(`Baal registered shares token: ${registeredSharesToken}`);
  console.log(`ARM token (deployed by this script): ${armTokenAddress}`);
  console.log(`G1 ArmadaToken (reference only): ${g1ArmTokenAddress}`);

  const resultJson = {
    safeAddress,
    safeOwners: finalOwners,
    safeThreshold: Number(finalThreshold),
    safeOwnerCount: finalOwners.length,
    safeHumanOwnerCount: humanOwnersFinal.length,
    baalIsSafeOwner: isBaalOwner,
    baalAddress,
    baalSharesToken: registeredSharesToken,
    armToken: armTokenAddress,
    sharesTokenIsArm:
      registeredSharesToken.toLowerCase() === armTokenAddress.toLowerCase(),
    g1ArmToken: g1ArmTokenAddress,
    ownerHistory,
  };
  console.log(`DEPLOY_RESULT_JSON=${JSON.stringify(resultJson)}`);

  const deployment: BaalSafeDeployment = {
    chainId,
    deployer: deployer.address,
    deployBlock: createProxyReceipt!.blockNumber,
    contracts: {
      safe: safeAddress,
      safeTemplate: safeTemplateAddress,
      baal: baalAddress,
      baalTemplate: baalTemplateAddress,
      armToken: armTokenAddress,
      lootToken: lootTokenAddress,
      multisend: multisendAddress,
      g1ArmToken: g1ArmTokenAddress,
    },
    ownerHistory,
    timestamp: new Date().toISOString(),
  };
  saveDeployment(outputFile, deployment);
  console.log(`\nDeployment saved to: deployments/${outputFile}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
