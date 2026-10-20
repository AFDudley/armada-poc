// SPDX-License-Identifier: MIT
// ABOUTME: Foundry test proving the Baal + Safe summon: the Safe is owned solely by
// ABOUTME: the Baal (isOwner(baal) true, getOwners().length == 1), threshold 1, and
// ABOUTME: the registered shares token is G1's ArmadaToken (sharesToken() == ARM).
// ABOUTME: Mirrors the fixturenet deploy (scripts/summon-baal-safe.ts).
// ABOUTME: See docs/tasks/G2-baal-safe-summon.md.
//
// ArmadaToken (pragma ^0.8.17) and BaalLootToken (pragma ^0.8.17) compile beside forge-std
// and the vendored Baal core (lib/baal/contracts/Baal.sol, pragma ^0.8.7) at solc 0.8.17, so
// this test registers the REAL ArmadaToken as Baal's shares token (arp-932: there is one ARM
// token and it IS the Baal shares token) and the frozen BaalLootToken as its loot token.
// Baal's own Shares/Loot implementations (SharesERC20.sol, LootERC20.sol) pin an exact
// `pragma solidity 0.8.7`, incompatible with forge-std's `>=0.8.13` in the same compilation
// unit, so they are not imported here.
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "@gnosis.pm/safe-contracts/contracts/GnosisSafe.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/GnosisSafeProxyFactory.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/GnosisSafeProxy.sol";
import "@gnosis.pm/safe-contracts/contracts/libraries/MultiSend.sol";
import "@gnosis.pm/zodiac/contracts/factory/ModuleProxyFactory.sol";
import "lib/baal/contracts/Baal.sol";
import {ArmadaToken} from "../contracts/governance/ArmadaToken.sol";
import {BaalLootToken} from "../contracts/governance/BaalLootToken.sol";

contract BaalSafeSummonTest is Test {
    GnosisSafeProxyFactory public factory;
    GnosisSafe public safe;
    Baal public baal;
    address public armAddress;

    address public constant HOLDER = address(0xA11CE);
    address public constant TIMELOCK = address(0x7140C4);

    function setUp() public {
        // 1. Deploy the Baal logic template, then clone it via zodiac's ModuleProxyFactory
        //    (an EIP-1167 minimal proxy) — Baal's constructor calls _disableInitializers(),
        //    so Baal.setUp() must run against a clone's fresh storage, not the template's.
        Baal baalLogic = new Baal();
        ModuleProxyFactory moduleProxyFactory = new ModuleProxyFactory();
        address baalClone = moduleProxyFactory.deployModule(address(baalLogic), abi.encodeWithSignature("avatar()"), 0);
        baal = Baal(baalClone);

        // 2. Deploy G1's real ArmadaToken (the shares token) and the frozen BaalLootToken.
        ArmadaToken arm = new ArmadaToken(HOLDER, TIMELOCK);
        armAddress = address(arm);
        BaalLootToken loot = new BaalLootToken();

        // 3. Deploy the Gnosis Safe logic template + factory + multisend library.
        GnosisSafe safeLogic = new GnosisSafe();
        factory = new GnosisSafeProxyFactory();
        MultiSend multisend = new MultiSend();

        // 4. Deploy the Safe proxy with no setup yet (empty data — the proxy exists but
        //    threshold is still 0; no owner, human or otherwise, exists at this point). Then
        //    call setup directly, setting the Safe's sole owner to the Baal clone, threshold 1,
        //    and enabling the Baal as a Safe module in the same call (mirrors
        //    BaalSummoner.configureSafe) — Baal.exec() reaches the Safe via
        //    execTransactionFromModule, which requires Baal to be a registered module.
        GnosisSafeProxy safeProxy = factory.createProxy(address(safeLogic), bytes(""));
        safe = GnosisSafe(payable(address(safeProxy)));

        address[] memory owners = new address[](1);
        owners[0] = address(baal);
        bytes memory enableBaalModule = abi.encodeWithSignature("enableModule(address)", address(baal));
        // Packed multisend entry: operation(0=call) ++ to ++ value ++ dataLength ++ data.
        bytes memory enableBaalMultisendEntry =
            abi.encodePacked(uint8(0), address(safe), uint256(0), uint256(enableBaalModule.length), enableBaalModule);
        bytes memory multisendAction = abi.encodeWithSignature("multiSend(bytes)", enableBaalMultisendEntry);
        safe.setup(
            owners,
            1, // threshold = 1
            address(multisend), // to (multisend library, delegatecalled by setupModules)
            multisendAction, // data (enableModule(baal), self-targeted via multisend)
            address(0), // fallbackHandler
            address(0), // paymentToken
            0, // payment
            payable(0) // paymentReceiver
        );

        // 5. Register the real ArmadaToken as the Baal's shares token and the frozen
        //    BaalLootToken as its loot token, now that the Safe (avatar) exists. Baal.setUp
        //    decodes (loot, shares, multisend, avatar, forwarder, initMultisendData) then
        //    delegatecalls multisendLibrary with initMultisendData — a real (no-op)
        //    multiSend(bytes("")) call, not raw empty bytes (which would hit MultiSend's
        //    nonexistent fallback and revert "call failure setup").
        bytes memory noOpMultisend = abi.encodeWithSignature("multiSend(bytes)", bytes(""));
        bytes memory baalInitParams =
            abi.encode(address(loot), armAddress, address(multisend), address(safe), address(0), noOpMultisend);
        baal.setUp(baalInitParams);
    }

    /// @notice The Safe's sole owner is the Baal (getOwners().length == 1, isOwner(baal) true).
    function test_safeOwnedSolelyByBaal() public view {
        assertEq(safe.getOwners().length, 1, "Safe must have exactly one owner (the Baal)");
        assertTrue(safe.isOwner(address(baal)), "Baal is the Safe's sole owner");
    }

    /// @notice The Safe's threshold is 1 (one owner, one signature executes).
    function test_safeThresholdOne() public view {
        assertEq(safe.getThreshold(), 1, "Safe threshold must be 1");
    }

    /// @notice The Baal's registered shares token is G1's ArmadaToken (arp-932: one ARM token).
    function test_baalSharesTokenIsARM() public view {
        assertEq(address(baal.sharesToken()), armAddress, "Baal shares token must be G1's ArmadaToken");
    }

    /// @notice No human owner exists: the Safe's only owner is the Baal contract, which is
    ///         deployed code (not an EOA) — confirming the Baal is a contract, not a human key.
    function test_noHumanOwner() public view {
        address[] memory owners = safe.getOwners();
        for (uint256 i = 0; i < owners.length; i++) {
            assertGt(owners[i].code.length, 0, "every Safe owner must be contract code, not a human EOA");
        }
    }
}
