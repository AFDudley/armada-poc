// ABOUTME: Foundry tests for G3 shielded ragequit — the Baal manager-shaman exit path.
// ABOUTME: 9 tests matching the spec's acceptance names (c1-c9). The c10 exit-proof check is a
// ABOUTME: separate metamorphic script (bash scripts/verify-ragequit-exit-proof.sh).
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {PrivacyPool} from "../contracts/privacy-pool/PrivacyPool.sol";
import {ShieldModule} from "../contracts/privacy-pool/modules/ShieldModule.sol";
import {TransactModule} from "../contracts/privacy-pool/modules/TransactModule.sol";
import {MerkleModule} from "../contracts/privacy-pool/modules/MerkleModule.sol";
import {VerifierModule} from "../contracts/privacy-pool/modules/VerifierModule.sol";
import {CommitmentPreimage, TokenData, TokenType, UnshieldType, ShieldCiphertext, ShieldRequest} from "../contracts/privacy-pool/types/PoolTypes.sol";
import {PoseidonT4} from "../contracts/privacy-pool/types/PoseidonLibs.sol";
import {MockUSDCV2} from "../contracts/cctp/MockUSDCV2.sol";
import {MockTokenMessengerV2, MockMessageTransmitterV2} from "../contracts/cctp/MockCCTPV2.sol";
import {ArmadaToken} from "../contracts/governance/ArmadaToken.sol";
import {ShieldedRagequit} from "../contracts/governance/ShieldedRagequit.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {GnosisSafe} from "@gnosis.pm/safe-contracts/contracts/GnosisSafe.sol";
import {GnosisSafeProxyFactory} from "@gnosis.pm/safe-contracts/contracts/proxies/GnosisSafeProxyFactory.sol";
import {GnosisSafeProxy} from "@gnosis.pm/safe-contracts/contracts/proxies/GnosisSafeProxy.sol";
import {MultiSend} from "@gnosis.pm/safe-contracts/contracts/libraries/MultiSend.sol";
import {ModuleProxyFactory} from "@gnosis.pm/zodiac/contracts/factory/ModuleProxyFactory.sol";
import {Baal} from "lib/baal/contracts/Baal.sol";
import {IBaalToken} from "lib/baal/contracts/interfaces/IBaalToken.sol";
import {PoseidonLinker} from "./helpers/PoseidonLinker.sol";

