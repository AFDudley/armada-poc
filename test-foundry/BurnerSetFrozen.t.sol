// ABOUTME: Foundry tests proving the ArmadaToken burner set is frozen at deploy (E5). The
// ABOUTME: deployer registers ShieldedRagequit one-shot via initBurners; addBurner is removed,
// ABOUTME: so no address (the timelock/Safe included) can add a burner after that.
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {ArmadaToken} from "../contracts/governance/ArmadaToken.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title BurnerSetFrozenTest — the ArmadaToken burner set is frozen after the one-shot
///        deployer registration (initBurners). The post-deploy addBurner path is deleted (E5).
/// @dev Proves C1-C4. C5 (a real member ragequit still burns) is proven by the existing
///      test-foundry/ShieldedRagequit.t.sol suite, which this change leaves green.
contract BurnerSetFrozenTest is Test {
    ArmadaToken public arm;
    TimelockController public timelock;
    address public deployer = address(this);
    address public holder = address(0xA9);
    // The registered burner. A fresh address stands in for ShieldedRagequit in these
    // token-only tests; the real ragequit flow is proven in ShieldedRagequit.t.sol.
    address public ragequit = address(0x7E23D);

    // The 4-byte selector of the removed function addBurner(address).
    bytes4 constant ADD_BURNER_SELECTOR = bytes4(keccak256("addBurner(address)"));

    function setUp() public {
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(172800, proposers, executors, deployer);

        // Deploy ARM: the holder receives the whole initial supply (single constructor mint).
        arm = new ArmadaToken(holder, address(timelock));

        // The deployer (this test) runs the one-shot burner registration.
        address[] memory burners = new address[](1);
        burners[0] = ragequit;
        arm.initBurners(burners);
    }

    // C1 · The timelock (the Safe) tries to give burn rights to a new address. The post-deploy
    //      path is removed, so the attempt fails, and the new address still has no burn rights.
    function test_BurnerSetFrozen_TimelockCannotAddBurner() public {
        address newAddr = address(0x9F1);

        // The addBurner function is deleted, so the selector resolves to no function and the
        // call reverts. (On the unfixed contract this call succeeds and grants burn rights.)
        vm.prank(address(timelock));
        (bool ok,) = address(arm).call(abi.encodeWithSelector(ADD_BURNER_SELECTOR, newAddr));
        assertFalse(ok, "C1: the timelock must have no path to add a burner");

        // The timelock also cannot run the one-shot registration (deployer-only, already done).
        address[] memory burners = new address[](1);
        burners[0] = newAddr;
        vm.prank(address(timelock));
        vm.expectRevert("ArmadaToken: not deployer");
        arm.initBurners(burners);

        assertFalse(arm.authorizedBurner(newAddr), "C1: new address has no burn rights");
        assertTrue(arm.authorizedBurner(ragequit), "C1: the registered burner keeps its rights");
    }

    // C2 · After the one-time registration, no caller (the timelock, the deployer, or an
    //      unrelated address) can add a burner, and a second initBurners call fails.
    function test_BurnerSetFrozen_NoCallerCanAddBurner() public {
        address newAddr = address(0x2B2);

        // The deployer's removed addBurner path fails.
        vm.prank(deployer);
        (bool okDeployer,) = address(arm).call(abi.encodeWithSelector(ADD_BURNER_SELECTOR, newAddr));
        assertFalse(okDeployer, "C2: the deployer must have no path to add a burner");

        // An unrelated address's removed addBurner path fails.
        vm.prank(address(0x5E5));
        (bool okOther,) = address(arm).call(abi.encodeWithSelector(ADD_BURNER_SELECTOR, newAddr));
        assertFalse(okOther, "C2: an unrelated address must have no path to add a burner");

        // The deployer's second one-shot registration fails (already initialized).
        address[] memory burners = new address[](1);
        burners[0] = newAddr;
        vm.prank(deployer);
        vm.expectRevert("ArmadaToken: burners already initialized");
        arm.initBurners(burners);

        assertFalse(arm.authorizedBurner(newAddr), "C2: new address has no burn rights");
        assertTrue(arm.authorizedBurner(ragequit), "C2: the registered burner keeps its rights");
    }

    // C3 · The one registered burner (ShieldedRagequit) burns ARM. The call succeeds, and the
    //      holder's balance and the total supply both drop by the burned amount.
    function test_BurnerSetFrozen_ShieldedRagequitCanBurn() public {
        uint256 balBefore = arm.balanceOf(holder);
        uint256 supplyBefore = arm.totalSupply();
        uint256 amount = 1_000;

        vm.prank(ragequit);
        arm.burn(holder, amount);

        assertEq(arm.balanceOf(holder), balBefore - amount, "C3: holder balance drops by amount");
        assertEq(arm.totalSupply(), supplyBefore - amount, "C3: total supply drops by amount");
    }

    // C4 · An address that is not the registered burner (the timelock, the deployer, or a
    //      random address) tries to burn a holder's ARM. Each call reverts with
    //      "ArmadaToken: not authorized burner", and the holder's balance does not change.
    function test_BurnerSetFrozen_NonBurnerBurnReverts() public {
        uint256 balBefore = arm.balanceOf(holder);

        vm.prank(address(timelock));
        vm.expectRevert("ArmadaToken: not authorized burner");
        arm.burn(holder, 1);

        vm.prank(deployer);
        vm.expectRevert("ArmadaToken: not authorized burner");
        arm.burn(holder, 1);

        vm.prank(address(0x5E5));
        vm.expectRevert("ArmadaToken: not authorized burner");
        arm.burn(holder, 1);

        assertEq(arm.balanceOf(holder), balBefore, "C4: holder balance unchanged");
    }
}
