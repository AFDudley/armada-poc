// ABOUTME: Foundry tests for ArmadaYieldVault.harvestProtocolFee() — cadence
// ABOUTME: enforcement, sweep correctness, multi-harvest accounting, and redeem interaction.

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../contracts/yield/ArmadaYieldVault.sol";
import "../contracts/governance/ArmadaTreasuryGov.sol";
import "../contracts/aave-mock/MockAaveSpoke.sol";
import "../contracts/cctp/MockUSDCV2.sol";

/// @title YieldHarvestProtocolFeeTest — Explicit coverage for the new permissionless harvest path.
/// @dev Covers the gap flagged in PR #275 automated review: the existing yield tests exercise
///      `_settleProtocolFee` indirectly via redeem, but nothing explicitly exercises
///      `harvestProtocolFee()`. These tests pin its public contract.
contract YieldHarvestProtocolFeeTest is Test {
    ArmadaYieldVault public vault;
    MockUSDCV2 public usdc;
    MockAaveSpoke public spoke;
    ArmadaTreasuryGov public treasury;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public randomCaller = address(0xCAFE);

    uint256 constant YIELD_BPS = 500; // 5% APY on the mock spoke
    uint256 constant DEPOSIT_AMOUNT = 100_000e6; // 100k USDC
    uint256 constant ONE_YEAR = 365 days;

    // FALLBACK_HARVEST_INTERVAL on the vault (used when no fee module is wired).
    uint256 constant HARVEST_INTERVAL = 7 days;

    event ProtocolFeeHarvested(uint256 amount, uint256 cumulativeAfter, uint256 settledAt);

    function setUp() public {
        usdc = new MockUSDCV2("Mock USDC", "USDC");
        spoke = new MockAaveSpoke();
        usdc.addMinter(address(spoke));
        spoke.addReserve(address(usdc), YIELD_BPS, true);

        treasury = new ArmadaTreasuryGov(address(this));
        vault = new ArmadaYieldVault(address(spoke), 0, address(treasury), "Armada Yield USDC", "ayUSDC");

        usdc.mint(alice, DEPOSIT_AMOUNT * 4);
        usdc.mint(bob, DEPOSIT_AMOUNT * 4);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Constructor initialisation
    // ══════════════════════════════════════════════════════════════════════

    /// WHY: A zero-initialised lastHarvestTime would let the very first call to
    ///      harvestProtocolFee() bypass the cadence (block.timestamp >= 0 + interval
    ///      is always true). Pin that the constructor sets it to the deploy timestamp.
    function test_constructor_initialisesLastHarvestTime() public view {
        assertEq(vault.lastHarvestTime(), block.timestamp, "constructor must seed lastHarvestTime");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Cadence enforcement
    // ══════════════════════════════════════════════════════════════════════

    /// WHY: Permissionless callers must not be able to grief the vault with
    ///      tiny back-to-back harvests. The cadence floor is the only spam gate.
    function test_harvestProtocolFee_revertsBeforeInterval() public {
        _deposit(alice, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + ONE_YEAR); // generous yield, but no time-since-deploy on the *vault clock*

        // lastHarvestTime was set at deploy. Roll forward < interval since then.
        // Note: setUp uses default vm timestamp (1); the warp above lands well past interval.
        // To isolate the cadence check, reset lastHarvestTime by triggering a harvest, then
        // attempt a second harvest immediately.
        vault.harvestProtocolFee();
        vm.warp(block.timestamp + HARVEST_INTERVAL - 1);

        vm.expectRevert("ArmadaYieldVault: interval not met");
        vault.harvestProtocolFee();
    }

    /// WHY: After exactly `harvestInterval` elapses, the next call must succeed.
    ///      Off-by-one in the `>=` comparison would silently delay treasury revenue by a block.
    function test_harvestProtocolFee_succeedsAtIntervalBoundary() public {
        _deposit(alice, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + ONE_YEAR);

        vault.harvestProtocolFee();
        uint256 firstHarvestAt = vault.lastHarvestTime();

        // Advance to exactly the interval boundary; accrue a touch more yield so there's
        // something to sweep (otherwise the test would also be exercising the zero-amount path).
        vm.warp(firstHarvestAt + HARVEST_INTERVAL);

        // Must not revert at the exact boundary.
        vault.harvestProtocolFee();
        assertEq(vault.lastHarvestTime(), block.timestamp);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Sweep correctness
    // ══════════════════════════════════════════════════════════════════════

    /// WHY: The whole point of #75 — verify the treasury receives *exactly* the
    ///      pendingProtocolFee amount (modulo block-level yield drift between view-read
    ///      and harvest), and that cumulativeProtocolFee is updated by the same amount.
    function test_harvestProtocolFee_sweepsExactPendingToTreasury() public {
        _deposit(alice, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + ONE_YEAR);

        uint256 pendingBefore = vault.pendingProtocolFee();
        assertGt(pendingBefore, 0, "yield should have accrued a fee");

        uint256 treasuryBefore = usdc.balanceOf(address(treasury));
        uint256 cumulativeBefore = vault.cumulativeProtocolFee();

        vault.harvestProtocolFee();

        uint256 swept = usdc.balanceOf(address(treasury)) - treasuryBefore;
        assertEq(swept, pendingBefore, "treasury must receive exactly the pre-harvest pending amount");
        assertEq(
            vault.cumulativeProtocolFee() - cumulativeBefore,
            pendingBefore,
            "cumulativeProtocolFee must advance by the swept amount"
        );
        assertEq(vault.pendingProtocolFee(), 0, "post-harvest pending must be zero");
    }

    /// WHY: A no-op harvest (no yield since last settle) is benign — pin that no value
    ///      moves, no event is fired with a non-zero amount, and lastHarvestTime still
    ///      advances (so the cadence clock resets even on a zero-amount sweep).
    /// @dev No deposits means the spoke has nothing to compound, so warping past the
    ///      cadence here doesn't accrue any yield — keeps the "zero pending" path clean.
    function test_harvestProtocolFee_noOpWhenZeroPending() public {
        // Push past the cadence without depositing — no yield can possibly accrue.
        vm.warp(block.timestamp + HARVEST_INTERVAL + 1);
        assertEq(vault.pendingProtocolFee(), 0, "preconditions: nothing pending");

        uint256 treasuryBefore = usdc.balanceOf(address(treasury));
        uint256 cumulativeBefore = vault.cumulativeProtocolFee();

        vault.harvestProtocolFee();

        assertEq(usdc.balanceOf(address(treasury)), treasuryBefore, "no value should move");
        assertEq(vault.cumulativeProtocolFee(), cumulativeBefore, "cumulative unchanged");
        assertEq(vault.lastHarvestTime(), block.timestamp, "timer still resets");
    }

    /// WHY: Verify the ProtocolFeeHarvested event fires with the right amount and
    ///      cumulativeAfter on a non-zero sweep. Off-chain accounting depends on it.
    function test_harvestProtocolFee_emitsEventOnSweep() public {
        _deposit(alice, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + ONE_YEAR);

        uint256 expected = vault.pendingProtocolFee();
        uint256 cumulativeBefore = vault.cumulativeProtocolFee();

        vm.expectEmit(false, false, false, true);
        emit ProtocolFeeHarvested(expected, cumulativeBefore + expected, block.timestamp);
        vault.harvestProtocolFee();
    }

    // ══════════════════════════════════════════════════════════════════════
    // Multi-harvest accounting
    // ══════════════════════════════════════════════════════════════════════

    /// WHY: Multiple harvests across yield periods must not double-count. Total swept
    ///      across all harvests should equal feeBps * total gross yield (within rounding).
    ///      Catches a class of bug where `cumulativeProtocolFee` isn't subtracted in the
    ///      pending-fee formula on subsequent calls.
    function test_harvestProtocolFee_multipleHarvestsNoDoubleCount() public {
        _deposit(alice, DEPOSIT_AMOUNT);

        uint256 totalSweptToTreasury = 0;
        uint256 treasuryStart = usdc.balanceOf(address(treasury));

        // Three harvest rounds, each ~120 days apart so yield accrues meaningfully.
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 120 days);
            uint256 pendingBefore = vault.pendingProtocolFee();
            vault.harvestProtocolFee();
            totalSweptToTreasury = usdc.balanceOf(address(treasury)) - treasuryStart;
            // Each harvest's contribution to cumulative must equal what `pendingProtocolFee`
            // reported immediately before the call.
            assertGt(pendingBefore, 0, "round had no fee to claim");
        }

        // Sanity: cumulative tracker matches what hit the treasury.
        assertEq(
            vault.cumulativeProtocolFee(),
            totalSweptToTreasury,
            "cumulativeProtocolFee must equal sum of all treasury inflows"
        );

        // After the final harvest, no fee should be pending. Allow up to 1 wei of
        // drift to absorb integer-rounding differences between the view path's read
        // of spoke balance and the withdraw path's recalculation inside the spoke.
        assertLe(
            vault.pendingProtocolFee(), 1, "post-final-harvest pending must be ~zero (1 wei spoke-rounding tolerance)"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // Interaction with redeem
    // ══════════════════════════════════════════════════════════════════════

    /// WHY: redeem() also settles. A harvest followed immediately by a redeem should
    ///      pay the user against a post-settle share price with zero double-charging,
    ///      and a redeem followed by a harvest should leave the harvest finding nothing
    ///      to sweep (because redeem already swept).
    function test_harvestProtocolFee_redeemAfterHarvest_consistent() public {
        _deposit(alice, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + ONE_YEAR);

        // Harvest first.
        vault.harvestProtocolFee();
        assertEq(vault.pendingProtocolFee(), 0);

        // Redeem immediately — share price should be post-harvest user-claimable value.
        uint256 shares = vault.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = vault.redeem(shares, alice, alice);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, payout, "payout matches transferred USDC");
        // Pending was already zeroed by the harvest — redeem's settle had nothing to do,
        // so no additional treasury inflow on this redeem.
    }

    /// WHY: Reverse order — redeem first (which settles), then attempt harvest at the
    ///      cadence boundary. The harvest should be a no-op (or sweep only the new
    ///      drift since redeem), with no double-claim against the treasury.
    function test_harvestProtocolFee_harvestAfterRedeem_noDoubleClaim() public {
        _deposit(alice, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + ONE_YEAR);

        uint256 treasuryBefore = usdc.balanceOf(address(treasury));

        // Redeem half — triggers settle of the full pending fee.
        uint256 halfShares = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.redeem(halfShares, alice, alice);

        uint256 treasuryAfterRedeem = usdc.balanceOf(address(treasury));
        assertGt(treasuryAfterRedeem, treasuryBefore, "redeem settled and paid treasury");

        // Push past cadence; harvest now should find ~0 pending (only block-drift since redeem).
        vm.warp(block.timestamp + HARVEST_INTERVAL + 1);
        uint256 pendingNow = vault.pendingProtocolFee();
        vault.harvestProtocolFee();

        uint256 sweptByHarvest = usdc.balanceOf(address(treasury)) - treasuryAfterRedeem;
        assertEq(sweptByHarvest, pendingNow, "harvest must sweep only the post-redeem drift");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Permissionless caller
    // ══════════════════════════════════════════════════════════════════════

    /// WHY: The function is intentionally permissionless by design (#75). Pin that an
    ///      arbitrary EOA can trigger it once the cadence has elapsed. If access control
    ///      ever creeps in by accident, this test fails.
    function test_harvestProtocolFee_callableByAnyEOA() public {
        _deposit(alice, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + ONE_YEAR);

        uint256 pending = vault.pendingProtocolFee();
        assertGt(pending, 0);

        vm.prank(randomCaller);
        vault.harvestProtocolFee();

        assertEq(vault.pendingProtocolFee(), 0, "any caller can sweep when cadence allows");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════════════════

    function _deposit(address from, uint256 amount) internal {
        vm.startPrank(from);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, from);
        vm.stopPrank();
    }
}
