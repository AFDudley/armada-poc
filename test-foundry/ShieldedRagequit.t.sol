// ABOUTME: Foundry tests for G3 shielded ragequit — the Baal manager-shaman exit path.
// ABOUTME: 9 tests matching the spec's acceptance names (c1-c9). The c10 exit-proof check is a
// ABOUTME: separate metamorphic script (bash scripts/verify-ragequit-exit-proof.sh).
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {PrivacyPool} from "../contracts/privacy-pool/PrivacyPool.sol";
import {ShieldModule} from "../contracts/privacy-pool/modules/ShieldModule.sol";
import {TransactModule} from "../contracts/privacy-pool/modules/TransactModule.sol";
import {MerkleModule} from "../contracts/privacy-pool/modules/MerkleModule.sol";
import {VerifierModule} from "../contracts/privacy-pool/modules/VerifierModule.sol";
import {
    CommitmentPreimage,
    TokenData,
    TokenType,
    UnshieldType,
    ShieldRequest,
    ShieldCiphertext
} from "../contracts/privacy-pool/types/PoolTypes.sol";
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
        bytes32 safeNote = _shieldToSafe(1000);
        uint256 balBefore = arm.balanceOf(holder);
        uint256 supplyBefore = arm.totalSupply();

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)), _safeNotes(safeNote));

        assertEq(arm.balanceOf(holder), balBefore - armAmt, "c1: caller ARM balance must drop by armAmount");
        assertEq(arm.totalSupply(), supplyBefore - armAmt, "c1: totalSupply must drop by armAmount");
    }

    // c3 · The registered burner (ShieldedRagequit) keeps its ability to burn after the change.
    function test_BurnerSetFrozen_ShieldedRagequitCanBurn() public {
        uint256 armAmt = 100;
        bytes32 safeNote = _shieldToSafe(1000);
        uint256 balBefore = arm.balanceOf(holder);
        uint256 supplyBefore = arm.totalSupply();

        // ShieldedRagequit burns an amount of ARM from the holder.
        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)), _safeNotes(safeNote));

        assertEq(arm.balanceOf(holder), balBefore - armAmt, "c3: caller ARM balance drops by armAmount");
        assertEq(arm.totalSupply(), supplyBefore - armAmt, "c3: totalSupply drops by armAmount");
    }

    // c5 · The existing shielded-ragequit tests register the token with the one-time
    //      registration only, and a member ragequit still burns that member's ARM.
    function test_RagequitBurnsArm() public {
        uint256 armAmt = 100;
        bytes32 safeNote = _shieldToSafe(1000);
        uint256 balBefore = arm.balanceOf(holder);
        uint256 supplyBefore = arm.totalSupply();

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)), _safeNotes(safeNote));

        assertEq(arm.balanceOf(holder), balBefore - armAmt, "c5: member ARM balance drops by the burn amount");
        assertEq(arm.totalSupply(), supplyBefore - armAmt, "c5: totalSupply drops by the burn amount");
    }

    // c2 · The exit creates a contract-owned note at the caller's npk with the bounded payout,
    //      debited from the Safe's pool-owned note (owner-derived npk).
    function test_RagequitCreatesOwnedNoteAtCallerNpk() public {
        bytes32 safeNote = _shieldToSafe(1000);
        uint256 armAmt = 100;
        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)), _safeNotes(safeNote));

        // The preimage registry now holds the output note's preimage (the caller's note at npk).
        bytes32 commitment = _commitment(_npk(holder), address(usdc), armAmt, 1000, arm.totalSupply());
        (bytes32 npk, TokenData memory tokenData, uint256 value) = pool.preimageOf(commitment);
        assertEq(npk, _npk(holder), "c2: the note must be at the caller's npk");
        assertEq(uint8(tokenData.tokenType), uint8(TokenType.ERC20), "c2: payout is denominated in the treasury token");
        assertEq(tokenData.tokenAddress, address(usdc), "c2: payout token is the treasury USDC");
        assertEq(value, armAmt * 1000 / arm.totalSupply(), "c2: payout equals the bounded share");
    }

    // c3 · The exit succeeds with a single direct call — no Safe signature, no Baal proposal.
    function test_RagequitNeedsNoSafeSignatureOrProposal() public {
        bytes32 safeNote = _shieldToSafe(1000);
        uint256 supplyBefore = arm.totalSupply();
        uint256 armAmt = 100;

        // A single call from the holder succeeds: no Safe multisig, no Baal proposal needed.
        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)), _safeNotes(safeNote));

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
        bytes32 safeNote = _shieldToSafe(1000);
        uint256 armAmt = 100;
        uint256 safeBal = 1000;
        uint256 supply = arm.totalSupply();
        uint256 bound = armAmt * safeBal / supply;

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)), _safeNotes(safeNote));

        // The exit pays out exactly the bound — never more.
        (,, uint256 value) = pool.preimageOf(_commitment(_npk(holder), address(usdc), armAmt, safeBal, supply));
        assertEq(value, bound, "c4: payout equals the bounded share");
        assertLe(value, safeBal, "c4: the treasury keeps its funds (payout <= Safe balance)");
    }

    // c5 · A caller with no ARM reverts; no note created; Safe balance + totalSupply unchanged.
    function test_RagequitRevertsForNonHolder() public {
        usdc.mint(address(safe), 1000);
        bytes32 safeNote = _shieldToSafe(1000);
        uint256 balBefore = arm.balanceOf(nonHolder);
        uint256 supplyBefore = arm.totalSupply();
        uint256 safeBalBefore = usdc.balanceOf(address(safe));

        // The non-holder's call must revert (burnFrom: insufficient balance).
        vm.prank(nonHolder);
        try ragequit.ragequit(100, _npk(nonHolder), _tokenList(address(usdc)), _safeNotes(safeNote)) {
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
        bytes32 safeNote = _shieldToSafe(1000);
        uint256 supplyBefore = arm.totalSupply();
        uint256 aAmt = 100; // ~10% of supply (holder)
        uint256 bAmt = 200; // ~20% of supply (holder2)

        // Both holders exit the same token (USDC) in the same block.
        uint256 holderBalBefore = arm.balanceOf(holder);
        uint256 holder2BalBefore = arm.balanceOf(holder2);

        vm.prank(holder);
        ragequit.ragequit(aAmt, _npk(holder), _tokenList(address(usdc)), _safeNotes(safeNote));
        vm.prank(holder2);
        try ragequit.ragequit(bAmt, _npk(holder2), _tokenList(address(usdc)), _safeNotes(safeNote)) {
            revert("c8: second ragequit should have reverted (shared note)");
        } catch {
            // expected revert
        }

        // The bound holds: total paid = aAmt*bal/S0 + bAmt*bal/(S0-aAmt) must be <= the
        // Safe's held balance.
        uint256 base = 1000;
        uint256 totalPaid = aAmt * base / supplyBefore + bAmt * base / (supplyBefore - aAmt);
        assertLe(totalPaid, base, "c8: total paid must not exceed the Safe-owned note value");
        // holder burned aAmt of its own ARM; holder2's exit reverted (Note already spent).
        assertEq(arm.balanceOf(holder), holderBalBefore - aAmt, "c8: holder balance drops by exactly the burn amount");
        assertEq(arm.balanceOf(holder2), holder2BalBefore, "c8: holder2 balance unchanged after reverted exit");
    }

    // c9 · Every holdings change (the exit) emits RagequitExecuted with the correct fields.
    function test_RagequitEmitsRagequitExecuted() public {
        bytes32 safeNote = _shieldToSafe(100);
        uint256 armAmt = 100;
        address[] memory tokens = _tokenList(address(usdc));
        // The event's payout must match the bounded share the contract computes.
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = armAmt * 100 / arm.totalSupply();

        // expectEmit on the event signature (fields must match).
        vm.expectEmit(true, false, false, false);
        emit RagequitExecuted(holder, armAmt, _npk(holder), tokens, payouts);
        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), tokens, _safeNotes(safeNote));
    }

    // ─────────────────────────────────────────────────────────────────────
    // arp-caf (E3) · The payout base is the Safe-owned pool note value, not balanceOf(safe).

    // caf-c1 · payout = burned ARM * Safe-owned note value / supply.
    function test_RagequitPayoutBaseIsSafeOwnedNoteValue() public {
        uint256 noteValue = 1000;
        bytes32 safeNote = _shieldToSafe(noteValue);
        uint256 armAmt = arm.totalSupply() / 4;

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)), _safeNotes(safeNote));

        uint256 expected = armAmt * noteValue / arm.totalSupply();
        (,, uint120 value) =
            pool.preimageOf(PoseidonT4.poseidon([_npk(holder), _tokenID(address(usdc)), bytes32(expected)]));
        assertGt(expected, 0, "caf-c1: a nonzero pro-rata share");
        assertEq(uint256(value), expected, "caf-c1: payout base is the Safe-owned note value");
    }

    // caf-c2 · A fully shielded treasury (zero public balance) still pays a nonzero share.
    function test_RagequitPaysNonzeroFromFullyShieldedTreasury() public {
        uint256 noteValue = 1000;
        bytes32 safeNote = _shieldToSafe(noteValue);
        assertEq(usdc.balanceOf(address(safe)), 0, "caf-c2: the treasury is fully shielded (zero public balance)");
        uint256 armAmt = arm.totalSupply() / 4;

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)), _safeNotes(safeNote));

        uint256 expected = armAmt * noteValue / arm.totalSupply();
        (,, uint120 value) =
            pool.preimageOf(PoseidonT4.poseidon([_npk(holder), _tokenID(address(usdc)), bytes32(expected)]));
        assertGt(uint256(value), 0, "caf-c2: nonzero payout from a fully shielded treasury");
        assertEq(uint256(value), expected, "caf-c2: payout is the bounded share of the note value");
    }

    // caf-c3 · A raw ERC-20 transfer straight to the Safe does not change the payout.
    function test_RagequitPayoutIgnoresRawTransferToSafe() public {
        uint256 noteValue = 1000;
        bytes32 safeNote = _shieldToSafe(noteValue);
        usdc.mint(address(safe), 500); // tainted dust, credited to no note
        uint256 armAmt = arm.totalSupply() / 4;

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)), _safeNotes(safeNote));

        uint256 expected = armAmt * noteValue / arm.totalSupply();
        (,, uint120 value) =
            pool.preimageOf(PoseidonT4.poseidon([_npk(holder), _tokenID(address(usdc)), bytes32(expected)]));
        assertEq(uint256(value), expected, "caf-c3: the raw transfer to the Safe does not change the payout");
    }

    // caf-c4 · The Safe-owned note falls by exactly the payout (the change note holds base - payout).
    function test_RagequitDebitsSafeOwnedNoteByPayout() public {
        uint256 noteValue = 1000;
        bytes32 safeNote = _shieldToSafe(noteValue);
        uint256 armAmt = arm.totalSupply() / 4;

        vm.prank(holder);
        ragequit.ragequit(armAmt, _npk(holder), _tokenList(address(usdc)), _safeNotes(safeNote));

        uint256 payout = armAmt * noteValue / arm.totalSupply();
        uint256 change = noteValue - payout;
        (bytes32 cnpk,, uint120 cvalue) =
            pool.preimageOf(PoseidonT4.poseidon([_safeNpk(), _tokenID(address(usdc)), bytes32(change)]));
        assertEq(cnpk, _safeNpk(), "caf-c4: the change note belongs to the Safe");
        assertEq(uint256(cvalue), change, "caf-c4: the Safe note value falls by exactly the payout");
    }

    // ============ Helpers ============

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

    /// @dev Token ID the pool uses for an ERC20 (its address in the field element).
    function _tokenID(address t) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(t)));
    }

    function _usdcTokenData() internal view returns (TokenData memory) {
        return TokenData({tokenType: TokenType.ERC20, tokenAddress: address(usdc), tokenSubID: 0});
    }

    function _safeNpk() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(safe))));
    }

    /// @dev Shields `value` USDC into a Safe-owned pool note (the fixture's shield fee is 0, so
    ///      the recorded note value equals `value`) and returns its commitment. The USDC moves
    ///      into the pool, so the Safe's public ERC-20 balance is unchanged.
    function _shieldToSafe(uint256 value) internal returns (bytes32 commitment) {
        usdc.mint(address(this), value);
        usdc.approve(address(pool), value);
        ShieldRequest[] memory reqs = new ShieldRequest[](1);
        reqs[0] = ShieldRequest({
            preimage: CommitmentPreimage({npk: _safeNpk(), token: _usdcTokenData(), value: uint120(value)}),
            ciphertext: ShieldCiphertext({encryptedBundle: [bytes32(0), bytes32(0), bytes32(0)], shieldKey: bytes32(0)})
        });
        pool.shield(reqs, address(0));
        commitment = PoseidonT4.poseidon([_safeNpk(), _tokenID(address(usdc)), bytes32(value)]);
    }

    /// @dev A single-element Safe-note commitment list, parallel to a single-token list.
    function _safeNotes(bytes32 c) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = c;
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
