// SPDX-License-Identifier: MIT
// ABOUTME: arp-932 — proves G1's ArmadaToken IS Baal's one shares token. Baal reads ARM vote
// ABOUTME: power by block timestamp (ERC-6372), the loot token is frozen (mint reverts, supply
// ABOUTME: zero forever), ARM's public mint reverts, and Baal's native ragequit reverts for ARM
// ABOUTME: so ShieldedRagequit stays the one exit (lab book decisions 3, 20-21).
//
// ArmadaToken (pragma ^0.8.17) and BaalLootToken (pragma ^0.8.17) compile beside forge-std and
// the vendored Baal core (Baal.sol pragma ^0.8.7) at solc 0.8.17, so this test uses the REAL
// ArmadaToken as Baal's shares token — no mock stands in for it.
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {ArmadaToken} from "../contracts/governance/ArmadaToken.sol";
import {BaalLootToken} from "../contracts/governance/BaalLootToken.sol";

import {GnosisSafe} from "@gnosis.pm/safe-contracts/contracts/GnosisSafe.sol";
import {GnosisSafeProxyFactory} from "@gnosis.pm/safe-contracts/contracts/proxies/GnosisSafeProxyFactory.sol";
import {GnosisSafeProxy} from "@gnosis.pm/safe-contracts/contracts/proxies/GnosisSafeProxy.sol";
import {MultiSend} from "@gnosis.pm/safe-contracts/contracts/libraries/MultiSend.sol";
import {ModuleProxyFactory} from "@gnosis.pm/zodiac/contracts/factory/ModuleProxyFactory.sol";
import {Baal} from "lib/baal/contracts/Baal.sol";

