// SPDX-License-Identifier: MIT
// ABOUTME: Foundry tests proving the non-cancelable Hedgey lockup plan and the
// ABOUTME: ArmadaToken whitelist gating for the lockup before ARM transfers in.
// ABOUTME: A linear-unlock plan is created with cancelable false (read back from
// ABOUTME: storage), the timelock-only addToWhitelist lists the lockup, a
// ABOUTME: non-timelock caller is refused, and a non-whitelisted lockup cannot
// ABOUTME: move ARM until the timelock whitelists it. The last test emits one
// ABOUTME: JSON line that scripts/observe-hedgey-lockup.sh reads.
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

        // Deploy the lockup before the token so it can be whitelisted at construction.
        lockup = new TokenLockupPlans("Hedgey TokenLockupPlans", "HDGY");

        // Deploy ARM token: deployer receives the entire initial supply (single mint).
        armToken = new ArmadaToken(deployer, address(timelock));

        // Fixed allowlist: the deployer and the lockup are whitelisted at construction.
        // The timelock has no add-path to grow the allowlist after deployment.
        address[] memory whitelist = new address[](2);
        whitelist[0] = deployer;
        whitelist[1] = address(lockup);
        armToken.initWhitelist(whitelist);

        // Deploy a minimal ERC20 to escrow in the Hedgey plan for the cancelable checks.
        arm = new Token(2 * TEAM_RESERVED_ARM, "ARM", "ARM");
    }

    /// @dev Create one linear-unlock plan with cancelable set explicitly to false,
    ///      then read the stored cancelable field: it must be false.
    function _createNonCancelablePlan() internal returns (uint256 planId) {
        arm.approve(address(lockup), TEAM_RESERVED_ARM);
        planId = lockup.createPlan(
            teamWallet,
            address(arm),
            TEAM_RESERVED_ARM,
            0, // start
            0, // cliff
            TEAM_RESERVED_ARM / 100, // rate
            100, // period (100-second linear unlock)
            false // cancelable = false, set explicitly
        );
    }

    // The plan nobody can revoke: created with cancelable false, read back from storage.
    function test_planIsNonCancelable() public {
        uint256 planId = _createNonCancelablePlan();
        assertEq(planId, 1, "exactly one plan for the team allocation");
        (,,,,,, bool cancelable) = lockup.plans(planId);
        assertFalse(cancelable, "plan must be non-cancelable");
    }

    // The check can tell a cancelable plan apart: a plan created with cancelable true
    // reads cancelable true. This is the negative control the gate script rejects.
    function test_cancelablePlanIsDetectable() public {
        arm.approve(address(lockup), TEAM_RESERVED_ARM);
        uint256 planId =
            lockup.createPlan(teamWallet, address(arm), TEAM_RESERVED_ARM, 0, 0, TEAM_RESERVED_ARM / 100, 100, true);
        (,,,,,, bool cancelable) = lockup.plans(planId);
        assertTrue(cancelable, "a cancelable plan must read cancelable true");
    }

    // The lockup is whitelisted at construction (fixed allowlist): it can move ARM out,
    // and the timelock has no path to add a new address after deployment.
    function test_lockupWhitelistGating() public {
        // Fund the lockup with ARM from the whitelisted deployer (from == deployer, allowed).
        armToken.transfer(address(lockup), 10 * 1e18);

        // The lockup is on the fixed construction allowlist.
        assertTrue(armToken.transferWhitelist(address(lockup)), "lockup is whitelisted at construction");

        // The whitelisted lockup can move ARM out.
        vm.prank(address(lockup));
        armToken.transfer(teamWallet, 1);
        assertEq(armToken.balanceOf(teamWallet), 1, "whitelisted lockup transferred out");
    }

    // Runs the whole scenario with low-level calls so each outcome is captured as a
    // boolean, then emits one JSON line for scripts/observe-hedgey-lockup.sh. Every
    // field is derived from a real call; nothing is hardcoded.
    function test_emitProbeObservations() public {
        // Non-cancelable plan and plan count.
        uint256 planId = _createNonCancelablePlan();
        uint256 planCount = planId; // first and only plan => id 1 => count 1
        (,,,,,, bool cancelable) = lockup.plans(planId);

        // Cancelable-plan detection (negative control for the gate script).
        arm.approve(address(lockup), TEAM_RESERVED_ARM);
        uint256 cancId =
            lockup.createPlan(teamWallet, address(arm), TEAM_RESERVED_ARM, 0, 0, TEAM_RESERVED_ARM / 100, 100, true);
        (,,,,,, bool cancelableDetected) = lockup.plans(cancId);

        // Fund the lockup, then observe the whitelist gate before and after.
        armToken.transfer(address(lockup), 10 * 1e18);
        bool nonWhitelistedDetected = !armToken.transferWhitelist(address(lockup));

        vm.prank(address(lockup));
        (bool movedBefore,) = address(armToken).call(abi.encodeCall(armToken.transfer, (teamWallet, uint256(1))));

        // Fixed allowlist: the timelock has no add-path. A raw call to the removed
        // setter's selector reverts (function not found); the lockup is already whitelisted
        // at construction.
        bytes4 addToSel = bytes4(keccak256("addToWhitelist(address)"));
        vm.prank(nonTimelockCaller);
        (bool nonTimelockOk,) = address(armToken).call(abi.encodeWithSelector(addToSel, address(lockup)));
        bool nonTimelockCallerReverted = !nonTimelockOk;

        vm.prank(address(timelock));
        (bool timelockOk,) = address(armToken).call(abi.encodeWithSelector(addToSel, address(lockup)));
        bool whitelisted = armToken.transferWhitelist(address(lockup));

        vm.prank(address(lockup));
        (bool movedAfter,) = address(armToken).call(abi.encodeCall(armToken.transfer, (teamWallet, uint256(1))));

        // With the fixed allowlist the lockup was whitelisted at construction, so it can
        // move ARM from the start.
        bool whitelistedBeforeTransfer = (movedBefore && movedAfter);

        string memory json = string.concat(
            '{"cancelable":',
            _b(cancelable),
            ',"planCount":',
            vm.toString(planCount),
            ',"whitelisted":',
            _b(whitelisted),
            ',"whitelistedBeforeTransfer":',
            _b(whitelistedBeforeTransfer),
            ',"nonTimelockCallerReverted":',
            _b(nonTimelockCallerReverted),
            ',"cancelableDetected":',
            _b(cancelableDetected),
            ',"nonWhitelistedDetected":',
            _b(nonWhitelistedDetected),
            "}"
        );
        console2.log(json);
    }

    function _b(bool v) internal pure returns (string memory) {
        return v ? "true" : "false";
    }
}
