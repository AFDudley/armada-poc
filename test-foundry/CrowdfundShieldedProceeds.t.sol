// ABOUTME: G5 acceptance test — ArmadaCrowdfund.finalize shields the sale proceeds into the
// ABOUTME: privacy pool as one Safe-owned note, instead of a plain transfer to the treasury.
// ABOUTME: Proves the pool holds exactly one Safe note, the note amount equals the sale proceeds,
// ABOUTME: the treasury USDC balance is unchanged, the unsold-ARM sweep still works, finalize
// ABOUTME: stays nonReentrant, and no USDC allowance to the pool is left open after finalize.

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./helpers/CrowdfundPoolDeploy.sol";
import "../contracts/crowdfund/ArmadaCrowdfund.sol";
import "../contracts/governance/ArmadaToken.sol";
import "../contracts/cctp/MockUSDCV2.sol";
import "../contracts/privacy-pool/PrivacyPool.sol";
import "../contracts/privacy-pool/types/PoolTypes.sol";
import "../contracts/privacy-pool/types/PoseidonLibs.sol";

/// @title MaliciousUSDC
/// @notice Mock USDC with a transfer hook that reenters the target with the given calldata,
///         so a `finalize` reentrant call is observable (proves the nonReentrant guard).
contract MaliciousUSDC is ERC20 {
    address public attackTarget;
    bytes public attackCalldata;
    bool public attackActive;
    bool public attackFired;
    bool public callSucceeded;
    bytes public revertData;

    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _decimals = 6;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setAttack(address target, bytes calldata data) external {
        attackTarget = target;
        attackCalldata = data;
        attackActive = true;
        attackFired = false;
        callSucceeded = false;
        revertData = "";
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount);
        if (attackActive && !attackFired) {
            attackFired = true;
            (bool success, bytes memory ret) = attackTarget.call(attackCalldata);
            callSucceeded = success;
            if (!success) {
                revertData = ret;
            }
        }
    }
}

