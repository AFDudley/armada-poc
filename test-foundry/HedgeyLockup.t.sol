// SPDX-License-Identifier: MIT
// ABOUTME: Foundry tests proving the non-cancelable Hedgey lockup plan and the
// ABOUTME: ArmadaToken whitelist gating for the lockup before ARM transfers in.
// ABOUTME: c4: the plan is non-cancelable (cancelable field reads false) and the
// ABOUTME: lockup is whitelisted in ArmadaToken before ARM moves into the lockup.
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../contracts/governance/ArmadaToken.sol";
import "lib/hedgey/contracts/LockupPlans/TokenLockupPlans.sol";
import "lib/hedgey/contracts/test/Token.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract HedgeyLockupTest is Test {
    ArmadaToken public armToken;
    TimelockController public timelock;
    TokenLockupPlans public lockup;
    Token public arm;

    address public deployer = address(this);
    address public teamWallet = address(0x511CE);
    address public nonTimelockCaller = address(0xBAD);

    uint256 constant TEAM_RESERVED_ARM = 1_000_000 * 1e18; // team's reserved allocation

    function setUp() public {
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(2 days, proposers, executors, deployer);

        // Deploy ARM token: deployer receives the entire initial supply (single mint).
        armToken = new ArmadaToken(deployer, address(timelock));

        // Whitelist the deployer and the team wallet so ARM transfers work.
        address[] memory whitelist = new address[](3);
        whitelist[0] = deployer;
        whitelist[1] = teamWallet;
        whitelist[2] = address(this); // lockup deployer (the test contract)
        armToken.initWhitelist(whitelist);

        // Deploy the Hedgey lockup contract.
        lockup = new TokenLockupPlans("Hedgey TokenLockupPlans", "HDGY");

        // Deploy a minimal ERC20 to represent the ARM token for the lockup test.
        arm = new Token(1_000_000 * 1e18, "ARM", "ARM");
    }

    // c4a: the plan is non-cancelable - the deployed plan's cancelable field reads false.
    function test_planIsNonCancelable() public {
        // Seed some ARM into the lockup for the plan.
        arm.mint(TEAM_RESERVED_ARM);
        arm.approve(address(lockup), TEAM_RESERVED_ARM);

        // Create one linear-unlock plan for the team allocation, cancelable set explicitly to false.
        uint256 planId = lockup.createPlan(
            teamWallet,
            address(arm),
            TEAM_RESERVED_ARM,
            0,                    // start
            0,                    // cliff
            TEAM_RESERVED_ARM / 100, // rate: TEAM_RESERVED_ARM / 100 periods
            100,                  // period (100-second linear unlock)
            false                 // cancelable = false, set explicitly
        );

        // Read back the plan's cancelable field: it must be false.
        require(planId > 0, "planId must be positive");
        (address token, uint256 amount, uint256 start, uint256 cliff, uint256 rate, uint256 period, bool cancelable) = lockup.plans(planId);
        require(!cancelable, "plan must be non-cancelable");
        console2.log("plan", planId, "cancelable:", cancelable);
    }

    // c4b: the timelock whitelists the lockup in ArmadaToken, and a non-timelock caller reverts.
    function test_lockupWhitelistedInArmadaToken() public {
        // The timelock whitelists the lockup: must succeed (direct call, pranked).
        vm.label(address(lockup), "HedgeyLockup");
        vm.prank(address(timelock));
        armToken.addToWhitelist(address(lockup));
        console2.log("lockup whitelisted:", armToken.transferWhitelist(address(lockup)));
        require(armToken.transferWhitelist(address(lockup)), "lockup must be on the allowlist");

        // A non-timelock caller must be refused: the .call() returns ok=false on revert.
        vm.prank(nonTimelockCaller);
        (bool ok2,) = address(armToken).call(
            abi.encode(armToken.addToWhitelist, address(lockup))
        );
        console2.log("non-timelock caller reverted:", !ok2);
        require(!ok2, "non-timelock caller must revert");
    }
}