contract OneArmShareTokenTest is Test {
    ArmadaToken public arm;
    BaalLootToken public loot;
    Baal public baal;
    GnosisSafe public safe;
    MultiSend public multisend;

    address public constant HOLDER = address(0xA11CE);
    address public constant TIMELOCK = address(0x7140C4);
    uint256 public constant SUPPLY = 12_000_000 * 1e18;

    function setUp() public {
        // ArmadaToken mints the whole 12M supply to HOLDER in its constructor (the one mint).
        arm = new ArmadaToken(HOLDER, TIMELOCK);
        // The loot token is the frozen BaalLootToken (mint reverts; supply zero forever).
        loot = new BaalLootToken();

        // Clone the Baal template, deploy the Safe, and set the Safe's sole owner to the Baal
        // (threshold 1, Baal enabled as a module) — mirrors scripts/summon-baal-safe.ts.
        Baal baalLogic = new Baal();
        ModuleProxyFactory mpf = new ModuleProxyFactory();
        baal = Baal(mpf.deployModule(address(baalLogic), abi.encodeWithSignature("avatar()"), 0));

        GnosisSafe safeLogic = new GnosisSafe();
        GnosisSafeProxyFactory factory = new GnosisSafeProxyFactory();
        multisend = new MultiSend();
        GnosisSafeProxy proxy = factory.createProxy(address(safeLogic), bytes(""));
        safe = GnosisSafe(payable(address(proxy)));

        address[] memory owners = new address[](1);
        owners[0] = address(baal);
        bytes memory enableBaal = abi.encodeWithSignature("enableModule(address)", address(baal));
        bytes memory entry =
            abi.encodePacked(uint8(0), address(safe), uint256(0), uint256(enableBaal.length), enableBaal);
        bytes memory setupAction = abi.encodeWithSignature("multiSend(bytes)", entry);
        safe.setup(owners, 1, address(multisend), setupAction, address(0), address(0), 0, payable(0));

        // Register ARM as Baal's SHARES token and the frozen BaalLootToken as its loot token.
        bytes memory noOp = abi.encodeWithSignature("multiSend(bytes)", bytes(""));
        bytes memory init = abi.encode(address(loot), address(arm), address(multisend), address(safe), address(0), noOp);
        baal.setUp(init);

        // Only the loot token's ownership moves to the Baal (its mint/burn always revert; only
        // the pause flag is owner-gated). ARM has no ownership — Baal only reads it.
        loot.transferOwnership(address(baal));

        // Governance config: votingPeriod 100s, no grace, no offering, no quorum, sponsorThreshold
        // 0 (so a holder self-sponsors). Set by the avatar (the Safe), per baalOrGovernorOnly.
        bytes memory gov = abi.encode(uint32(100), uint32(0), uint256(0), uint256(0), uint256(0), uint256(0));
        vm.prank(address(safe));
        baal.setGovernanceConfig(gov);
    }

    // ----- c1: Baal's shares token is the real ArmadaToken; its loot is the frozen loot token.
    function test_baalSharesTokenIsArmadaToken() public view {
        assertEq(address(baal.sharesToken()), address(arm), "Baal shares token must be the ArmadaToken");
        assertEq(address(baal.lootToken()), address(loot), "Baal loot token must be the frozen BaalLootToken");
    }

    // ----- c2: ARM measures vote time by block timestamp (ERC-6372), not block number.
    function test_armClockIsTimestamp() public {
        assertEq(arm.clock(), uint48(block.timestamp), "clock() must equal block.timestamp");
        assertEq(arm.CLOCK_MODE(), "mode=timestamp", "CLOCK_MODE() must report timestamp mode");
        vm.warp(block.timestamp + 12345);
        assertEq(arm.clock(), uint48(block.timestamp), "clock() tracks block.timestamp after warp");
    }

    // ----- c3: a holder's past ARM vote power at a timestamp equals the ARM they held then, and
    //           an actual Baal vote by the holder counts that amount.
    function test_baalVoteCountsHolderArmAtTimestamp() public {
        // HOLDER self-delegates, so their ARM becomes vote power checkpointed at this timestamp.
        vm.prank(HOLDER);
        arm.delegate(HOLDER);
        vm.warp(block.timestamp + 10);

        // HOLDER (sponsorThreshold 0) self-sponsors a proposal; votingStarts = now.
        vm.prank(HOLDER);
        uint256 id = baal.submitProposal(bytes(""), 0, 0, "arp-932 vote test");

        // A past-vote lookup at an earlier timestamp equals the ARM the holder held then.
        assertEq(arm.getPastVotes(HOLDER, block.timestamp - 1), SUPPLY, "past votes equal the held ARM");

        // Move forward inside the voting window, then vote. Baal reads getPastVotes at
        // votingStarts and must count the holder's full ARM balance as yes votes.
        vm.warp(block.timestamp + 1);
        vm.prank(HOLDER);
        baal.submitVote(uint32(id), true);

        assertEq(_proposalYesVotes(id), SUPPLY, "Baal must count the holder's ARM as the yes-vote weight");

        // Negative control: an address with no ARM is not a Baal member and cannot vote.
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("!member"));
        baal.submitVote(uint32(id), true);
    }

    /// @dev Reads only the yesVotes field of a Baal proposal. The public getter returns 13
    ///      value-type fields (no dynamic members), so the ABI encoding is 13 consecutive
    ///      32-byte words; yesVotes is field index 7. A raw staticcall plus a single-word read
    ///      avoids the full 13-tuple decoder, which is stack-too-deep without via-IR.
    function _proposalYesVotes(uint256 id) internal view returns (uint256 yesVotes) {
        (bool ok, bytes memory data) = address(baal).staticcall(abi.encodeWithSignature("proposals(uint256)", id));
        require(ok, "proposals() call failed");
        assembly {
            yesVotes := mload(add(data, add(0x20, mul(7, 0x20))))
        }
    }

    // ----- c4: the crowdfund's distribution call (transferAndDelegate, ArmadaCrowdfund.claim
    //           line 626) gives a claimant ARM and timestamp-checkpointed vote power.
    function test_crowdfundDistributionGivesTimestampVotes() public {
        address crowdfund = address(0xC0FFEE);
        address claimant = address(0xC1A1);
        address delegatee = address(0xDE1E);
        uint256 allocation = 1_000 * 1e18;

        // The crowdfund is a whitelisted sender and an authorized delegator (its deploy state).
        address[] memory wl = new address[](2);
        wl[0] = HOLDER;
        wl[1] = crowdfund;
        arm.initWhitelist(wl);
        address[] memory delegators = new address[](1);
        delegators[0] = crowdfund;
        arm.initAuthorizedDelegators(delegators);

        // Fund the crowdfund with ARM (HOLDER is whitelisted, so the transfer is allowed).
        vm.prank(HOLDER);
        arm.transfer(crowdfund, allocation);

        // claim(): the crowdfund credits the claimant and delegates in one call.
        vm.prank(crowdfund);
        arm.transferAndDelegate(claimant, allocation, delegatee);
        assertEq(arm.balanceOf(claimant), allocation, "claimant's ARM balance rises by the allocation");

        vm.warp(block.timestamp + 5);
        assertEq(arm.getPastVotes(delegatee, block.timestamp - 1), allocation, "delegate's past votes equal it");
    }

    // ----- c5: the loot token is frozen — every mint reverts (from the Baal owner and from any
    //           other address), so no Baal proposal can ever create loot and the supply stays 0.
    function test_lootMintAlwaysReverts() public {
        assertEq(loot.totalSupply(), 0, "loot supply starts at zero");

        vm.prank(address(baal)); // the Baal owns the loot token
        vm.expectRevert(bytes("BaalLootToken: loot is frozen"));
        loot.mint(HOLDER, 1);

        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("BaalLootToken: loot is frozen"));
        loot.mint(HOLDER, 1);

        // The mint reverts for every caller, so a Baal proposal whose action calls mint (the
        // Safe calling loot.mint) reverts the same way; loot can never be created.
        assertEq(loot.totalSupply(), 0, "loot supply stays zero");
    }

    // ----- c6: Baal's native ragequit reverts for an ARM holder, so ARM and Safe assets cannot
    //           move through it; ShieldedRagequit stays the one exit.
    function test_baalNativeRagequitRevertsForArm() public {
        vm.prank(HOLDER);
        arm.delegate(HOLDER);

        address[] memory tokens = new address[](1);
        tokens[0] = address(arm);

        vm.prank(HOLDER);
        vm.expectRevert(bytes("ArmadaToken: not authorized burner"));
        baal.ragequit(HOLDER, 1_000 * 1e18, 0, tokens);

        assertEq(arm.balanceOf(HOLDER), SUPPLY, "the holder's ARM is unchanged");
        assertEq(arm.totalSupply(), SUPPLY, "the total ARM supply is unchanged");
    }

    // ----- c9: ARM's public mint reverts for every caller; the supply stays fixed at 12M.
    function test_publicMintReverts() public {
        assertEq(arm.totalSupply(), SUPPLY, "supply is exactly 12,000,000 ARM");

        vm.expectRevert(bytes("ArmadaToken: minting disabled"));
        arm.mint(HOLDER, 1);

        vm.prank(HOLDER);
        vm.expectRevert(bytes("ArmadaToken: minting disabled"));
        arm.mint(HOLDER, 1);

        assertEq(arm.totalSupply(), SUPPLY, "supply never rises");
    }
}
