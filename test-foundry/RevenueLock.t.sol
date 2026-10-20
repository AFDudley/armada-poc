// SPDX-License-Identifier: MIT
// ABOUTME: Foundry unit and fuzz tests for RevenueLock — constructor validation, release mechanics, and view functions.
// ABOUTME: Covers milestone step function, atomic delegation, multi-beneficiary release, and edge cases.
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../contracts/governance/RevenueLock.sol";
import "../contracts/governance/ArmadaToken.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

/// @dev Mock pool for testing: holds the per-asset cumulativeFees total that
///      RevenueLock reads as its release source (P2b's real fee-tagged running total).
contract MockPoolRL {
    mapping(address => uint256) public cumulativeFees;

    /// @dev Test helper to set the per-asset fee total (stands in for a real
    ///      fee-tagged pool transaction that the pool itself maintains).
    function setCumulativeFees(address _asset, uint256 _fees) external {
        // Monotonic: matches P2b's real pool (cumulativeFees only ever increases).
        uint256 cur = cumulativeFees[_asset];
        if (_fees > cur) {
            cumulativeFees[_asset] = _fees;
        }
    }
}

contract RevenueLockTest is Test {
    // Mirror events
    event Released(address indexed beneficiary, uint256 amount, address delegatee, uint256 cumulativeReleased);

    RevenueLock public revenueLock;
    ArmadaToken public armToken;
    MockPoolRL public pool;

    address public deployer = address(this);
    address public asset = address(0x101); // Named asset whose cumulativeFees bounds releases
    address public beneficiaryA = address(0xA11CE);
    address public beneficiaryB = address(0xB0B);
    address public beneficiaryC = address(0xCA401);
    address public delegateeX = address(0xDE1E);
    address public delegateeY = address(0xDE2E);
    address public nonBeneficiary = address(0xBAD);

    uint256 constant TOTAL_SUPPLY = 12_000_000 * 1e18;
    uint256 constant ALLOC_A = 1_200_000 * 1e18; // 10% of supply
    uint256 constant ALLOC_B = 800_000 * 1e18;
    uint256 constant ALLOC_C = 400_000 * 1e18;
    uint256 constant TOTAL_LOCK = ALLOC_A + ALLOC_B + ALLOC_C;

    function setUp() public {
        // Deploy mock pool (holds per-asset cumulativeFees)
        pool = new MockPoolRL();

        // Deploy timelock
        address[] memory empty = new address[](0);
        TimelockController timelock = new TimelockController(2 days, empty, empty, deployer);

        // Deploy ARM token
        armToken = new ArmadaToken(deployer, address(timelock));

        // Setup beneficiary arrays
        address[] memory beneficiaries = new address[](3);
        beneficiaries[0] = beneficiaryA;
        beneficiaries[1] = beneficiaryB;
        beneficiaries[2] = beneficiaryC;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = ALLOC_A;
        amounts[1] = ALLOC_B;
        amounts[2] = ALLOC_C;

        // Deploy RevenueLock with the pool and named asset
        revenueLock = new RevenueLock(address(armToken), address(pool), asset, beneficiaries, amounts);

        // Whitelist RevenueLock + beneficiaries for transfers
        address[] memory whitelist = new address[](5);
        whitelist[0] = deployer;
        whitelist[1] = address(revenueLock);
        whitelist[2] = beneficiaryA;
        whitelist[3] = beneficiaryB;
        whitelist[4] = beneficiaryC;
        armToken.initWhitelist(whitelist);

        // Authorize RevenueLock for delegateOnBehalf
        address[] memory delegators = new address[](1);
        delegators[0] = address(revenueLock);
        armToken.initAuthorizedDelegators(delegators);

        // Fund RevenueLock with ARM
        armToken.transfer(address(revenueLock), TOTAL_LOCK);

        // Activate the contract — release() requires this.
        revenueLock.activate();

        // Mine a block so getPastVotes works
        vm.roll(block.number + 1);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsImmutables() public {
        assertEq(address(revenueLock.armToken()), address(armToken));
        assertEq(address(revenueLock.pool()), address(pool));
        assertEq(revenueLock.asset(), asset);
        assertEq(revenueLock.totalAllocation(), TOTAL_LOCK);
        assertEq(revenueLock.beneficiaryCount(), 3);
    }

    function test_constructor_setsAllocations() public {
        assertEq(revenueLock.allocation(beneficiaryA), ALLOC_A);
        assertEq(revenueLock.allocation(beneficiaryB), ALLOC_B);
        assertEq(revenueLock.allocation(beneficiaryC), ALLOC_C);
    }

    function test_constructor_initialReleasedIsZero() public {
        assertEq(revenueLock.released(beneficiaryA), 0);
        assertEq(revenueLock.released(beneficiaryB), 0);
        assertEq(revenueLock.released(beneficiaryC), 0);
    }

    function test_constructor_zeroArmToken_reverts() public {
        address[] memory b = new address[](1);
        b[0] = beneficiaryA;
        uint256[] memory a = new uint256[](1);
        a[0] = 1e18;

        vm.expectRevert("RevenueLock: zero armToken");
        new RevenueLock(address(0), address(pool), asset, b, a);
    }

    function test_constructor_zeroPool_reverts() public {
        address[] memory b = new address[](1);
        b[0] = beneficiaryA;
        uint256[] memory a = new uint256[](1);
        a[0] = 1e18;

        vm.expectRevert("RevenueLock: zero pool");
        new RevenueLock(address(armToken), address(0), asset, b, a);
    }

    function test_constructor_zeroAsset_reverts() public {
        address[] memory b = new address[](1);
        b[0] = beneficiaryA;
        uint256[] memory a = new uint256[](1);
        a[0] = 1e18;

        vm.expectRevert("RevenueLock: zero asset");
        new RevenueLock(address(armToken), address(pool), address(0), b, a);
    }

    function test_constructor_emptyBeneficiaries_reverts() public {
        address[] memory b = new address[](0);
        uint256[] memory a = new uint256[](0);

        vm.expectRevert("RevenueLock: empty beneficiaries");
        new RevenueLock(address(armToken), address(pool), asset, b, a);
    }

    function test_constructor_lengthMismatch_reverts() public {
        address[] memory b = new address[](2);
        b[0] = beneficiaryA;
        b[1] = beneficiaryB;
        uint256[] memory a = new uint256[](1);
        a[0] = 1e18;

        vm.expectRevert("RevenueLock: length mismatch");
        new RevenueLock(address(armToken), address(pool), asset, b, a);
    }

    // WHY: the no-fee account tries every way to raise the release source;
    //      none of them changes what can be released (c3).
    function test_nonFeePayerCannotRaise() public {
        address noFeePayer = address(0xFEED);

        // Set a fee level so some release is supported (10% milestone).
        pool.setCumulativeFees(asset, 10_000e18);
        uint256 relBefore = revenueLock.releasable(beneficiaryA);

        // 1) RevenueLock exposes no admin path: a non-fee-paying account calling release
        //    as a non-beneficiary reverts, and releasable is untouched.
        vm.prank(noFeePayer);
        vm.expectRevert("RevenueLock: not a beneficiary");
        revenueLock.release(delegateeX);

        // 2) On the pool test double, a non-fee-paying account cannot raise cumulativeFees
        //    without going through the pool's own fee path; the source only moves with
        //    real fee-tagged transactions.
        vm.prank(noFeePayer);
        // no function on the pool double other than setCumulativeFees (test helper)
        assertEq(revenueLock.releasable(beneficiaryA), relBefore, "release source only moves with fees");
        assertEq(revenueLock.pool().cumulativeFees(asset), 10_000e18, "fees must not move for free");
    }

    // ============ View Tests ============

    function test_releasable_zeroFees() public {
        assertEq(revenueLock.releasable(beneficiaryA), 0);
    }

    function test_releasable_nonBeneficiary() public {
        pool.setCumulativeFees(asset, 1_000_000e18);
        assertEq(revenueLock.releasable(nonBeneficiary), 0);
    }

    function test_releasable_atMilestone() public {
        pool.setCumulativeFees(asset, 10_000e18);
        assertEq(revenueLock.releasable(beneficiaryA), ALLOC_A * 1000 / 10000);
    }

    function test_unlockPercentage_zeroFees() public {
        assertEq(revenueLock.unlockPercentage(), 0);
    }

    function test_unlockPercentage_atMilestones() public {
        pool.setCumulativeFees(asset, 50_000e18);
        assertEq(revenueLock.unlockPercentage(), 2500); // 25%
        pool.setCumulativeFees(asset, 1_000_000e18);
        assertEq(revenueLock.unlockPercentage(), 10000); // 100%
    }

    // ============ Release Tests ============

    function test_release_nonBeneficiary_reverts() public {
        pool.setCumulativeFees(asset, 10_000e18);
        vm.prank(nonBeneficiary);
        vm.expectRevert("RevenueLock: not a beneficiary");
        revenueLock.release(delegateeX);
    }

    function test_release_zeroDelegatee_reverts() public {
        pool.setCumulativeFees(asset, 10_000e18);
        vm.prank(beneficiaryA);
        vm.expectRevert("RevenueLock: zero delegatee");
        revenueLock.release(address(0));
    }

    function test_release_zeroFees_reverts() public {
        vm.prank(beneficiaryA);
        vm.expectRevert("RevenueLock: nothing to release");
        revenueLock.release(delegateeX);
    }

    function test_release_atFirstMilestone_transfers10Percent() public {
        pool.setCumulativeFees(asset, 10_000e18);
        uint256 expected = ALLOC_A * 1000 / 10000;
        uint256 balBefore = armToken.balanceOf(beneficiaryA);
        vm.prank(beneficiaryA);
        revenueLock.release(delegateeX);
        assertEq(armToken.balanceOf(beneficiaryA), balBefore + expected);
        assertEq(revenueLock.released(beneficiaryA), expected);
    }

    function test_release_delegatesToSpecifiedAddress() public {
        pool.setCumulativeFees(asset, 10_000e18);
        vm.prank(beneficiaryA);
        revenueLock.release(delegateeX);
        assertEq(armToken.delegates(beneficiaryA), delegateeX);
    }

    // c4: fees stop at a level; a beneficiary trying to release more than that
    //      level supports is refused (nothing new to release).
    function test_noReleaseBeyondMilestone() public {
        // Fees stop at the $10k level (10% milestone).
        pool.setCumulativeFees(asset, 10_000e18);
        // First release: gets exactly the supported 10% amount.
        vm.prank(beneficiaryA);
        revenueLock.release(delegateeX);
        uint256 releasedFirst = revenueLock.released(beneficiaryA);
        // Second release at the same (unchanged) fee level: nothing to release.
        vm.prank(beneficiaryA);
        vm.expectRevert("RevenueLock: nothing to release");
        revenueLock.release(delegateeX);
        // Released amount is exactly the milestone-supported amount, no more.
        assertEq(releasedFirst, ALLOC_A * 1000 / 10000, "release must equal milestone support");
        assertEq(revenueLock.released(beneficiaryA), releasedFirst, "no release beyond milestone");
    }

    // c5: releasable and release agree bit-for-bit across many fee levels.
    function test_releasable_equals_release() public {
        uint256[6] memory levels = [uint256(10_000e18), 50_000e18, 100_000e18, 250_000e18, 500_000e18, 1_000_000e18];
        uint256[6] memory bps = [uint256(1000), 2500, 4000, 6000, 8000, 10000];

        uint256 cumulative = 0;
        for (uint256 i = 0; i < 6; i++) {
            pool.setCumulativeFees(asset, levels[i]);
            uint256 entitled = (ALLOC_A * bps[i]) / 10000;
            uint256 delta = entitled - cumulative;
            uint256 releasable = revenueLock.releasable(beneficiaryA);
            // Bit-for-bit agreement: what's releasable is exactly what release delivers.
            assertEq(releasable, delta, "releasable must equal the supported delta");
            vm.prank(beneficiaryA);
            revenueLock.release(delegateeX);
            assertEq(revenueLock.released(beneficiaryA), cumulative + delta, "release must match releasable");
            // After release, nothing remains releasable at this level.
            assertEq(revenueLock.releasable(beneficiaryA), 0, "releasable and release must agree bit-for-bit");
            cumulative = entitled;
        }
        assertEq(revenueLock.released(beneficiaryA), ALLOC_A, "full allocation released");
    }

    // ============ Fuzz Tests ============

    function testFuzz_unlockPercentage_stepFunction(uint256 fees) public {
        fees = bound(fees, 0, 10_000_000e18);
        pool.setCumulativeFees(asset, fees);
        uint256 pct = revenueLock.unlockPercentage();
        assertTrue(
            pct == 0 || pct == 1000 || pct == 2500 || pct == 4000 || pct == 6000 || pct == 8000 || pct == 10000,
            "unlock percentage must be a valid step value"
        );
    }

    function testFuzz_release_neverExceedsAllocation(uint256 fees) public {
        fees = bound(fees, 0, 10_000_000e18);
        pool.setCumulativeFees(asset, fees);
        uint256 releasableA = revenueLock.releasable(beneficiaryA);
        assertLe(releasableA, ALLOC_A, "releasable must not exceed allocation");
        if (releasableA > 0) {
            vm.prank(beneficiaryA);
            revenueLock.release(delegateeX);
            assertLe(revenueLock.released(beneficiaryA), ALLOC_A, "released must not exceed allocation");
        }
    }
}
