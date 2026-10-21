// ABOUTME: Foundry tests proving the ArmadaToken burner set is frozen at deploy: only
// ABOUTME: ShieldedRagequit can burn, and no address (the timelock/Safe included) can add a burner.
// ABOUTME: 4 tests matching the spec's acceptance names (c1-c4).
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {ArmadaToken} from "../contracts/governance/ArmadaToken.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title BurnerSetFrozenTest — the ArmadaToken burner set is frozen after the one-shot
/// @dev    deployer registration (initBurners). Proves C1-C4:
///      C1 the timelock cannot add a burner after the one-shot registration.
///      C2 no address (the timelock/Safe, the deployer, or an unrelated address) can add a
///           burner, and a second initBurners reverts.
///      C4 any non-burner call to burn reverts with "ArmadaToken: not authorized burner".
contract BurnerSetFrozenTest is Test {
    ArmadaToken public arm;
    TimelockController public timelock;
    address public deployer = address(this);
    address public holder = address(0xA9);
    address public holder2 = address(0xB9);
    // The registered burner (a fresh address standing in for ShieldedRagequit in these
    // token-only tests; the real ragequit flow is proven in ShieldedRagequit.t.sol).
    address public ragequit = address(0x7E23D);

    uint256 constant TOTAL_SUPPLY = 12_000_000 * 1e18;

    function setUp() public {
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(172800, proposers, executors, deployer);

        // Deploy the ARM token: the holder receives the entire initial supply (single mint).
        arm = new ArmadaToken(holder, address(timelock));
        // Register the burner: the deployer (this test contract) runs the one-shot initBurners.
        address[] memory burners = new address[](1);
        burners[0] = ragequit;
        arm.initBurners(burners);
        // Give holder2 some ARM: the holder (whitelisted) transfers to holder2.
        address[] memory whitelist = new address[](2);
        whitelist[0] = holder;
        whitelist[1] = holder2;
        arm.initWhitelist(whitelist);
        vm.prank(holder);
        arm.transfer(holder2, 200);
    }

    // c1 · After deploy (after the one-shot registration), the timelock (the Safe) tries to
    //      authorize a new burner. The attempt fails (frozen), and the new address still has
    //      no burn rights.
    function test_BurnerSetFrozen_TimelockCannotAddBurner() public {
        address newAddr = address(0x9F1);
        vm.prank(address(timelock));
        try arm.addBurner(newAddr) {
            revert("c1: the timelock must not be able to add a burner after registration");
        } catch (bytes memory data) {
            _assertRevertMessage(data, "ArmadaToken: burner set frozen");
        }
        // The new address still has no burn rights.
        assertEq(arm.authorizedBurner(newAddr), false, "c1: new address has no burn rights");
        assertEq(arm.authorizedBurner(address(ragequit)), true, "c1: the registered burner keeps its rights");
    }

    // c2 · After the one-time registration, no caller (the timelock/Safe, the deployer, or an
    //      unrelated address) can add a burner, and the deployer's second initBurners call fails.
    function test_BurnerSetFrozen_NoCallerCanAddBurner() public {
        address newAddr = address(0x2B2);
        // The deployer calls addBurner (not the timelock) — must revert (not timelock).
        vm.prank(address(this));
        try arm.addBurner(newAddr) {
            revert("c2: the deployer must not be able to add a burner");
        } catch (bytes memory data) {
            _assertRevertMessage(data, "ArmadaToken: not timelock");
        }
        // An unrelated address calls addBurner — must revert (not the timelock).
        vm.prank(address(0x5E5));
        try arm.addBurner(newAddr) {
            revert("c2: an unrelated address must not be able to add a burner");
        } catch (bytes memory data) {
            _assertRevertMessage(data, "ArmadaToken: not timelock");
        }
        // The deployer tries the one-shot registration a second time — must revert (already
        // initialized).
        address[] memory burners = new address[](1);
        burners[0] = newAddr;
        vm.prank(address(this));
        try arm.initBurners(burners) {
            revert("c2: a second initBurners call must fail");
        } catch (bytes memory data) {
            _assertRevertMessage(data, "ArmadaToken: burners already initialized");
        }
        // The new address still has no burn rights (all attempts failed).
        assertEq(arm.authorizedBurner(newAddr), false, "c2: new address has no burn rights");
        assertEq(arm.authorizedBurner(address(ragequit)), true, "c2: the registered burner keeps its rights");
    }

    // c4 · An address that is not the registered burner (the timelock, the deployer, or a
    //      random address) tries to burn a holder's ARM. Each call reverts with
    //      "ArmadaToken: not authorized burner", and the holder's balance does not change.
    function test_BurnerSetFrozen_NonBurnerBurnReverts() public {
        uint256 balBefore = arm.balanceOf(holder);

        // The timelock calls burn — not an authorized burner.
        vm.prank(address(timelock));
        try arm.burn(holder, 1) {
            revert("c4: the timelock must not be able to burn");
        } catch (bytes memory data) {
            _assertRevertMessage(data, "ArmadaToken: not authorized burner");
        }
        // The deployer calls burn — not an authorized burner.
        vm.prank(address(this));
        try arm.burn(holder, 1) {
            revert("c4: the deployer must not be able to burn");
        } catch (bytes memory data) {
            _assertRevertMessage(data, "ArmadaToken: not authorized burner");
        }
        // A random address calls burn — not an authorized burner.
        vm.prank(address(0x5E5));
        try arm.burn(holder, 1) {
            revert("c4: a random address must not be able to burn");
        } catch (bytes memory data) {
            _assertRevertMessage(data, "ArmadaToken: not authorized burner");
        }
        // The holder's balance is unchanged (every non-burner call reverted).
        assertEq(arm.balanceOf(holder), balBefore, "c4: holder balance unchanged");
    }

    /// @dev Decode the revert reason string from the caught revert data.
    function _assertRevertMessage(bytes memory data, string memory expected) internal pure {
        require(data.length > 4, "c: too short");
        // The caught revert data carries a 4-byte selector prefix followed by the
        // ABI-encoded string payload. Skip the prefix, then decode the string.
        string memory reason = abi.decode(_dropBytes(data, 4), (string));
        assertEq(reason, expected, "revert message mismatch");
    }

    function _dropBytes(bytes memory b, uint256 n) private pure returns (bytes memory) {
        require(b.length >= n, "dropBytes: too short");
        bytes memory out = new bytes(b.length - n);
        for (uint256 i; i + n < b.length; i++) {
            out[i] = b[i + n];
        }
        return out;
    }
}
