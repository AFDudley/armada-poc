/**
 * Deploy Privacy Pool Modular Architecture
 *
 * This script deploys the new modular privacy pool system:
 *   Hub Chain:
 *     - PrivacyPool (router)
 *     - MerkleModule, VerifierModule, ShieldModule, TransactModule
 *
 *   Client Chain:
 *     - PrivacyPoolClient
 *
 * Prerequisites:
 *   - CCTP V2 contracts must be deployed/configured
 *
 * Usage (local):
 *   npx hardhat run scripts/deploy_privacy_pool.ts --network hub
 *   npx hardhat run scripts/deploy_privacy_pool.ts --network client1
 *   npx hardhat run scripts/deploy_privacy_pool.ts --network client2   # ...client<n> for CLIENT_COUNT
 *
 * Usage (sepolia):
 *   npx hardhat run scripts/deploy_privacy_pool.ts --network sepoliaHub
 *   npx hardhat run scripts/deploy_privacy_pool.ts --network sepoliaClient1
 *   npx hardhat run scripts/deploy_privacy_pool.ts --network sepoliaClient2
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import {
  getNetworkConfig,
  getChainRole,
  getChainByRole,
  getAllChains,
  getCCTPDeploymentFile,
  getGovernanceDeploymentFile,
  getBaalSafeDeploymentFile,
  getPrivacyPoolDeploymentFile,
  isLocal,
  type ChainRole,
} from "../config/networks";
import {
  createNonceManager,
  loadDeployment,
  saveDeployment,
} from "./deploy-utils";

// Load Poseidon bytecode for library deployment
const poseidonBytecode = JSON.parse(
  fs.readFileSync(
    path.join(__dirname, "..", "lib", "poseidon_bytecode.json"),
    "utf-8",
  ),
);

// On fast-block chains (e.g. OP Sepolia) the client initialize() that immediately follows the
// PrivacyPoolClient deploy must pass an EXPLICIT gasLimit. The RPC backend serving
// eth_estimateGas has not yet synced the just-deployed contract's code, so it estimates a no-op
// call to a code-less address (~27k gas) and the real tx then runs out of gas mid-initialize.
// The client init's real cost (~136k) sits safely under this fixed limit. The hub initialize()
// is left on normal auto-estimation: it runs on Ethereum Sepolia (slow blocks, reliable
// estimation) and its cost (~1.5M gas — merkle tree setup + module delegatecalls) is too large
// and change-prone to safely hardcode. A hub deployed on a fast-block chain would need the same
// explicit-limit treatment as the client.
const CLIENT_INIT_GAS_LIMIT = 300_000;

interface HubDeploymentInfo {
  chainId: number;
  domain: number;
  deployer: string;
  /** The pool owner: the verification-key authority (issue #349). A dedicated key
   *  or Safe multisig, never an address the Baal/Safe governance can direct
   *  (lab book decision 8). The deploy refuses a governance-reachable owner. */
  poolOwner: string;
  contracts: {
    privacyPool: string;
    merkleModule: string;
    verifierModule: string;
    shieldModule: string;
    transactModule: string;
    hookRouter: string;
  };
  cctp: {
    tokenMessenger: string;
    messageTransmitter: string;
    usdc: string;
  };
  /** Block number the PrivacyPool router contract was deployed at. Used by the
   *  armada-interface to bound the Railgun engine's initial Shield/Transact/Unshield
   *  event scan — without it the engine starts from block 0 and burns through ~10M
   *  unnecessary getLogs calls on public RPCs. */
  deployBlock: number;
  timestamp: string;
}

interface ClientDeploymentInfo {
  chainId: number;
  domain: number;
  deployer: string;
  contracts: {
    privacyPoolClient: string;
    hookRouter: string;
  };
  cctp: {
    tokenMessenger: string;
    messageTransmitter: string;
    usdc: string;
  };
  hub: {
    domain: number;
    privacyPool: string;
  };
  /** Block number the PrivacyPoolClient was deployed at. Less load-bearing than the
   *  hub's deployBlock — clients don't host the Railgun merkletree — but useful for
   *  any future tooling that scans client-chain events from the contract's birth. */
  deployBlock: number;
  timestamp: string;
}

