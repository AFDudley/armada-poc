// ABOUTME: Reads the deployed ArmadaCrowdfund's active-window length and launch-team
// ABOUTME: invite period from the on-chain immutable state and prints JSON. Used by
// ABOUTME: scripts/report_deployed_crowdfund_window.sh.

import { ethers } from "hardhat";
import { loadDeployment } from "./deploy-utils";
import { getCrowdfundDeploymentFile } from "../config/networks";

async function main() {
  const deployment = loadDeployment(getCrowdfundDeploymentFile());
  if (deployment === null || deployment === undefined) {
    console.error(
      "crowdfund deployment file not found; run the production deploy flow first.",
    );
    process.exit(1);
  }
  const crowdfund = new ethers.Contract(
    deployment.contracts.crowdfund,
    [
      "function windowStart() view returns (uint256)",
      "function windowEnd() view returns (uint256)",
      "function launchTeamInviteEnd() view returns (uint256)",
    ],
    (await ethers.getSigners())[0],
  );

  const [windowStart, windowEnd, launchTeamInviteEnd] = await Promise.all([
    crowdfund.windowStart(),
    crowdfund.windowEnd(),
    crowdfund.launchTeamInviteEnd(),
  ]);

  const windowSeconds = Number(windowEnd - windowStart);
  const inviteSeconds = Number(launchTeamInviteEnd - windowStart);

  console.log(
    JSON.stringify(
      {
        window_seconds: windowSeconds,
        launch_team_invite_seconds: inviteSeconds,
      },
      null,
      2,
    ),
  );
}

main();
