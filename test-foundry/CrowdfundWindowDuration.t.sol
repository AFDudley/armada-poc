// ABOUTME: Window-duration acceptance tests — ArmadaCrowdfund takes the active-window
// ABOUTME: length as a constructor argument stored as an immutable, so the deployer chooses it
// ABOUTME: (21 days in production, a short value on fixture nets).

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./helpers/CrowdfundPoolDeploy.sol";
import "../contracts/crowdfund/ArmadaCrowdfund.sol";
import "../contracts/governance/ArmadaToken.sol";
import "../contracts/cctp/MockUSDCV2.sol";
import "../contracts/privacy-pool/PrivacyPool.sol";

contract CrowdfundWindowDurationTest is Test, CrowdfundPoolDeploy {
    MockUSDCV2 usdc;
    ArmadaCrowdfund cf;

    // Short window for fixture-net testing: 60 seconds, so deploy -> commit -> finalize ->
    // claim can complete within the 1800s gate.
    uint256 constant SHORT_WINDOW = 60;
    // Claim deadline stays a 3-year (1095 days) constant, independent of the window duration.
    uint256 constant CLAIM_DEDLINE_SECONDS = 1095 days;

    // The Safe's owner-derived npk registered as the pool's feeRecipient (P2b).
    bytes32 constant SAFE_NPK = bytes32(uint256(0x5AFE00000000000000000000000000000000000000000000000000000));

    function setUp() public {
        address admin = address(this);
        address treasury = address(0xCAFE);
        usdc = new MockUSDCV2("Mock USDC", "USDC");
        ArmadaToken armToken = new ArmadaToken(admin, admin);
        PrivacyPool pool = _deployPool(address(usdc), address(0xBEEF), address(this), SAFE_NPK);
        cf = new ArmadaCrowdfund(
            address(usdc), address(armToken), treasury, admin, admin, block.timestamp, SHORT_WINDOW, address(pool)
        );
    }

    /// c1: windowEnd == openTimestamp + duration for a non-21-day duration passed to the constructor.
    function test_WindowDuration_windowEndMatchesPassedDuration() public {
        assertEq(cf.windowStart(), block.timestamp, "windowStart must equal openTimestamp");
        assertEq(cf.windowDuration(), SHORT_WINDOW, "windowDuration must equal passed duration");
        assertEq(cf.windowEnd(), block.timestamp + SHORT_WINDOW, "windowEnd mismatch");
    }

    /// c2: launchTeamInviteEnd == openTimestamp + the same passed duration.
    function test_WindowDuration_launchTeamInviteEndMatchesPassedDuration() public {
        assertEq(cf.launchTeamInviteEnd(), block.timestamp + SHORT_WINDOW, "launchTeamInviteEnd mismatch");
        // The launch-team invite window spans the full commitment window: both end at windowEnd.
        assertEq(cf.launchTeamInviteEnd(), cf.windowEnd(), "launchTeamInviteEnd must equal windowEnd");
    }

    /// c3: The constructor reverts when the duration is zero.
    function test_WindowDuration_zeroDurationReverts() public {
        // Deploy with a zero duration must fail (revert on "zero duration").
        try new ArmadaCrowdfund(
            address(usdc),
            address(usdc),
            address(0xCAFE),
            address(this),
            address(this),
            block.timestamp,
            0,
            address(cf.pool())
        ) {
            // If the constructor succeeded, c3 fails: zero duration was not rejected.
            assertTrue(false, "constructor should have reverted on zero duration");
        } catch (bytes memory) {
            // Reverted as expected — zero duration rejected at deploy time.
        }
    }

    /// c4: With a short window, finalize() reverts at block.timestamp == windowEnd and
    ///      succeeds one second later.
    function test_WindowDuration_finalizeOnlyAfterWindowEnd() public {
        uint256 windowEnd_ = cf.windowEnd();

        // At exactly windowEnd, finalize requires block.timestamp > windowEnd, so it reverts.
        vm.warp(windowEnd_);
        vm.expectRevert();
        cf.finalize();

        // One second after windowEnd, finalize succeeds (the short window has passed).
        vm.warp(windowEnd_ + 1);
        cf.finalize();
        // Finalized phase (value 1) and zero committed USDC (no commits) => refund mode.
        assertEq(uint256(cf.phase()), 1, "phase must be Finalized");
        assertEq(cf.refundMode(), true, "no commits -> refund mode");
    }

    /// c5: A crowdfund deployed with a short window still reports a claim deadline length
    ///      of 1095 days (3 years), independent of the window duration.
    function test_WindowDuration_claimDeadlineStaysThreeYears() public {
        assertEq(cf.CLAIM_DEADLINE_DURATION(), CLAIM_DEDLINE_SECONDS, "claim deadline must be 3 years");
    }
}