/// @title ShieldedRagequitTest — G3 Baal manager-shaman exit (9 spec tests c1-c9).
/// @dev The pool runs in testingMode (SNARK proof bypassed); the exit path (transactOwned) is
///      exercised for real: authorization (ownerField), bounded payout, preimageOf registry.
contract ShieldedRagequitTest is Test, PoseidonLinker {
    // ── Pool fixture (P2a) ──
    PrivacyPool public pool;
    ShieldModule public shieldModule;
    TransactModule public transactModule;
    MerkleModule public merkleModule;
    VerifierModule public verifierModule;
    MockUSDCV2 public usdc;
    MockTokenMessengerV2 public tokenMessenger;
    MockMessageTransmitterV2 public messageTransmitter;
    address public poolOwner;
    address public poolTreasury;

    // ── Governance fixture (G1 ARM + G2 Baal/Safe + G3) ──
    ArmadaToken public arm;
    TimelockController public timelock;
    Baal public public_baal;
    GnosisSafe public safe;
    ShieldedRagequit public ragequit;

    address public holder = address(0xA9);
    address public holder2 = address(0xB9);
    address public nonHolder = address(0x5E5);

    // Mirror of ShieldedRagequit's RagequitExecuted for expectEmit (c9).
    event RagequitExecuted(address indexed holder, uint256 armBurned, bytes32 npk, address[] tokens, uint256[] payouts);

    function setUp() public {
        _linkRealPoseidon();
        poolOwner = address(this);
        poolTreasury = address(0x43);

        // ── Pool ──
        usdc = new MockUSDCV2("Mock USDC", "USDC");
        messageTransmitter = new MockMessageTransmitterV2(0, poolOwner);
        tokenMessenger = new MockTokenMessengerV2(address(messageTransmitter), address(usdc), 0);
        messageTransmitter.setTokenMessenger(address(tokenMessenger));

        shieldModule = new ShieldModule();
        transactModule = new TransactModule();
        merkleModule = new MerkleModule();
        verifierModule = new VerifierModule();

        pool = new PrivacyPool();
        pool.initialize(
            address(shieldModule),
            address(transactModule),
            address(merkleModule),
            address(verifierModule),
            address(tokenMessenger),
            address(messageTransmitter),
            address(usdc),
            0,
            poolOwner,
            payable(poolTreasury)
        );
        pool.setTestingMode(true);

        // ── G1 ARM token: the holder receives the entire initial supply (single mint). ──
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(172800, proposers, executors, address(0x43));
        arm = new ArmadaToken(holder, address(timelock));

        // Whitelist the two holders so the holder (0xA9) can transfer ARM to holder2 (0xB9)
        // while transfers are still restricted (transferable=false, only whitelisted senders).
        address[] memory whitelist = new address[](2);
        whitelist[0] = holder;
        whitelist[1] = holder2;
        arm.initWhitelist(whitelist);

        // ── G2 Baal + Safe (summon pattern) ──
        Baal baalLogic = new Baal();
        ModuleProxyFactory moduleProxyFactory = new ModuleProxyFactory();
        address baalClone = moduleProxyFactory.deployModule(address(baalLogic), abi.encodeWithSignature("avatar()"), 0);
        public_baal = Baal(baalClone);
        MockBaalToken armBaalToken = new MockBaalToken("ARM", "ARM");

        GnosisSafe safeLogic = new GnosisSafe();
        GnosisSafeProxyFactory safeFactory = new GnosisSafeProxyFactory();
        MultiSend multisend = new MultiSend();
        GnosisSafeProxy safeProxy = safeFactory.createProxy(address(safeLogic), bytes(""));
        safe = GnosisSafe(payable(safeProxy));

        address[] memory owners = new address[](1);
        owners[0] = address(public_baal);
        bytes memory enableBaalModule = abi.encodeWithSignature("enableModule(address)", address(public_baal));
        bytes memory multisendAction = abi.encodeWithSignature(
            "multiSend(bytes)",
            abi.encodePacked(uint8(0), address(safe), uint256(0), uint256(enableBaalModule.length), enableBaalModule)
        );
        safe.setup(owners, 1, address(multisend), multisendAction, address(0), address(0), 0, payable(0));

        bytes memory noOpMultisend = abi.encodeWithSignature("multiSend(bytes)", bytes(""));
        bytes memory baalInit = abi.encode(
            address(armBaalToken), address(armBaalToken), address(multisend), address(safe), address(0), noOpMultisend
        );
        public_baal.setUp(baalInit);

        // G3: the manager shaman contract (the constructor takes ARM, Baal, Safe, pool).
        ragequit = new ShieldedRagequit(address(arm), address(public_baal), address(safe), address(pool));

        // c7: register the burner (deployer = the test contract, one-shot initBurners).
        address[] memory burners = new address[](1);
        burners[0] = address(ragequit);
        arm.initBurners(burners);

        // Give holder2 some ARM: the holder (whitelisted) transfers to holder2.
        vm.prank(holder);
        arm.transfer(holder2, 200);
    }

    // ─────────────────────────────────────────────────────────────────────
    // c1 · The exit burns the caller's ARM; the caller's ARM balance and totalSupply
    //      drop by armAmount.
    function test_RagequitBurnsCallerArm() public {
        uint256 armAmt = 100;
        uint256 balBefore = arm.balanceOf(holder);
        uint256 supplyBefore = arm.totalSupply();

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)));

        assertEq(arm.balanceOf(holder), balBefore - armAmt, "c1: caller ARM balance must drop by armAmount");
        assertEq(arm.totalSupply(), supplyBefore - armAmt, "c1: totalSupply must drop by armAmount");
    }

    // c2 · The exit creates a contract-owned note at the caller's npk with the bounded payout,
    //      debited from the Safe's pool-owned note (owner-derived npk).
    function test_RagequitCreatesOwnedNoteAtCallerNpk() public {
        usdc.mint(address(safe), 1000);
        uint256 armAmt = 100;
        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)));

        // The preimage registry now holds the output note's preimage (the caller's note at npk).
        bytes32 commitment =
            _commitment(_npk(holder), address(usdc), armAmt, usdc.balanceOf(address(safe)), arm.totalSupply());
        (bytes32 npk, TokenData memory tokenData, uint256 value) = pool.preimageOf(commitment);
        assertEq(npk, _npk(holder), "c2: the note must be at the caller's npk");
        assertEq(uint8(tokenData.tokenType), uint8(TokenType.ERC20), "c2: payout is denominated in the treasury token");
        assertEq(tokenData.tokenAddress, address(usdc), "c2: payout token is the treasury USDC");
        assertEq(
            value, armAmt * usdc.balanceOf(address(safe)) / arm.totalSupply(), "c2: payout equals the bounded share"
        );
    }

    // c3 · The exit succeeds with a single direct call — no Safe signature, no Baal proposal.
    function test_RagequitNeedsNoSafeSignatureOrProposal() public {
        usdc.mint(address(safe), 1000);
        uint256 supplyBefore = arm.totalSupply();
        uint256 armAmt = 100;

        // A single call from the holder succeeds: no Safe multisig, no Baal proposal needed.
        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)));

        // Proof the exit needed no Safe signature or Baal proposal: the holder's own call
        // burned ARM (totalSupply dropped) and the exit path ran through transactOwned.
        assertEq(
            arm.totalSupply(),
            supplyBefore - armAmt,
            "c3: the holder's own call burned ARM without a Safe signature or Baal proposal"
        );
    }

    // c4 · A crafted call claiming more than the bound reverts; the treasury keeps its funds.
    function test_RagequitRevertsWhenClaimExceedsBound() public {
        usdc.mint(address(safe), 1000);
        uint256 armAmt = 100;
        uint256 safeBal = usdc.balanceOf(address(safe));
        uint256 supply = arm.totalSupply();
        uint256 bound = armAmt * safeBal / supply;

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)));

        // The exit pays out exactly the bound — never more.
        (,, uint256 value) = pool.preimageOf(_commitment(_npk(holder), address(usdc), armAmt, safeBal, supply));
        assertEq(value, bound, "c4: payout equals the bounded share");
        assertLe(value, safeBal, "c4: the treasury keeps its funds (payout <= Safe balance)");
    }

    // c5 · A caller with no ARM reverts; no note created; Safe balance + totalSupply unchanged.
    function test_RagequitRevertsForNonHolder() public {
        usdc.mint(address(safe), 1000);
        uint256 balBefore = arm.balanceOf(nonHolder);
        uint256 supplyBefore = arm.totalSupply();
        uint256 safeBalBefore = usdc.balanceOf(address(safe));

        // The non-holder's call must revert (burnFrom: insufficient balance).
        vm.prank(nonHolder);
        try ragequit.ragequit(100, _npk(nonHolder), _tokenList(address(usdc))) {
            revert("c5: ragequit should have reverted for non-holder");
        } catch {
            // expected revert
    }

        assertEq(arm.balanceOf(nonHolder), balBefore, "c5: non-holder keeps 0 ARM balance");
        assertEq(arm.totalSupply(), supplyBefore, "c5: totalSupply unchanged");
        assertEq(usdc.balanceOf(address(safe)), safeBalBefore, "c5: Safe balance unchanged");
    }

    // c6 · Baal's shaman list holds exactly one entry: ShieldedRagequit (manager, permission 2).
    function test_BaalShamanListIsOnlyShieldedRagequit() public {
        address[] memory shamanList = new address[](1);
        uint256[] memory perms = new uint256[](1);
        shamanList[0] = address(ragequit);
        perms[0] = 2;
        // setShamans is baalOnly (the avatar = Safe calls it).
        vm.prank(address(safe));
        public_baal.setShamans(shamanList, perms);
        vm.prank(address(safe));
        public_baal.lockManager();

        assertEq(public_baal.shamans(address(ragequit)), 2, "c6: ShieldedRagequit is the sole manager shaman");
        assertEq(public_baal.shamans(address(holder)), 0, "c6: holder is not a shaman");
        assertEq(public_baal.shamans(address(arm)), 0, "c6: ARM token is not a shaman");
        assertEq(public_baal.shamans(address(safe)), 0, "c6: Safe is not a shaman");
    }

    // c7 · The burn on ArmadaToken is only callable by ShieldedRagequit; other callers revert.
    function test_BurnOnlyCallableByShieldedRagequit() public {
        address stranger = address(0x7E23D);
        // A non-shaman caller of burn must revert (not authorized burner).
        vm.prank(stranger);
        try arm.burn(stranger, 1) {
            revert("c7: burn should have reverted for non-shaman");
        } catch {
            // expected revert
    }
        assertEq(arm.authorizedBurner(address(ragequit)), true, "c7: ShieldedRagequit is the authorized burner");
    }

    // c8 · Two holders exit the same token in the same block; total paid <= Safe balance.
    function test_TwoRagequitsSameBlockStayWithinBound() public {
        _shieldUsdcNote(1000);
        uint256 supplyBefore = arm.totalSupply();
        uint256 aAmt = 100; // ~10% of supply (holder)
        uint256 bAmt = 200; // ~20% of supply (holder2)
        uint256 noteValueBefore = pool.ownedNoteValue(_npk(address(safe)), address(usdc));

        // Both holders exit the same token (USDC) in the same block.
        uint256 holderBalBefore = arm.balanceOf(holder);
        uint256 holder2BalBefore = arm.balanceOf(holder2);

        vm.prank(holder);
        ragequit.ragequit(aAmt, _npk(holder), _tokenList(address(usdc)));
        uint256 noteValueAfterFirst = pool.ownedNoteValue(_npk(address(safe)), address(usdc));

        vm.prank(holder2);
        ragequit.ragequit(bAmt, _npk(holder2), _tokenList(address(usdc)));

        // The bound holds: total paid = aAmt*V/(S0-aAmt) + bAmt*(V-aPayout)/(S0-aAmt-bAmt)
        // must be <= the Safe's held balance.
        uint256 payoutA = aAmt * noteValueBefore / (supplyBefore - aAmt);
        uint256 payoutB = bAmt * noteValueAfterFirst / (supplyBefore - aAmt - bAmt);
        uint256 totalPaid = payoutA + payoutB;
        assertLe(totalPaid, noteValueBefore, "c8: total paid must not exceed the Safe's held balance");
        // holder burned aAmt; holder2 also burned bAmt (the exit succeeds on the same
        // shared note, debited by the remainder note).
        assertEq(arm.balanceOf(holder), holderBalBefore - aAmt, "c8: holder balance drops by exactly the burn amount");
        assertEq(arm.balanceOf(holder2), holder2BalBefore - bAmt, "c8: holder2 balance drops by exactly the burn amount");
        }


    // ── arp-caf · The payout base is the value of the Safe-owned pool note, not the
    // Safe's public ERC-20 balance. Shielded-treasury exits, bounded payout, and the
    // remainder note are exercised for real against the pool's owned-note view.
    function test_RagequitPayoutBaseIsSafeOwnedNoteValue() public {
        _shieldUsdcNote(1000);
        uint256 armAmt = 1200000000000000000; // 1.2e20
        uint256 noteValue = pool.ownedNoteValue(_npk(address(safe)), address(usdc));
        uint256 supplyBefore = arm.totalSupply();

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)));

        // c1: the payout the holder receives equals burned ARM times the pool-held note
        // value, divided by the total ARM supply (read after the burn).
        uint256 payout = armAmt * noteValue / (supplyBefore - armAmt);
        (, , uint256 value) = pool.preimageOf(_commitment(_npk(holder), address(usdc), armAmt, noteValue, supplyBefore - armAmt));
        assertEq(value, payout, "c1: payout equals burned ARM * note value / total supply");
        assertLe(value, noteValue, "c1: payout must not exceed the held note value");
    }

    function test_RagequitPaysNonzeroFromFullyShieldedTreasury() public {
        _shieldUsdcNote(1000);
        // c2: the treasury holds USDC only inside the pool; the Safe's public balance is
        // zero, yet the exit still pays a nonzero pro-rata amount for that token.
        assertEq(usdc.balanceOf(address(safe)), 0, "c2: the Safe holds no public USDC (fully shielded)");
        uint256 armAmt = 1200000000000000000;
        uint256 noteValue = pool.ownedNoteValue(_npk(address(safe)), address(usdc));
        uint256 supplyBefore = arm.totalSupply();

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)));

        (, , uint256 value) = pool.preimageOf(_commitment(_npk(holder), address(usdc), armAmt, noteValue, supplyBefore - armAmt));
        assertGt(value, 0, "c2: a fully shielded treasury pays a nonzero pro-rata amount");
        assertLe(value, noteValue, "c2: payout is bounded by the held note value");
    }

    function test_RagequitPayoutIgnoresRawTransferToSafe() public {
        _shieldUsdcNote(1000);
        uint256 armAmt = 1200000000000000000;
        uint256 noteValue = pool.ownedNoteValue(_npk(address(safe)), address(usdc));
        uint256 supplyBefore = arm.totalSupply();
        uint256 expectedPayout = armAmt * noteValue / (supplyBefore - armAmt);

        // c3: a raw ERC-20 transfer straight to the Safe (outside the pool) must not
        // change the computed payout.
        usdc.mint(address(safe), 500);

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)));

        (, , uint256 value) = pool.preimageOf(_commitment(_npk(holder), address(usdc), armAmt, noteValue, supplyBefore - armAmt));
        assertEq(value, expectedPayout, "c3: a raw transfer to the Safe does not change the payout");
    }

    function test_RagequitDebitsSafeOwnedNoteByPayout() public {
        _shieldUsdcNote(1000);
        uint256 armAmt = 1200000000000000000;
        uint256 noteValueBefore = pool.ownedNoteValue(_npk(address(safe)), address(usdc));
        uint256 supplyBefore = arm.totalSupply();
        uint256 payout = armAmt * noteValueBefore / (supplyBefore - armAmt);

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)));

        // c4: the Safe-owned note's held value after the exit equals the value before
        // minus exactly the payout the exiting member received (the remainder note).
        uint256 noteValueAfter = pool.ownedNoteValue(_npk(address(safe)), address(usdc));
        assertEq(noteValueAfter, noteValueBefore - payout, "c4: the held value falls by exactly the payout");
        assertLe(noteValueAfter, noteValueBefore, "c4: the held value cannot grow on the exit");
    }

    // c9 · Every holdings change (the exit) emits RagequitExecuted with the correct fields.
    function test_RagequitEmitsRagequitExecuted() public {
        usdc.mint(address(safe), 100);
        uint256 armAmt = 100;
        address[] memory tokens = _tokenList(address(usdc));
        // The event's payout must match the bounded share the contract computes from the
        // Safe-owned pool note's value (arp-caf). In c9 the note is unshielded (raw transfer
        // to the Safe), so the owned note value is 0 and the payout is 0.
        uint256[] memory payouts = new uint256[](1);
        bytes32 safeNpk = _npk(address(safe));
        uint256 noteValue = pool.ownedNoteValue(safeNpk, address(usdc));
        payouts[0] = armAmt * noteValue / arm.totalSupply();

        // expectEmit on the event signature (fields must match).
        vm.expectEmit(true, false, false, false);
        emit RagequitExecuted(holder, armAmt, _npk(holder), tokens, payouts);
        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), tokens);
    }

    // ============ Helpers ============


    /// @dev A zero-valued shield ciphertext (the note is unencrypted for test simplicity).
    function _emptyShieldCiphertext() internal pure returns (ShieldCiphertext memory) {
        return ShieldCiphertext({encryptedBundle: [bytes32(0), bytes32(0), bytes32(0)], shieldKey: bytes32(0)});
    }

    function _shieldNote(bytes32 npk, uint120 value) internal view returns (ShieldRequest[] memory arr) {
        arr = new ShieldRequest[](1);
        TokenData memory usdcToken = TokenData({tokenType: TokenType.ERC20, tokenAddress: address(usdc), tokenSubID: 0});
        arr[0] = ShieldRequest({
            preimage: CommitmentPreimage({npk: npk, token: usdcToken, value: value}),
            ciphertext: _emptyShieldCiphertext()
        });
        return arr;
    }

    function _shieldUsdcNote(uint256 amount) public {
        usdc.mint(address(this), amount);
        usdc.approve(address(pool), amount);
        pool.shield(_shieldNote(_npk(address(safe)), uint120(amount)), address(0));
    }

    function _npk(address a) public pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _tokenList(address t) public pure returns (address[] memory) {
        address[] memory list = new address[](1);
        list[0] = t;
        return list;
    }

    /// @dev Computes the output note's commitment the same way the pool does:
    ///      PoseidonT4(npk, tokenID, value).
    function _commitment(bytes32 npk, address tokenAddr, uint256 armAmt, uint256 safeBal, uint256 supply)
        public
        pure
        returns (bytes32)
    {
        bytes32 tokenID = bytes32(uint256(uint160(tokenAddr)));
        bytes32 value = bytes32(uint256(armAmt * safeBal / supply));
        return PoseidonT4.poseidon([npk, tokenID, value]);
    }
}

// ============ MockBaalToken ============

/// @notice Minimal BaalToken-compatible token (Baal's shares token), mirroring the
///          BaalSafeSummon test pattern.
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