async function deployHub(): Promise<HubDeploymentInfo> {
  const signers = await ethers.getSigners();
  const deployer = signers[0];
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  const config = getNetworkConfig();
  const domain = config.hub.cctpDomain;
  const nm = await createNonceManager(deployer);

  // ── Hub pool owner guard (arp-b11.2; lab book decision 8) ──────────────────
  // The pool owner is the verification-key authority (issue #349). A swapped key
  // accepts forged proofs and drains every pool user's shielded funds, so the owner
  // must be a dedicated key or Safe multisig, never an address the Baal/Safe
  // governance can direct. POOL_OWNER_ADDRESS sets the owner; it falls back to the
  // deployer only when unset.
  const poolOwnerAddress =
    process.env.POOL_OWNER_ADDRESS?.trim() || deployer.address;

  // Forbidden-owner set: the Baal, the Safe (treasury/avatar), the ShieldedRagequit
  // shaman and the ARM token — every address the Baal/Safe governance can direct.
  // Read from the Baal/Safe manifest (baal, safe, shieldedRagequit, armToken) and
  // the governance manifest (treasury = the Safe, armToken). Checked before the
  // module deploys so a refusal is cheap.
  const forbiddenOwners: [string, string][] = [];
  const addForbidden = (addr: string | undefined, label: string) => {
    if (addr) forbiddenOwners.push([addr, label]);
  };
  const baalSafeContracts = loadDeployment(
    getBaalSafeDeploymentFile(),
  )?.contracts;
  addForbidden(baalSafeContracts?.baal, "Baal");
  addForbidden(baalSafeContracts?.safe, "Safe (treasury)");
  addForbidden(baalSafeContracts?.shieldedRagequit, "ShieldedRagequit shaman");
  addForbidden(baalSafeContracts?.armToken, "ARM token");
  const govGuardContracts = loadDeployment(
    getGovernanceDeploymentFile(),
  )?.contracts;
  addForbidden(govGuardContracts?.treasury, "Safe (treasury)");
  addForbidden(govGuardContracts?.armToken, "ARM token");
  for (const [addr, label] of forbiddenOwners) {
    if (poolOwnerAddress.toLowerCase() === addr.toLowerCase()) {
      console.log(
        `Hub owner guard: pool owner ${poolOwnerAddress} equals the ${label} address ${addr} — refused`,
      );
      throw new Error(
        `Hub owner guard: pool owner ${poolOwnerAddress} equals the ${label} address ${addr}, ` +
          "which the Baal/Safe governance can direct. A swapped verification key would let an " +
          "attacker accept forged proofs and drain the pool's shielded funds. Set " +
          "POOL_OWNER_ADDRESS to a dedicated key or Safe multisig.",
      );
    }
  }
  console.log(
    `Pool owner (dedicated key / Safe multisig): ${poolOwnerAddress}`,
  );

  // The owner-gated hub ops (setVerificationKey via loadVerificationKeys, and
  // setShieldFee) must be signed by the pool owner. When the owner is a local anvil
  // signer, sign as it; otherwise fall back to the deployer (valid only when the
  // owner equals the deployer).
  const ownerSigner =
    signers.find(
      (s) => s.address.toLowerCase() === poolOwnerAddress.toLowerCase(),
    ) ?? deployer;
  const ownerNm = await createNonceManager(ownerSigner);

  console.log("=== Deploying Privacy Pool Modules to Hub Chain ===");
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`CCTP Domain: ${domain}`);
  console.log(`Environment: ${config.env}`);
  console.log("");

  // Load CCTP deployment
  const cctpFilename = getCCTPDeploymentFile("hub");
  const cctpDeployment = loadDeployment(cctpFilename);
  if (!cctpDeployment) {
    throw new Error(
      `CCTP deployment not found (${cctpFilename}). Run deploy_cctp first.`,
    );
  }

  const usdcAddress = cctpDeployment.contracts.usdc;
  const tokenMessengerAddress = cctpDeployment.contracts.tokenMessenger;
  const messageTransmitterAddress = cctpDeployment.contracts.messageTransmitter;

  console.log("CCTP Contracts:");
  console.log(`  USDC: ${usdcAddress}`);
  console.log(`  TokenMessenger: ${tokenMessengerAddress}`);
  console.log(`  MessageTransmitter: ${messageTransmitterAddress}`);
  console.log("");

  // 1. Deploy Poseidon libraries
  console.log("1. Deploying Poseidon libraries...");
  const poseidonT3Tx = await deployer.sendTransaction({
    data: poseidonBytecode.PoseidonT3.bytecode,
    ...nm.override(),
  });
  const poseidonT3Receipt = await poseidonT3Tx.wait();
  const poseidonT3Address = poseidonT3Receipt!.contractAddress!;
  console.log(`   PoseidonT3: ${poseidonT3Address}`);

  const poseidonT4Tx = await deployer.sendTransaction({
    data: poseidonBytecode.PoseidonT4.bytecode,
    ...nm.override(),
  });
  const poseidonT4Receipt = await poseidonT4Tx.wait();
  const poseidonT4Address = poseidonT4Receipt!.contractAddress!;
  console.log(`   PoseidonT4: ${poseidonT4Address}`);

  // 2. Deploy MerkleModule (requires PoseidonT3)
  console.log("\n2. Deploying MerkleModule...");
  const MerkleModule = await ethers.getContractFactory("MerkleModule", {
    libraries: { PoseidonT3: poseidonT3Address },
  });
  const merkleModule = await MerkleModule.deploy(nm.override());
  await merkleModule.deploymentTransaction()!.wait();
  const merkleModuleAddress = await merkleModule.getAddress();
  console.log(`   MerkleModule: ${merkleModuleAddress}`);

  // 3. Deploy VerifierModule
  console.log("\n3. Deploying VerifierModule...");
  const VerifierModule = await ethers.getContractFactory("VerifierModule");
  const verifierModule = await VerifierModule.deploy(nm.override());
  await verifierModule.deploymentTransaction()!.wait();
  const verifierModuleAddress = await verifierModule.getAddress();
  console.log(`   VerifierModule: ${verifierModuleAddress}`);

  // 4. Deploy ShieldModule (requires PoseidonT4)
  console.log("\n4. Deploying ShieldModule...");
  const ShieldModule = await ethers.getContractFactory("ShieldModule", {
    libraries: { PoseidonT4: poseidonT4Address },
  });
  const shieldModule = await ShieldModule.deploy(nm.override());
  await shieldModule.deploymentTransaction()!.wait();
  const shieldModuleAddress = await shieldModule.getAddress();
  console.log(`   ShieldModule: ${shieldModuleAddress}`);

  // 5. Deploy TransactModule (requires PoseidonT4)
  console.log("\n5. Deploying TransactModule...");
  const TransactModule = await ethers.getContractFactory("TransactModule", {
    libraries: { PoseidonT4: poseidonT4Address },
  });
  const transactModule = await TransactModule.deploy(nm.override());
  await transactModule.deploymentTransaction()!.wait();
  const transactModuleAddress = await transactModule.getAddress();
  console.log(`   TransactModule: ${transactModuleAddress}`);

  // 6. Deploy PrivacyPool (router)
  console.log("\n6. Deploying PrivacyPool (router)...");
  const PrivacyPool = await ethers.getContractFactory("PrivacyPool");
  const privacyPool = await PrivacyPool.deploy(nm.override());
  const privacyPoolReceipt = await privacyPool.deploymentTransaction()!.wait();
  const privacyPoolAddress = await privacyPool.getAddress();
  // Capture for the manifest — interface uses this to bound initial event scan.
  const privacyPoolDeployBlock = privacyPoolReceipt!.blockNumber;
  console.log(
    `   PrivacyPool: ${privacyPoolAddress} (block ${privacyPoolDeployBlock})`,
  );

  // 7. Resolve treasury address and initialize PrivacyPool
  // Priority: env var > governance manifest (the Safe treasury) > deployer (local only).
  // The env var override is refused on mainnet by getNetworkConfig().
  console.log("\n7. Initializing PrivacyPool...");
  const govDeployment = loadDeployment(getGovernanceDeploymentFile());
  let treasuryAddress: string;
  if (config.treasuryAddress) {
    treasuryAddress = config.treasuryAddress;
    console.log("   Using TREASURY_ADDRESS from env");
  } else if (govDeployment?.contracts?.treasury) {
    treasuryAddress = govDeployment.contracts.treasury;
    console.log("   Using treasury from governance deployment");
  } else if (isLocal()) {
    treasuryAddress = deployer.address;
    console.log(
      "   Warning: no treasury configured, using deployer as treasury (local only)",
    );
  } else {
    throw new Error(
      "No treasury address available. Deploy governance first, or set TREASURY_ADDRESS in env. " +
        "The privacy pool treasury is immutable after initialization.",
    );
  }
  console.log("   Treasury: " + treasuryAddress);

  const initTx = await privacyPool.initialize(
    shieldModuleAddress,
    transactModuleAddress,
    merkleModuleAddress,
    verifierModuleAddress,
    tokenMessengerAddress,
    messageTransmitterAddress,
    usdcAddress,
    domain,
    poolOwnerAddress,
    treasuryAddress,
    nm.override(),
  );
  await initTx.wait();
  console.log("   PrivacyPool initialized (owner + treasury immutable)");

  // 8. Deploy CCTPHookRouter
  console.log("\n8. Deploying CCTPHookRouter...");
  const CCTPHookRouter = await ethers.getContractFactory("CCTPHookRouter");
  const hookRouter = await CCTPHookRouter.deploy(
    messageTransmitterAddress,
    tokenMessengerAddress,
    nm.override(),
  );
  await hookRouter.deploymentTransaction()!.wait();
  const hookRouterAddress = await hookRouter.getAddress();
  console.log(`   CCTPHookRouter: ${hookRouterAddress}`);

  // 9. Load verification keys for SNARK proof verification.
  // Thread the nonce manager through so its N on-chain txs keep the counter in sync —
  // omitting this leaves the manager N nonces behind once the load returns and the next
  // override(...) call ends up with a stale nonce.
  console.log("\n9. Loading verification keys...");
  const { loadVerificationKeys, TESTING_ARTIFACT_CONFIGS } =
    await import("../lib/artifacts");
  const ownerPool =
    ownerSigner.address.toLowerCase() === deployer.address.toLowerCase()
      ? privacyPool
      : privacyPool.connect(ownerSigner);
  await loadVerificationKeys(ownerPool, TESTING_ARTIFACT_CONFIGS, true, () =>
    ownerNm.override(),
  );

  // 10. SNARK verification enabled
  console.log("\n10. SNARK verification enabled (testing mode disabled)");

  // 10b. Configure shield fee
  console.log("\n10b. Configuring shield fee...");
  await (await ownerPool.setShieldFee(50, ownerNm.override())).wait();
  console.log("   Shield fee: 50 bps (0.50%)");

  const deployment: HubDeploymentInfo = {
    chainId,
    domain,
    deployer: deployer.address,
    poolOwner: poolOwnerAddress,
    contracts: {
      privacyPool: privacyPoolAddress,
      merkleModule: merkleModuleAddress,
      verifierModule: verifierModuleAddress,
      shieldModule: shieldModuleAddress,
      transactModule: transactModuleAddress,
      hookRouter: hookRouterAddress,
    },
    cctp: {
      tokenMessenger: tokenMessengerAddress,
      messageTransmitter: messageTransmitterAddress,
      usdc: usdcAddress,
    },
    deployBlock: privacyPoolDeployBlock,
    timestamp: new Date().toISOString(),
  };

  const filename = getPrivacyPoolDeploymentFile("hub");
  saveDeployment(filename, deployment);

  console.log("\n=== Hub Privacy Pool Deployment Complete ===");
  console.log(`Deployment saved to: deployments/${filename}`);

  return deployment;
}

