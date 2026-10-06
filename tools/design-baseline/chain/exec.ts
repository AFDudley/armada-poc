// ABOUTME: Generic Hardhat-run chain-mutation script for the interactive baseline — executes an
// ABOUTME: ordered JSON "plan" of primitive crowdfund actions (addSeeds, time-warp, bulk commits,
// ABOUTME: finalize/cancel) against the already-deployed `deployments/crowdfund-hub.json` contract.
//
// One generic script (instead of one file per action) keeps the orchestrator's chain-mutation
// surface small and auditable: every action this pipeline can take against the chain is listed
// in the `Action` union below, in one place.
//
// Usage: CHAIN_PLAN='[{"op":"addSeeds","indices":[1]}, ...]' npx hardhat run tools/design-baseline/chain/exec.ts --network hub

import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const REPO_ROOT = path.resolve(__dirname, "../../..");

type Action =
  | { op: "addSeeds"; indices: number[] }
  | { op: "fundUsdc"; indices: number[] }
  | { op: "advanceToWindowStart" }
  | { op: "advancePastWindowEnd" }
  | { op: "bulkCommit"; startIndex: number; count: number; hop: number; capUsd: number }
  // Hop-0's allocation is ceiling-capped at 47% of saleSize regardless of how much hop-0
  // oversubscribes (ArmadaCrowdfund._computeHopAllocations) — at BASE_SALE ($1.2M) that ceiling is
  // only $564,000, well under MIN_SALE ($1M) on its own. Reaching a genuine (non-refund-mode)
  // finalize needs real hop-1 demand too, which requires an on-chain `invite(invitee, inviterHop)`
  // from an already-eligible address before the invitee can `commit()` at the next hop.
  | {
      op: "inviteAndCommit";
      inviterIndices: number[];
      inviterHop: number;
      inviteesPerInviter: number;
      inviteeStartIndex: number;
      hop: number;
      capUsd: number;
    }
  | { op: "finalize" }
  | { op: "cancel" }
  | { op: "printState" };

function log(tag: string, msg: string) {
  console.log(`[${tag.padEnd(10)}] ${msg}`);
}

function loadCrowdfundDeployment(): { contracts: { crowdfund: string; usdc: string } } {
  const file = path.join(REPO_ROOT, "deployments", "crowdfund-hub.json");
  if (!fs.existsSync(file)) throw new Error(`deployment manifest not found: ${file}`);
  return JSON.parse(fs.readFileSync(file, "utf-8"));
}

