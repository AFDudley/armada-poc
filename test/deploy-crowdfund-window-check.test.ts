// ABOUTME: Mocha test for the ArmadaCrowdfund window-duration deploy check.
// ABOUTME: Proves the check rejects a non-21-day mainnet value and accepts 21 days;
//           mutation-gated on scripts/deploy_crowdfund.ts (c5).

// Initialize the hardhat context so `import { ethers } from "hardhat"` in
// scripts/deploy_crowdfund.ts resolves under a plain mocha run (c5).
require("hardhat");

import { expect } from "chai";
import {
  checkCrowdfundWindow,
  CROWDFUND_PRODUCTION_WINDOW_SECONDS as PRODUCTION_WINDOW_SECONDS,
} from "../scripts/deploy_crowdfund";

describe("ArmadaCrowdfund window duration check", () => {
  it("c1: reports the production window duration as 1814400 seconds (21 days)", () => {
    expect(PRODUCTION_WINDOW_SECONDS).to.equal(1814400);
  });

  it("c2: rejects a non-21-day mainnet value, does not start deploy, and names the duration", () => {
    const r = checkCrowdfundWindow("mainnet", 1209600);
    expect(r.accepted).to.equal(false);
    expect(r.deploy_started).to.equal(false);
    expect(r.error_mentions_window_duration).to.equal(true);
    expect(r.error).to.contain("1209600");
  });

  it("c3: accepts exactly 21 days (1814400s) for mainnet", () => {
    const r = checkCrowdfundWindow("mainnet", 1814400);
    expect(r.accepted).to.equal(true);
    expect(r.deploy_started).to.equal(true);
  });

  it("c4: accepts a short window (3600s) for local config", () => {
    const r = checkCrowdfundWindow("local", 3600);
    expect(r.accepted).to.equal(true);
    expect(r.deploy_started).to.equal(true);
  });
});
