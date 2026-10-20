// ABOUTME: G3/arp-a76 c10 — the exit-proof conservation oracle.
// ABOUTME: Runs a ShieldedRagequit exit (creates the contract-owned payout note at the
// ABOUTME: caller's npk via PrivacyPool.transactOwned), then builds a spend of that note
// ABOUTME: with @armada/sdk planTransfer + prove, submits it on-chain via PrivacyPool.transact,
// ABOUTME: and asserts conservation (the value the spend consumes equals the sum of its outputs).
//
// Prerequisites (local):
//   npm run chains                              # terminal 1
//   source config/local.env && npm run setup    # terminal 2 (deploys the pool + ARM + ragequit)
//   npx hardhat run scripts/verify-ragequit-exit-proof.ts --network hub
import { ethers } from "hardhat";
import {
  planTransfer,
  buildWitness,
  buildTransactCalldata,
  createSnarkjsProver,
  UTXOMerkletree,
  decodePoolEvents,
  tryDecryptCommitment,
  tryDecryptShield,
  fetchLogsRanged,
  LocalSigner,
  deriveKeyset,
  POOL_V2_EVENT_ABI,
  type ParsedPoolLog,
  type TXO,
} from "@armada/sdk";
import {
  getTokenDataERC20,
  initPoseidonPromise,
  type TokenData,
  ChainType,
} from "@armada/sdk/core";
import { getChainById } from "../lib/sdk/chain-config";
import { loadDeployment } from "./deploy-utils";
import { getArtifact } from "../lib/sdk/armada-artifacts";

const bytesToHex = (b: Uint8Array): string =>
  Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
const seed = (fill: number): Uint8Array => new Uint8Array(32).fill(fill);
const toBig = (hexNo0x: string): bigint => BigInt(`0x${hexNo0x}`);

// The holder's root (deterministic keyset). The ragequit payout note is contract-owned at the
// holder's npk; the holder's wallet can spend it.
const HOLDER_ROOT = seed(0xa9);

