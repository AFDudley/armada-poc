// SPDX-License-Identifier: MIT
// ABOUTME: Foundry test proving the Baal + Safe summon: the Safe is owned solely by
// ABOUTME: the Baal (isOwner(baal) true, getOwners().length == 1), threshold 1, and
// ABOUTME: the ARM shares token is registered on the Baal (sharesToken() == ARM).
// ABOUTME: Mirrors the fixturenet deploy (scripts/summon-baal-safe.ts).
// ABOUTME: See docs/tasks/G2-baal-safe-summon.md.
//
// Uses the vendored Baal core (lib/baal/contracts/Baal.sol, pragma ^0.8.7, compatible
// with this repo's 0.8.17 compiler) and the vendored Gnosis Safe (lib/safe-contracts).
// Baal's own Shares/Loot token implementations (lib/baal/contracts/SharesERC20.sol,
// LootERC20.sol) are pinned to an exact `pragma solidity 0.8.7`, which is incompatible
// with forge-std's `>=0.8.13` requirement in the same compilation unit — so this test
// implements IBaalToken directly in a minimal local token (MockBaalToken) instead of
// importing those two files. The mock is configured with name/symbol "ARM", standing in
// for G1's ArmadaToken (which is not BaalToken-compatible — see docs/tasks/G1-arm-shares-token.md);
// what this test proves is that Baal's registered sharesToken is the deployed ARM token,
// matching scripts/summon-baal-safe.ts's own ARM shares-token wiring.
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "@gnosis.pm/safe-contracts/contracts/GnosisSafe.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/GnosisSafeProxyFactory.sol";
import "@gnosis.pm/safe-contracts/contracts/libraries/MultiSend.sol";
import "@gnosis.pm/zodiac/contracts/factory/ModuleProxyFactory.sol";
import "lib/baal/contracts/Baal.sol";
import "lib/baal/contracts/interfaces/IBaalToken.sol";

/// @notice Minimal BaalToken-compatible token used as the Baal shares/loot token in this
///         test. Implements every function Baal.setUp and Baal's SetupComplete event read
///         (name, symbol, paused) plus the rest of IBaalToken for interface completeness.
contract MockBaalToken is IBaalToken {
    string public override name;
    string public override symbol;
    address public override owner;
    bool public override paused;
    uint256 public override totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => address) public override delegates;
    mapping(address => uint256) public override delegationNonces;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        owner = msg.sender;
    }

    function setUp(string memory, string memory) external override {}

    function mint(address recipient, uint256 amount) external override {
        _balances[recipient] += amount;
        totalSupply += amount;
    }

    function burn(address account, uint256 amount) external override {
        _balances[account] -= amount;
        totalSupply -= amount;
    }

    function pause() external override {
        paused = true;
    }

    function unpause() external override {
        paused = false;
    }

    function transferOwnership(address newOwner) external override {
        owner = newOwner;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function snapshot() external pure override returns (uint256) {
        return 0;
    }

    function getCurrentSnapshotId() external pure override returns (uint256) {
        return 0;
    }

    function balanceOfAt(address account, uint256) external view override returns (uint256) {
        return _balances[account];
    }

    function totalSupplyAt(uint256) external view override returns (uint256) {
        return totalSupply;
    }

    function getPastVotes(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function numCheckpoints(address) external pure override returns (uint256) {
        return 0;
    }

    function getCheckpoint(address, uint256) external pure override returns (Checkpoint memory) {
        return Checkpoint(0, 0);
    }

    function getVotes(address) external pure override returns (uint256) {
        return 0;
    }

    function delegate(address delegatee) external override {
        delegates[msg.sender] = delegatee;
    }

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external override {}
}

contract BaalSafeSummonTest is Test {
    GnosisSafeProxyFactory public factory;
    GnosisSafe public safe;
    Baal public baal;
    address public armAddress;

    function setUp() public {
        // 1. Deploy the Baal logic template, then clone it via zodiac's ModuleProxyFactory
        //    (an EIP-1167 minimal proxy) — Baal's constructor calls _disableInitializers(),
        //    so Baal.setUp() must run against a clone's fresh storage, not the template's.
        //    The clone's deployModule call uses a harmless view-function initializer
        //    (avatar(), reads as address(0) pre-setUp) purely to get the clone's address —
        //    the real setUp() call happens in step 6, once the Safe (avatar) exists. This
        //    mirrors BaalSummoner._summonBaal's own two-step deployModule + setUp order.
        Baal baalLogic = new Baal();
        ModuleProxyFactory moduleProxyFactory = new ModuleProxyFactory();
        address baalClone = moduleProxyFactory.deployModule(address(baalLogic), abi.encodeWithSignature("avatar()"), 0);
        baal = Baal(baalClone);

        // 2. Deploy the ARM shares token (BaalToken-compatible, configured as "ARM").
        MockBaalToken arm = new MockBaalToken("ARM", "ARM");
        armAddress = address(arm);

        // 3. Deploy a minimal loot token (BaalToken-compatible, configured as "LOOT").
        MockBaalToken loot = new MockBaalToken("LOOT", "LOOT");

        // 4. Deploy the Gnosis Safe logic template + factory + multisend library.
        GnosisSafe safeLogic = new GnosisSafe();
        factory = new GnosisSafeProxyFactory();
        MultiSend multisend = new MultiSend();

        // 5. Deploy the Safe proxy with no setup yet (empty data — the proxy exists but
        //    threshold is still 0, not yet initialized; no owner, human or otherwise, exists
        //    at this point). Then call setup directly, now that address(safe) is known,
        //    setting the Safe's sole owner to the Baal clone, threshold 1, and enabling the
        //    Baal as a Safe module in the same call (mirrors BaalSummoner.configureSafe) —
        //    Baal.exec() reaches the Safe via execTransactionFromModule, which requires Baal
        //    to be a registered module, not merely the sole owner.
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

        // 6. Register the ARM as the Baal's shares token, now that the Safe (avatar) exists.
        //    Baal.setUp decodes (loot, shares, multisend, avatar, forwarder, initMultisendData)
        //    then delegatecalls multisendLibrary with initMultisendData — a real (no-op)
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

    /// @notice The Baal's registered shares token is the ARM token address.
    function test_baalSharesTokenIsARM() public view {
        assertEq(address(baal.sharesToken()), armAddress, "Baal shares token must be the ARM");
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