async function deployClient(role: ChainRole): Promise<ClientDeploymentInfo> {
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  const config = getNetworkConfig();
  const chain = getChainByRole(role);
  const domain = chain.cctpDomain;
  const name = chain.name;
  const nm = await createNonceManager(deployer);

  console.log(`=== Deploying PrivacyPoolClient to ${name} Chain ===`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`CCTP Domain: ${domain}`);
  console.log(`Environment: ${config.env}`);
  console.log("");

  // Load CCTP deployment for this chain
  const cctpFilename = getCCTPDeploymentFile(role);
  const cctpDeployment = loadDeployment(cctpFilename);
  if (!cctpDeployment) {
    throw new Error(
      `CCTP deployment not found (${cctpFilename}). Run deploy_cctp first.`,
    );
  }

  const usdcAddress = cctpDeployment.contracts.usdc;
  const tokenMessengerAddress = cctpDeployment.contracts.tokenMessenger;
  const messageTransmitterAddress = cctpDeployment.contracts.messageTransmitter;

  console.log("CCTP Contracts:");
  console.log(`  USDC: ${usdcAddress}`);
  console.log(`  TokenMessenger: ${tokenMessengerAddress}`);
  console.log(`  MessageTransmitter: ${messageTransmitterAddress}`);
  console.log("");

  // Load Hub deployment
  const hubFilename = getPrivacyPoolDeploymentFile("hub");
  const hubDeployment = loadDeployment(hubFilename);
  let hubPoolAddress = ethers.ZeroAddress;
  let hubPoolBytes32 = ethers.zeroPadValue(ethers.ZeroAddress, 32);
  const hubDomain = config.hub.cctpDomain;

  if (hubDeployment) {
    hubPoolAddress = hubDeployment.contracts.privacyPool;
    hubPoolBytes32 = ethers.zeroPadValue(hubPoolAddress, 32);
    console.log(`Hub PrivacyPool: ${hubPoolAddress}`);
  } else {
    console.log("Warning: Hub deployment not found, will need to link later");
  }
  console.log("");

  // 1. Deploy PrivacyPoolClient
  console.log("1. Deploying PrivacyPoolClient...");
  const PrivacyPoolClient =
    await ethers.getContractFactory("PrivacyPoolClient");
  const privacyPoolClient = await PrivacyPoolClient.deploy(nm.override());
  const clientReceipt = await privacyPoolClient.deploymentTransaction()!.wait();
  const clientAddress = await privacyPoolClient.getAddress();
  const clientDeployBlock = clientReceipt!.blockNumber;
  console.log(
    `   PrivacyPoolClient: ${clientAddress} (block ${clientDeployBlock})`,
  );

  // 2. Initialize PrivacyPoolClient
  console.log("\n2. Initializing PrivacyPoolClient...");
  const initTx = await privacyPoolClient.initialize(
    tokenMessengerAddress,
    messageTransmitterAddress,
    usdcAddress,
    domain,
    hubDomain,
    hubPoolBytes32,
    deployer.address,
    { ...nm.override(), gasLimit: CLIENT_INIT_GAS_LIMIT },
  );
  await initTx.wait();
  console.log("   PrivacyPoolClient initialized");

  // 3. Deploy CCTPHookRouter
  console.log("\n3. Deploying CCTPHookRouter...");
  const CCTPHookRouter = await ethers.getContractFactory("CCTPHookRouter");
  const hookRouter = await CCTPHookRouter.deploy(
    messageTransmitterAddress,
    tokenMessengerAddress,
    nm.override(),
  );
  await hookRouter.deploymentTransaction()!.wait();
  const hookRouterAddress = await hookRouter.getAddress();
  console.log(`   CCTPHookRouter: ${hookRouterAddress}`);

  const deployment: ClientDeploymentInfo = {
    chainId,
    domain,
    deployer: deployer.address,
    contracts: {
      privacyPoolClient: clientAddress,
      hookRouter: hookRouterAddress,
    },
    cctp: {
      tokenMessenger: tokenMessengerAddress,
      messageTransmitter: messageTransmitterAddress,
      usdc: usdcAddress,
    },
    hub: {
      domain: hubDomain,
      privacyPool: hubPoolAddress,
    },
    deployBlock: clientDeployBlock,
    timestamp: new Date().toISOString(),
  };

  const filename = getPrivacyPoolDeploymentFile(role);
  saveDeployment(filename, deployment);

  console.log(`\n=== ${name} PrivacyPoolClient Deployment Complete ===`);
  console.log(`Deployment saved to: deployments/${filename}`);

  return deployment;
}

async function main() {
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);

  const role = getChainRole(chainId);
  if (!role) {
    console.error(`Unknown chain ID: ${chainId}`);
    console.error(
      `Configured chains: ${getAllChains()
        .map((c) => `${c.role}=${c.chainId}`)
        .join(", ")}`,
    );
    process.exit(1);
  }

  if (role === "hub") {
    await deployHub();
  } else {
    await deployClient(role);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