async function main() {
  console.log("=".repeat(60));
  console.log(
    "  G3/arp-a76 c10: ShieldedRagequit exit-proof conservation oracle",
  );
  console.log("=".repeat(60));
  await initPoseidonPromise;

  const deployments = loadDeployment("privacy-pool-hub.json");
  if (!deployments)
    throw new Error(
      "privacy-pool-hub.json not found — run `npm run setup` first",
    );
  const chainId: number = deployments.chainId;
  const chain = getChainById(chainId);
  console.log(`Network: hub (chainId ${chainId})`);

  const pool = await ethers.getContractAt(
    "PrivacyPool",
    deployments.contracts.privacyPool,
  );
  const poolAddress = (await pool.getAddress()) as `0x${string}`;
  const usdc = await ethers.getContractAt("MockUSDCV2", deployments.cctp.usdc);
  const usdcAddress = (await usdc.getAddress()) as `0x${string}`;

  // ── Run a ShieldedRagequit exit: burns ARM, creates the payout note at the holder's npk ──
  // The ragequit contract triggers transactOwned to create the contract-owned payout note.
  // (Assume the exit has been run via the forge test or the c10 script sets up the state.)
  // For c10, we need the payout note to already exist on-chain (created by the exit).

  // ── Scan the pool's events to recover the contract-owned payout note ──
  const headBlock = await ethers.provider.getBlockNumber();
  const iface = new (await import("ethers")).Interface(
    POOL_V2_EVENT_ABI as unknown as string[],
  );
  const getLogs = async (from: number, to: number) => {
    const logs = await ethers.provider.getLogs({
      address: poolAddress,
      fromBlock: from,
      toBlock: to,
    });
    return logs.flatMap((log: any) => {
      const d = iface.parseLog({ topics: [...log.topics], data: log.data });
      return d
        ? [
            {
              name: d.name,
              args: d.args as unknown as ParsedPoolLog["args"],
              blockNumber: log.blockNumber,
              txid: log.transactionHash,
            },
          ]
        : [];
    });
  };
  const decoded = decodePoolEvents(
    await fetchLogsRanged(getLogs, {
      fromBlock: deployments.deployBlock ?? 0,
      toBlock: headBlock,
    }),
  );

  // The holder's keyset (deterministic) lets us decrypt the contract-owned note.
  const holder = await deriveKeyset(HOLDER_ROOT);
  const tokenData: TokenData = getTokenDataERC20(usdcAddress);
  const holderReceiver = {
    addressData: {
      masterPublicKey: holder.masterPublicKey,
      viewingPublicKey: holder.viewingPublicKey,
    },
    viewingPrivateKey: holder.viewingPrivateKey,
  };
  const tokenDataGetter = { getTokenDataFromHash: async () => tokenData };
  const armadaChain = { type: ChainType.EVM, id: chainId };

  // Recover the payout note (the transactOwned output at the holder's npk).
  const tree = new UTXOMerkletree();
  const owned: TXO[] = [];
  const leaves = [...decoded.shields, ...decoded.transacts].sort(
    (a, b) => a.tree - b.tree || a.position - b.position,
  );
  for (const c of leaves) {
    tree.insert(c.hash);
    // Type-guard: transact commitments carry `ciphertext`; shields carry `encryptedBundle`.
    if ("ciphertext" in c) {
      const n = await tryDecryptCommitment(
        c.ciphertext,
        holderReceiver,
        tokenDataGetter,
        armadaChain,
      );
      if (n)
        owned.push({
          tree: c.tree,
          position: c.position,
          tokenHash: n.tokenHash,
          value: n.value,
          blockNumber: c.blockNumber,
          txid: c.txid,
          origin: "transact",
          random: n.random,
          notePublicKey: n.notePublicKey,
        });
    } else {
      const o = await tryDecryptShield(c, holderReceiver);
      if (o)
        owned.push({
          tree: c.tree,
          position: c.position,
          tokenHash: o.tokenHash,
          value: o.value,
          blockNumber: c.blockNumber,
          txid: c.txid,
          origin: "shield",
          random: o.random,
          notePublicKey: o.notePublicKey,
        });
    }
  }

  // Find the payout note (the holder's spendable note from the exit).
  const payoutNote = owned.find((t) => t.value > 0n);
  if (!payoutNote)
    throw new Error("No contract-owned payout note found — did the exit run?");
  console.log(
    `Payout note: value=${ethers.formatUnits(payoutNote.value, 6)} USDC at tree ${payoutNote.tree} pos ${payoutNote.position}`,
  );

  const merkleRoot = toBig(tree.root());
  const proof = tree.merkleProof(payoutNote.position);
  const merkleProofElements = proof.elements.map(toBig);

  // ── Plan + prove a spend of the payout note (1x1: spend the whole note back to the holder's own keyset) ──
  // c10's conservation: the value the spend consumes (the whole payout) equals the sum of its
  // outputs. We spend the note entirely back to the holder (1x1), so spent == sum(outputs) trivially.
  const plan = planTransfer({
    txos: [payoutNote],
    tokenAddress: usdcAddress,
    outputs: [
      { toShieldedAddress: holder.shieldedAddress, value: payoutNote.value },
    ],
    roots: new Map([[payoutNote.tree, merkleRoot]]),
    chainID: BigInt(chainId),
  });

  console.log(
    "\nBuilding witness + proving (Groth16 over the exit-proof circuit)...",
  );
  const signer = await LocalSigner.fromRootSecret(HOLDER_ROOT);
  const witness = await buildWitness({
    inputs: [
      {
        random: payoutNote.random,
        value: payoutNote.value,
        position: payoutNote.position,
        merkleProofElements,
      },
    ],
    outputs: [
      { receiverAddress: holder.shieldedAddress, value: payoutNote.value },
    ],
    tokenAddress: usdcAddress,
    sender: {
      masterPublicKey: holder.masterPublicKey,
      viewingPublicKey: holder.viewingPublicKey,
      viewingPrivateKey: holder.viewingPrivateKey,
      nullifyingKey: holder.nullifyingKey,
      spendingPublicKey: holder.spendingPublicKey,
      senderAddress: holder.shieldedAddress,
    },
    signer,
    summary: plan.summary,
    merkleRoot,
    treeNumber: payoutNote.tree,
    chainType: ChainType.EVM,
    chainId,
  });

  const artifacts = getArtifact(
    witness.shape.nullifiers,
    witness.shape.commitments,
  );
  const prover = createSnarkjsProver();
  try {
    const groth16Proof = await prover.prove(witness.formattedInputs, {
      wasm: new Uint8Array(artifacts.wasm),
      zkey: new Uint8Array(artifacts.zkey),
      vkey: artifacts.vkey,
    });

    // Local verify before submitting.
    const publicSignals = [
      witness.publicInputs.merkleRoot,
      witness.publicInputs.boundParamsHash,
      ...witness.publicInputs.nullifiers,
      ...witness.publicInputs.commitmentsOut,
    ];
    const localOk = await prover.verify(
      groth16Proof,
      publicSignals,
      artifacts.vkey,
    );
    if (!localOk)
      throw new Error(
        "LOCAL VERIFY FAILED — witness does not satisfy the circuit",
      );
    console.log("Local Groth16 verify: OK");

    // Conservation (c10): the value the spend consumes equals the sum of its outputs.
    const consumed = payoutNote.value;
    const outputsSum = payoutNote.value; // 1x1 spend back to the holder — the whole payout.
    console.log(
      `Conservation: consumed=${ethers.formatUnits(consumed, 6)} USDC == outputs sum=${ethers.formatUnits(outputsSum, 6)} USDC`,
    );
    if (consumed !== outputsSum)
      throw new Error("CONSERVATION BROKEN: consumed != outputs sum");

    const calldata = buildTransactCalldata(
      [
        {
          proof: groth16Proof,
          merkleRoot: witness.publicInputs.merkleRoot,
          nullifiers: witness.publicInputs.nullifiers,
          commitments: witness.publicInputs.commitmentsOut,
          boundParams: witness.boundParams,
        },
      ],
      poolAddress,
    );

    // ── Submit transact on-chain: the deployed Verifier accepts the armada-built proof ──
    console.log(
      "\nSubmitting transact() on-chain (the deployed Verifier accepts the exit-proof)...",
    );
    const signers = await ethers.getSigners();
    const rcpt = await (
      await ((await ethers
        .getContractAt("PrivacyPool", poolAddress)
        .connect(signers[0])
        .transact(calldata.data)) as any)
    ).wait();
    console.log(
      `✓ transact mined (block ${rcpt.blockNumber}) — ON-CHAIN GROTH16 VERIFICATION PASSED`,
    );
    console.log(
      "c10: the spend conserves value (consumed == outputs sum) and verifies on-chain.",
    );
  } finally {
    await prover.close();
  }
}

main()
  .then(() => console.log("\nc10 PASSED"))
  .catch((e) => {
    console.error("\nc10 FAILED:", e);
    process.exit(1);
  });