async function main() {
  const planRaw = process.env.CHAIN_PLAN;
  if (!planRaw) throw new Error("CHAIN_PLAN env var is required (JSON array of actions)");
  const plan: Action[] = JSON.parse(planRaw);

  const deployment = loadCrowdfundDeployment();
  const crowdfund = await ethers.getContractAt("ArmadaCrowdfund", deployment.contracts.crowdfund);
  const usdc = await ethers.getContractAt("MockUSDCV2", deployment.contracts.usdc);
  const signers = await ethers.getSigners();
  const crowdfundAddr = await crowdfund.getAddress();

  for (const action of plan) {
    log("ACTION", JSON.stringify(action));
    switch (action.op) {
      case "addSeeds": {
        const addresses = action.indices.map((i) => signers[i].address);
        const tx = await crowdfund.addSeeds(addresses);
        await tx.wait();
        // Whitelisting alone does not fund the wallet — the real UI commit flow (approve +
        // commit, driven interactively) checks the connected wallet's actual USDC balance
        // (`overBalance` in Step2Commit.tsx), so every seeded address needs USDC on hand before
        // "Review" can ever be enabled. $1,000,000 comfortably exceeds any per-hop cap.
        const fundAmount = ethers.parseUnits("1000000", 6);
        for (const address of addresses) {
          const mintTx = await usdc.mint(address, fundAmount);
          await mintTx.wait();
        }
        log("addSeeds", `added ${addresses.length} seed(s), funded $1,000,000 USDC each: ${addresses.join(", ")}`);
        break;
      }
      case "fundUsdc": {
        // For addresses that become eligible WITHOUT a direct `addSeeds` whitelist call (e.g. an
        // invite-link redeemer, pre-validated by the signed link itself) — same $1,000,000 mint
        // as `addSeeds`, factored out so both paths fund identically rather than drifting.
        const addresses = action.indices.map((i) => signers[i].address);
        const fundAmount = ethers.parseUnits("1000000", 6);
        for (const address of addresses) {
          const mintTx = await usdc.mint(address, fundAmount);
          await mintTx.wait();
        }
        log("fundUsdc", `funded $1,000,000 USDC each: ${addresses.join(", ")}`);
        break;
      }
      case "advanceToWindowStart": {
        const windowStart = Number(await crowdfund.windowStart());
        const cur = (await ethers.provider.getBlock("latest"))!.timestamp;
        if (cur < windowStart) {
          const jump = windowStart - cur + 1;
          await network.provider.send("evm_increaseTime", [jump]);
          await network.provider.send("evm_mine");
          log("advanceToWindowStart", `jumped ${jump}s — now past windowStart (${windowStart})`);
        } else {
          log("advanceToWindowStart", `already past windowStart (${windowStart}), no-op`);
        }
        break;
      }
      case "advancePastWindowEnd": {
        const windowEnd = Number(await crowdfund.windowEnd());
        const cur = (await ethers.provider.getBlock("latest"))!.timestamp;
        const jump = windowEnd - cur + 1;
        if (jump > 0) {
          await network.provider.send("evm_increaseTime", [jump]);
          await network.provider.send("evm_mine");
        }
        log("advancePastWindowEnd", `now past windowEnd (${windowEnd})`);
        break;
      }
      case "bulkCommit": {
        const amount = ethers.parseUnits(action.capUsd.toString(), 6);
        const participants = signers.slice(action.startIndex, action.startIndex + action.count);
        const addresses = participants.map((s) => s.address);
        // addSeeds in one batch (hop-0 only — this plan is used exclusively to push total
        // committed above MIN_SALE via background hop-0 participants).
        const seedTx = await crowdfund.addSeeds(addresses);
        await seedTx.wait();
        for (const p of participants) {
          const mintTx = await usdc.mint(p.address, amount);
          await mintTx.wait();
          const appTx = await usdc.connect(p).approve(crowdfundAddr, amount);
          await appTx.wait();
          const cmtTx = await crowdfund.connect(p).commit(action.hop, amount);
          await cmtTx.wait();
        }
        log(
          "bulkCommit",
          `${participants.length} participant(s) x $${action.capUsd.toLocaleString()} = ` +
            `$${(participants.length * action.capUsd).toLocaleString()} (hop ${action.hop})`,
        );
        break;
      }
      case "inviteAndCommit": {
        const amount = ethers.parseUnits(action.capUsd.toString(), 6);
        let nextInviteeIndex = action.inviteeStartIndex;
        const invitees: typeof signers = [];
        for (const inviterIndex of action.inviterIndices) {
          const inviter = signers[inviterIndex];
          for (let k = 0; k < action.inviteesPerInviter; k++) {
            const invitee = signers[nextInviteeIndex];
            nextInviteeIndex++;
            const inviteTx = await crowdfund.connect(inviter).invite(invitee.address, action.inviterHop);
            await inviteTx.wait();
            invitees.push(invitee);
          }
        }
        for (const invitee of invitees) {
          const mintTx = await usdc.mint(invitee.address, amount);
          await mintTx.wait();
          const appTx = await usdc.connect(invitee).approve(crowdfundAddr, amount);
          await appTx.wait();
          const cmtTx = await crowdfund.connect(invitee).commit(action.hop, amount);
          await cmtTx.wait();
        }
        log(
          "inviteAndCommit",
          `${invitees.length} invitee(s) from ${action.inviterIndices.length} inviter(s) (hop ${action.inviterHop}→${action.hop}) x $${action.capUsd.toLocaleString()} = ` +
            `$${(invitees.length * action.capUsd).toLocaleString()}`,
        );
        break;
      }
      case "finalize": {
        const tx = await crowdfund.finalize();
        await tx.wait();
        const phase = Number(await crowdfund.phase());
        const refundMode = await crowdfund.refundMode();
        log("finalize", `phase=${phase} refundMode=${refundMode}`);
        break;
      }
      case "cancel": {
        const tx = await crowdfund.connect(signers[10]).cancel();
        await tx.wait();
        log("cancel", "cancelled by security council (signers[10])");
        break;
      }
      case "printState": {
        const [phase, totalCommitted, windowStart, windowEnd, refundMode] = await Promise.all([
          crowdfund.phase(),
          crowdfund.totalCommitted(),
          crowdfund.windowStart(),
          crowdfund.windowEnd(),
          crowdfund.refundMode(),
        ]);
        const blockTs = (await ethers.provider.getBlock("latest"))!.timestamp;
        log(
          "state",
          `phase=${phase} totalCommitted=$${ethers.formatUnits(totalCommitted, 6)} ` +
            `windowStart=${windowStart} windowEnd=${windowEnd} blockTs=${blockTs} refundMode=${refundMode}`,
        );
        break;
      }
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