contract CrowdfundShieldedProceedsTest is Test, CrowdfundPoolDeploy {
    MockUSDCV2 usdc;
    ArmadaToken armToken;
    PrivacyPool pool;
    ArmadaCrowdfund crowdfund;
    address admin;
    address treasury;
    address poolTreasury;

    bytes32 constant SAFE_NPK = bytes32(uint256(0x5AFE00000000000000000000000000000000000000000000000000000));
    uint256 constant ARM_FUNDING = 1_800_000 * 1e18;
    uint256 constant SEED_AMOUNT = 15_000 * 1e6;
    uint256 constant N_SEEDS = 180;

    address[] public seeds;

    function setUp() public {
        admin = address(this);
        treasury = address(0xCAFE);
        poolTreasury = address(0xBEEF);

        usdc = new MockUSDCV2("Mock USDC", "USDC");
        armToken = new ArmadaToken(admin, admin);
        pool = _deployPool(address(usdc), poolTreasury, admin, SAFE_NPK);

        crowdfund = new ArmadaCrowdfund(
            address(usdc),
            address(armToken),
            treasury,
            admin,
            admin,
            block.timestamp,
            address(pool)
        );

        address[] memory wl = new address[](2);
        wl[0] = admin;
        wl[1] = address(crowdfund);
        armToken.initWhitelist(wl);
        armToken.transfer(address(crowdfund), ARM_FUNDING);
        crowdfund.loadArm();

        for (uint256 i = 0; i < N_SEEDS; i++) {
            seeds.push(address(uint160(0xA000 + i)));
        }
        crowdfund.addSeeds(seeds);
    }

    /// @notice Commit the small sale: each of the N_SEEDS seeds commits SEED_AMOUNT USDC at hop-0.
    /// @notice Run the full sale: hop-0 seeds, then launch-team-invited hop-1/hop-2
    ///          committers. The multi-hop commits push totalAllocUsdc above MIN_SALE so
    ///          finalize takes the non-refund path and shields the proceeds.
    function _commitSmallSale() internal {
        // Hop-0: N_SEEDS seeds each commit SEED_AMOUNT.
        for (uint256 i = 0; i < N_SEEDS; i++) {
            usdc.mint(seeds[i], SEED_AMOUNT);
            vm.startPrank(seeds[i]);
            usdc.approve(address(crowdfund), SEED_AMOUNT);
            crowdfund.commit(0, SEED_AMOUNT);
            vm.stopPrank();
        }
        // Hop-1: the launch team (the test contract) invites a few hop-1 committers.
        for (uint256 i = 0; i < 40; i++) {
            address hop1Addr = address(uint160(0xB000 + i));
            crowdfund.launchTeamInvite(hop1Addr, 0);
        }
        for (uint256 i = 0; i < 40; i++) {
            address hop1Addr = address(uint160(0xB000 + i));
            usdc.mint(hop1Addr, SEED_AMOUNT);
            vm.startPrank(hop1Addr);
            usdc.approve(address(crowdfund), SEED_AMOUNT);
            crowdfund.commit(1, SEED_AMOUNT);
            vm.stopPrank();
        }
        // Hop-2: the launch team invites hop-2 committers, then they commit.
        for (uint256 i = 0; i < 40; i++) {
            address hop2Addr = address(uint160(0xC000 + i));
            crowdfund.launchTeamInvite(hop2Addr, 1);
            usdc.mint(hop2Addr, SEED_AMOUNT);
            vm.startPrank(hop2Addr);
            usdc.approve(address(crowdfund), SEED_AMOUNT);
            crowdfund.commit(2, SEED_AMOUNT);
            vm.stopPrank();
        }
    }

    /// @notice Reentrant finalize check: a malicious USDC reenters `finalize` during the shield's
    ///          USDC pull; the nonReentrant guard must reject the reentrant call.
    function _reentrantFinalizeBlocked() internal returns ( bool) {
        MaliciousUSDC maliciousUsdc = new MaliciousUSDC("Bad USDC", "BUSDC");
        ArmadaToken armToken2 = new ArmadaToken(admin, admin);
        PrivacyPool pool2 = _deployPool(address(maliciousUsdc), poolTreasury, admin, SAFE_NPK);
        ArmadaCrowdfund cf2 = new ArmadaCrowdfund(
            address(maliciousUsdc),
            address(armToken2),
            treasury,
            admin,
            admin,
            block.timestamp,
            address(pool2)
        );

        // Whitelist admin + cf2 on the fresh ARM token, then fund it.
        address[] memory wl2 = new address[](2);
        wl2[0] = admin;
        wl2[1] = address(cf2);
        armToken2.initWhitelist(wl2);
        armToken2.transfer(address(cf2), ARM_FUNDING);
        cf2.loadArm();

        // Register the seeds on cf2 so commit() accepts them.
        cf2.addSeeds(seeds);
        for (uint256 i = 0; i < N_SEEDS; i++) {
            maliciousUsdc.mint(seeds[i], SEED_AMOUNT);
            vm.startPrank(seeds[i]);
            maliciousUsdc.approve(address(cf2), SEED_AMOUNT);
            cf2.commit(0, SEED_AMOUNT);
            vm.stopPrank();
        }

        // Commit hop-1 on cf2 (invited by the launch team) so the sale clears MIN_SALE and the
        // shield's USDC pull (and thus the reentrant window) actually occurs.
        for (uint256 i = 0; i < 40; i++) {
            address hop1Addr = address(uint160(0xB000 + i));
            cf2.launchTeamInvite(hop1Addr, 0);
            maliciousUsdc.mint(hop1Addr, SEED_AMOUNT);
            vm.startPrank(hop1Addr);
            maliciousUsdc.approve(address(cf2), SEED_AMOUNT);
            cf2.commit(1, SEED_AMOUNT);
            vm.stopPrank();
        }

        // Arm the attack: during the shield's USDC pull, reenter cf2.finalize().
        maliciousUsdc.setAttack(address(cf2), abi.encodeWithSelector(ArmadaCrowdfund.finalize.selector));
        vm.warp(cf2.windowEnd() + 1);
        // Outer finalize: if it reverts, the try/catch catches it.
        bool outerRevert = false;
        bytes memory outerData;
        try cf2.finalize() {
            // outer finalize succeeded
        } catch (bytes memory odata) {
            outerRevert = true;
            outerData = odata;
            // store the reason for inspection
            _setRevertReason(_extractRevertReason(odata));
        }
        console.log("outerRevert:", outerRevert);
        if (outerRevert) {
            console.log("revert reason:", _extractRevertReason(outerData));
        }
        bool blocked = !maliciousUsdc.callSucceeded();
        bytes memory data = maliciousUsdc.revertData();
        bool reasonMatches = _strEq(_extractRevertReason(data), "ReentrancyGuard: reentrant call");
        return blocked && reasonMatches;
    }

    /// @notice Extract the revert reason from forge's revert data.

    /// @notice Compare two dynamic strings (Solidity forbids `==` on two dynamic strings).
    function _strEq(string memory a_, string memory b_) internal pure returns (bool) {
        return keccak256(bytes(a_)) == keccak256(bytes(b_));
    }

    function _extractRevertReason(bytes memory revertData_) internal pure returns (string memory) {
        if (revertData_.length < 32) {
            return string(revertData_);
        }
        bytes memory payload = new bytes(uint256(revertData_.length - 32));
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = revertData_[32 + i];
        }
        string memory message = abi.decode(payload, (string));
        return message;
    }

    function _setRevertReason(string memory reason) internal {
        // store the last-seen revert reason for inspection
    }



    /// @notice Concatenate two dynamic strings (Solidity forbids `+` on two dynamic strings).
    function _cat(string memory a_, string memory b_) internal pure returns (string memory) {
        bytes memory ba = bytes(a_);
        bytes memory bb = bytes(b_);
        bytes memory res = new bytes(ba.length + bb.length);
        uint256 i;
        for (i = 0; i < ba.length; i++) res[i] = ba[i];
        for (i = 0; i < bb.length; i++) res[ba.length + i] = bb[i];
        return string(res);
    }

    function test_shieldedProceeds() public {
        _commitSmallSale();

        uint256 usdcBalanceBefore = usdc.balanceOf(treasury);
        uint256 armBalanceBefore = armToken.balanceOf(treasury);

        vm.warp(crowdfund.windowEnd() + 1);
        crowdfund.finalize();
        console.log("DEBUG totalAlloc:", crowdfund.totalAllocatedUsdc());
        console.log("DEBUG participantCount:", crowdfund.getParticipantCount());
        console.log("DEBUG refundMode:", crowdfund.refundMode());

        // ── c1: pool holds exactly one Safe-owned note
        uint256 safeNoteCount = pool.nextLeafIndex();

        // ── c1: note amount matches the sale proceeds
        uint256 totalAlloc = crowdfund.totalAllocatedUsdc();
        uint256 roundingBuffer = crowdfund.getParticipantCount();
        uint256 proceedsPush = totalAlloc > roundingBuffer ? totalAlloc - roundingBuffer : 0;
        bytes32 tokenID = bytes32(uint256(uint160(address(usdc))));
        bytes32[3] memory arr = [SAFE_NPK, tokenID, bytes32(uint256(proceedsPush))];
        bytes32 expectedCommitment = PoseidonT4.poseidon(arr);

        (bytes32 noteNpk, TokenData memory noteToken, uint120 noteValue) = pool.preimageOf(expectedCommitment);
        bool amountMatchesProceeds = (uint256(noteValue) == proceedsPush) && (noteNpk == SAFE_NPK);

        // ── c2: treasury USDC delta == 0
        int256 treasuryUsdcDelta = int256(usdc.balanceOf(treasury)) - int256(usdcBalanceBefore);

        // ── c3: unsold-ARM sweep to treasury still works
        crowdfund.withdrawUnallocatedArm();
        bool armSweepOk = armToken.balanceOf(treasury) > armBalanceBefore;

        // ── c3: treasury address unchanged (immutable)
        bool treasuryUnchanged = crowdfund.treasury() == treasury;

        // ── c: reentrant finalize is rejected by the nonReentrant guard
        bool reentrantReverts = _reentrantFinalizeBlocked();

        // ── c4: no USDC allowance left open to the pool after finalize
        uint256 poolAllowanceAfter = usdc.allowance(address(crowdfund), address(pool));

        // Emit the JSON for the reducer. The script merges tests_passed / tests_failed.
        string memory json = "CROWDFUND_SHIELDED_PROCEEDS_JSON {\"safe_note_count\": ";
        json = _cat(json, toString(safeNoteCount));
        json = _cat(json, ",\"safe_note_amount_matches_proceeds\": ");
        json = _cat(json, amountMatchesProceeds ? "true" : "false");
        json = _cat(json, ",\"treasury_usdc_delta\": ");
        json = _cat(json, toString(uint256(treasuryUsdcDelta) == 0 ? 0 : 1));
        json = _cat(json, ",\"treasury_receives_unsold_arm_sweep\": ");
        json = _cat(json, armSweepOk ? "true" : "false");
        json = _cat(json, ",\"treasury_address_unchanged\": ");
        json = _cat(json, treasuryUnchanged ? "true" : "false");
        json = _cat(json, ",\"reentrant_finalize_reverts\": ");
        json = _cat(json, reentrantReverts ? "true" : "false");
        json = _cat(json, ",\"pool_allowance_after_finalize\": ");
        json = _cat(json, toString(poolAllowanceAfter));
        json = _cat(json, "}");
        console.log(json);

        assertEq(safeNoteCount, 1, "pool holds exactly one Safe note");
        assertTrue(amountMatchesProceeds, "note amount matches sale proceeds");
        assertEq(treasuryUsdcDelta, 0, "treasury USDC balance unchanged by finalize");
        assertTrue(armSweepOk, "unsold-ARM sweep to treasury");
        assertTrue(treasuryUnchanged, "treasury address immutable");
        assertTrue(reentrantReverts, "reentrant finalize rejected");
        assertEq(poolAllowanceAfter, 0, "no open USDC allowance to pool");
    }

    /// @notice Debug: print the sale/finalize values (passing test so output shows).
    function test_debug() public {
        _commitSmallSale();
        vm.warp(crowdfund.windowEnd() + 1);
        crowdfund.finalize();
        uint256 totalAlloc = crowdfund.totalAllocatedUsdc();
        bool refund = crowdfund.refundMode();
        uint256 pcount = crowdfund.getParticipantCount();
        uint256 proceeds = (totalAlloc > pcount) ? totalAlloc - pcount : 0;
        uint256 noteCount = pool.nextLeafIndex();
        assertEq(totalAlloc, 0, "totalAlloc");
        assertEq((refund ? 1 : 0), 0, "refundMode");
        assertEq(noteCount, 1, "noteCount");
        assertEq((refund ? 1 : 0), 0, "refund actual is shown");
        assertEq(proceeds, 0, "proceedsPush actual is shown");
        assertEq(usdc.balanceOf(treasury), 0, "treasuryUsdc actual is shown");
    }
    /// @notice Forge built-in: format a uint256 as a string.
    function toString(uint256 value) internal pure returns (string memory) {
        return vm.toString(value);
    }
}
