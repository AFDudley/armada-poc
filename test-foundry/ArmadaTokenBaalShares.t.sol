// SPDX-License-Identifier: MIT
// ABOUTME: Foundry tests for arp-932: G1's ArmadaToken is Baal's registered shares
// ABOUTME: token (timestamp-based voting), the Baal loot token stays zero forever, and
// ABOUTME: ShieldedRagequit is the one exit that burns ARM and pays a note.
// ABOUTME: Mirrors scripts/summon-baal-safe.ts (summon pattern) and ShieldedRagequit's
// ABOUTME: pool setup.

pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {ArmadaToken} from "../contracts/governance/ArmadaToken.sol";
import {BaalSharesToken} from "../contracts/governance/BaalSharesToken.sol";
import {ShieldedRagequit} from "../contracts/governance/ShieldedRagequit.sol";
import {ArmadaCrowdfund} from "../contracts/crowdfund/ArmadaCrowdfund.sol";
import {PrivacyPool} from "../contracts/privacy-pool/PrivacyPool.sol";
import {MockUSDCV2} from "../contracts/cctp/MockUSDCV2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {GnosisSafe} from "@gnosis.pm/safe-contracts/contracts/GnosisSafe.sol";
import {GnosisSafeProxyFactory} from "@gnosis.pm/safe-contracts/contracts/proxies/GnosisSafeProxyFactory.sol";
import {GnosisSafeProxy} from "@gnosis.pm/safe-contracts/contracts/proxies/GnosisSafeProxy.sol";
import {MultiSend} from "@gnosis.pm/safe-contracts/contracts/libraries/MultiSend.sol";
import {ModuleProxyFactory} from "@gnosis.pm/zodiac/contracts/factory/ModuleProxyFactory.sol";
import {Baal} from "lib/baal/contracts/Baal.sol";

import {CrowdfundPoolDeploy} from "./helpers/CrowdfundPoolDeploy.sol";

contract ArmadaTokenBaalSharesTest is Test, CrowdfundPoolDeploy {
    ArmadaToken public arm;
    TimelockController public timelock;
    Baal public baal;
    GnosisSafe public safe;
    MultiSend public multisend;
    PrivacyPool public pool;
    ShieldedRagequit public ragequit;
    MockUSDCV2 public usdc;
    ArmadaCrowdfund public crowdfund;

    address public holder = address(0xA9);
    address public admin = address(this);
    address public treasury = address(0x43);

    uint256 constant ARM_FUNDING = 1_800_000 * 1e18;

    function setUp() public {
        // G1: ArmadaToken with the holder as initial holder (receives the whole supply).
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(172800, proposers, executors, treasury);
        arm = new ArmadaToken(holder, address(timelock));

        // G2: summon Baal + Safe (zodiac clone of the Baal logic, registered with the Safe).
        Baal baalLogic = new Baal();
        ModuleProxyFactory mpf = new ModuleProxyFactory();
        address baalClone = mpf.deployModule(address(baalLogic), abi.encodeWithSignature("avatar()"), 0);
        baal = Baal(baalClone);

        BaalSharesToken loot = new BaalSharesToken("LOOT", "LOOT");

        GnosisSafe safeLogic = new GnosisSafe();
        GnosisSafeProxyFactory safeFactory = new GnosisSafeProxyFactory();
        GnosisSafeProxy safeProxy = safeFactory.createProxy(address(safeLogic), bytes(""));
        safe = GnosisSafe(payable(safeProxy));
        multisend = new MultiSend();

        // The Safe's sole owner is the Baal (threshold 1); the multisend action enables Baal as module.
        address[] memory owners = new address[](1);
        owners[0] = address(baal);
        bytes memory enableModule = abi.encodeWithSignature("enableModule(address)", address(baal));
        bytes memory multisendAction = abi.encodeWithSignature(
            "multiSend(bytes)",
            abi.encodePacked(uint8(0), address(safe), 0, uint256(enableModule.length), enableModule)
        );
        safe.setup(owners, 1, address(multisend), multisendAction, address(0), address(0), 0, payable(0));

        // Baal.setUp: register ArmadaToken as shares, LOOT as loot, the Safe as avatar.
        bytes memory noOp = abi.encodeWithSignature("multiSend(bytes)", bytes(""));
        bytes memory baalInit = abi.encode(
            address(loot), address(arm), address(multisend), address(safe), address(0), noOp
        );
        baal.setUp(baalInit);

        // G3: ShieldedRagequit + pool.
        usdc = new MockUSDCV2("Mock USDC", "USDC");
        pool = _deployPool(address(usdc), treasury, address(this), bytes32(0));
        ragequit = new ShieldedRagequit(address(arm), address(baal), address(safe), address(pool));

        // G4: ArmadaCrowdfund.
        address[] memory wl = new address[](2);
        wl[0] = admin;
        wl[1] = address(crowdfund);
        arm.initWhitelist(wl);
        address[] memory delegators = new address[](1);
        delegators[0] = address(crowdfund);
        arm.initAuthorizedDelegators(delegators);
        crowdfund = new ArmadaCrowdfund(
            address(usdc), address(arm), treasury, admin, admin, block.timestamp, address(pool)
        );
        arm.transfer(address(crowdfund), ARM_FUNDING);
        crowdfund.loadArm();
    }
}
