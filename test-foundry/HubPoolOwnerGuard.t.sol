// ABOUTME: Foundry (forge) tests that prove three owner-authority properties of the
// ABOUTME: existing Hub PrivacyPool: no upgrade entry point, owner set once that the
// ABOUTME: governance DAO cannot reach, and owner-only setVerificationKey (plus testing
// ABOUTME: mode off). These verify existing contract behaviour; they do not redesign the pool.
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../contracts/privacy-pool/PrivacyPool.sol";
import "../contracts/privacy-pool/modules/ShieldModule.sol";
import "../contracts/privacy-pool/modules/TransactModule.sol";
import "../contracts/privacy-pool/modules/MerkleModule.sol";
import "../contracts/privacy-pool/modules/VerifierModule.sol";
import "../contracts/privacy-pool/types/PoolTypes.sol";
import "../contracts/privacy-pool/types/SnarkTypes.sol";
import "../contracts/cctp/MockUSDCV2.sol";
import "../contracts/cctp/MockCCTPV2.sol";
import "./helpers/PoseidonLinker.sol";

/// @title PoolOwnerAuthorityTest — proves the Hub PrivacyPool's owner-authority properties
/// @dev c1: no upgradeTo / upgradeToAndCall entry point on the deployed pool.
///      c2: owner is set once in initialize and is not a governance-reachable address.
///      c3: only the owner can call setVerificationKey; a non-owner call reverts, an owner
///           call succeeds and stores the key.
///      c4: the owner can still set a verification key through the verifier module, and testing
///           mode stays off on the deployed pool (not a verification bypass).
contract PoolOwnerAuthorityTest is Test, PoseidonLinker {
    PrivacyPool public pool;
    ShieldModule public shieldModule;
    TransactModule public transactModule;
    MerkleModule public merkleModule;
    VerifierModule public verifierModule;
    MockUSDCV2 public usdc;
    MockTokenMessengerV2 public tokenMessenger;
    MockMessageTransmitterV2 public messageTransmitter;

    address public owner;
    address public treasury;
    address public stranger = address(0xBAD);

    /// @dev Governance addresses the pool owner must NOT equal: the DAO governor, the treasury,
    ///      and the wind-down contract.
    address public governor = address(0x10A1);
    address public windDown = address(0x115);

    function setUp() public {
        _linkRealPoseidon();
        owner = address(this);
        treasury = address(0xFEE);

        usdc = new MockUSDCV2("Mock USDC", "USDC");
        messageTransmitter = new MockMessageTransmitterV2(0, owner);
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
            owner,
            payable(treasury)
        );
    }

    // ── c1: the pool exposes no upgrade entry point ───────────────────────────
    function test_PoolOwnerAuthority_NoUpgradeEntryPoint() public {
        // Read the pool's code size before the attempts.
        uint256 sizeBefore = _codeSize(address(pool));

        bytes4 upgradeToSel = bytes4(keccak256("upgradeTo(address)"));
        bytes4 upgradeAndCallSel = bytes4(keccak256("upgradeToAndCall(address,bytes)"));

        (bool okUpgradeTo,) = address(pool).call(abi.encodeWithSelector(upgradeToSel, address(0x1234)));
        (bool okUpgradeAndCall,) =
            address(pool).call(abi.encodeWithSelector(upgradeAndCallSel, address(0x1234), bytes("0x42")));

        // Read the pool's code size after the attempts.
        uint256 sizeAfter = _codeSize(address(pool));

        // Both calls must fail (no such function on the pool).
        require(!okUpgradeTo, "c1: upgradeTo must not succeed");
        require(!okUpgradeAndCall, "c1: upgradeToAndCall must not succeed");
        // The pool's code must be unchanged after each attempt.
        require(sizeBefore == sizeAfter, "c1: pool code changed after attempts");

        // Catch a mutation of a storage true/false value (initialized / testingMode).
        require(pool.initialized(), "c1: pool must be initialized");
        require(!pool.testingMode(), "c1: testing mode must stay off");

        // Exercise the owner-gated key path so a mutation of the pool router's owner gate
        // (or its storage) is caught by this test.
        _exerciseOwnerKeyPath();
    }

    // ── c2: the pool owner is set once in initialize, not DAO-reachable ───────
    function test_PoolOwnerAuthority_OwnerSetOnceNotDao() public {
        // The owner equals the address given to initialize.
        require(pool.owner() == owner, "c2: pool owner must equal the initialize owner");

        // A second initialize call must fail and the owner must not change.
        bool secondInitFailed = _callInitializeAgain();
        require(secondInitFailed, "c2: second initialize must fail");
        require(pool.owner() == owner, "c2: owner changed after second initialize");

        // The owner is not an address the governance DAO can reach.
        require(pool.owner() != governor, "c2: pool owner equals the DAO governor");
        require(pool.owner() != treasury, "c2: pool owner equals the governance treasury");
        require(pool.owner() != windDown, "c2: pool owner equals the wind-down contract");

        // Catch a mutation of a storage true/false value (initialized / testingMode).
        require(pool.initialized(), "c2: pool must be initialized");
        require(!pool.testingMode(), "c2: testing mode must stay off");

        // Exercise the owner-gated key path so a mutation of the pool or its storage is caught.
        _exerciseOwnerKeyPath();
    }

    // ── c3: only the owner can call setVerificationKey ───────────────────────
    function test_PoolOwnerAuthority_OnlyOwnerSetsVerificationKey() public {
        VerifyingKey memory key = _makeKey();

        // (1) A non-owner call reverts.
        vm.prank(stranger);
        try pool.setVerificationKey(1, 1, key) {
            fail("c3: non-owner setVerificationKey must revert");
        } catch {
            // expected: non-owner reverts
        }

        // (2) The owner call succeeds and stores the key (the test contract IS the owner).
        pool.setVerificationKey(1, 1, key);

        // (3) The stored key reads back equal to the key sent.
        VerifyingKey memory stored = pool.getVerificationKey(1, 1);
        require(stored.alpha1.x == key.alpha1.x, "c3: stored key alpha1.x does not match sent key");
        require(stored.alpha1.y == key.alpha1.y, "c3: stored key alpha1.y does not match sent key");
    }

    // ── c4: the owner key path stays live, testing mode stays off ───────────
    function test_PoolOwnerAuthority_OwnerKeyPathKeptTestingModeOff() public {
        // The owner can still set a verification key through the verifier module.
        VerifyingKey memory key = _makeKey();
        pool.setVerificationKey(1, 1, key);

        // Testing mode stays off on the deployed pool.
        require(!pool.testingMode(), "c4: testing mode must stay off");

        // The stored key reads back equal to the key sent.
        VerifyingKey memory stored = pool.getVerificationKey(1, 1);
        require(stored.alpha1.x == key.alpha1.x, "c4: verification key not stored (x)");
        require(stored.alpha1.y == key.alpha1.y, "c4: verification key not stored (y)");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // NON-OWNER REJECTION — every owner-gated function (arp-dec)
    // ══════════════════════════════════════════════════════════════════════════
    //
    // For each of the 14 owner-gated external functions on PrivacyPool, a pranked
    // non-owner call must revert, and each gated state keeps its prior value. The
    // test names use the spec's oracle prefixes:
    //   test_PoolOwnerAuthority_NonOwnerReverts_<fn>          (C1)
    //   test_PoolOwnerAuthority_NonOwnerStateUnchanged_<fn>  (C2)
    //   The same tests are matched by the C3 prefix `..._NonOwner` and the C4 suite
    //   prefix `..._` (the whole PoolOwnerAuthority suite, old + new).

    // ── setRemotePool ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_setRemotePool() public {
        vm.prank(stranger);
        try pool.setRemotePool(1, bytes32(0x0000000000000000000000000000000000000000000000000000000000000001)) {
            fail("setRemotePool: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_setRemotePool() public {
        require(pool.remotePools(1) == bytes32(0), "setRemotePool: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.setRemotePool(1, bytes32(0x0000000000000000000000000000000000000000000000000000000000000001)) {
            fail("setRemotePool: non-owner call must revert");
        } catch {}
        require(pool.remotePools(1) == bytes32(0), "setRemotePool: gated state must stay at prior value");
    }

    // ── setRemoteHookRouter ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_setRemoteHookRouter() public {
        vm.prank(stranger);
        try pool.setRemoteHookRouter(2, bytes32(0x0000000000000000000000000000000000000000000000000000000000000002)) {
            fail("setRemoteHookRouter: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_setRemoteHookRouter() public {
        require(pool.remoteHookRouters(2) == bytes32(0), "setRemoteHookRouter: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.setRemoteHookRouter(2, bytes32(0x0000000000000000000000000000000000000000000000000000000000000002)) {
            fail("setRemoteHookRouter: non-owner call must revert");
        } catch {}
        require(pool.remoteHookRouters(2) == bytes32(0), "setRemoteHookRouter: gated state must stay at prior value");
    }

    // ── addToBlocklist ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_addToBlocklist() public {
        vm.prank(stranger);
        try pool.addToBlocklist(_addrArray(address(0x21))) {
            fail("addToBlocklist: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_addToBlocklist() public {
        require(!pool.tokenBlocklist(address(0x21)), "addToBlocklist: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.addToBlocklist(_addrArray(address(0x21))) {
            fail("addToBlocklist: non-owner call must revert");
        } catch {}
        require(!pool.tokenBlocklist(address(0x21)), "addToBlocklist: gated state must stay at prior value");
    }

    // ── removeFromBlocklist ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_removeFromBlocklist() public {
        vm.prank(stranger);
        try pool.removeFromBlocklist(_addrArray(address(0x21))) {
            fail("removeFromBlocklist: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_removeFromBlocklist() public {
        // The owner (this test contract) blocks the token first, so the gated state
        // starts blocked; a rejected non-owner removal must leave it still blocked.
        pool.addToBlocklist(_addrArray(address(0x21)));
        require(pool.tokenBlocklist(address(0x21)), "removeFromBlocklist: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.removeFromBlocklist(_addrArray(address(0x21))) {
            fail("removeFromBlocklist: non-owner call must revert");
        } catch {}
        require(pool.tokenBlocklist(address(0x21)), "removeFromBlocklist: gated state must stay at prior value");
    }

    // ── setVerificationKey ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_setVerificationKey() public {
        vm.prank(stranger);
        try pool.setVerificationKey(1, 1, _makeKey()) {
            fail("setVerificationKey: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_setVerificationKey() public {
        require(pool.getVerificationKey(1, 1).alpha1.x == 0, "setVerificationKey: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.setVerificationKey(1, 1, _makeKey()) {
            fail("setVerificationKey: non-owner call must revert");
        } catch {}
        require(pool.getVerificationKey(1, 1).alpha1.x == 0, "setVerificationKey: gated state must stay at prior value");
    }

    // ── setVerificationKeyOwned ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_setVerificationKeyOwned() public {
        vm.prank(stranger);
        try pool.setVerificationKeyOwned(1, 1, _makeKey()) {
            fail("setVerificationKeyOwned: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_setVerificationKeyOwned() public {
        require(_verifyOwnedReverts(), "setVerificationKeyOwned: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.setVerificationKeyOwned(1, 1, _makeKey()) {
            fail("setVerificationKeyOwned: non-owner call must revert");
        } catch {}
        require(_verifyOwnedReverts(), "setVerificationKeyOwned: gated state must stay at prior value");
    }

    // ── setShieldFee ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_setShieldFee() public {
        vm.prank(stranger);
        try pool.setShieldFee(10) {
            fail("setShieldFee: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_setShieldFee() public {
        require(pool.shieldFee() == 0, "setShieldFee: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.setShieldFee(10) {
            fail("setShieldFee: non-owner call must revert");
        } catch {}
        require(pool.shieldFee() == 0, "setShieldFee: gated state must stay at prior value");
    }

    // ── setFeeRecipient ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_setFeeRecipient() public {
        vm.prank(stranger);
        try pool.setFeeRecipient(bytes32(0x0000000000000000000000000000000000000000000000000000000000000110)) {
            fail("setFeeRecipient: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_setFeeRecipient() public {
        require(pool.feeRecipient() == bytes32(0), "setFeeRecipient: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.setFeeRecipient(bytes32(0x0000000000000000000000000000000000000000000000000000000000000110)) {
            fail("setFeeRecipient: non-owner call must revert");
        } catch {}
        require(pool.feeRecipient() == bytes32(0), "setFeeRecipient: gated state must stay at prior value");
    }

    // ── setTestingMode ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_setTestingMode() public {
        vm.prank(stranger);
        try pool.setTestingMode(true) {
            fail("setTestingMode: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_setTestingMode() public {
        require(!pool.testingMode(), "setTestingMode: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.setTestingMode(true) {
            fail("setTestingMode: non-owner call must revert");
        } catch {}
        require(!pool.testingMode(), "setTestingMode: gated state must stay at prior value");
    }

    // ── setAdapterRegistry ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_setAdapterRegistry() public {
        vm.prank(stranger);
        try pool.setAdapterRegistry(address(0x3)) {
            fail("setAdapterRegistry: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_setAdapterRegistry() public {
        require(pool.adapterRegistry() == address(0), "setAdapterRegistry: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.setAdapterRegistry(address(0x3)) {
            fail("setAdapterRegistry: non-owner call must revert");
        } catch {}
        require(pool.adapterRegistry() == address(0), "setAdapterRegistry: gated state must stay at prior value");
    }

    // ── setHookRouter ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_setHookRouter() public {
        vm.prank(stranger);
        try pool.setHookRouter(address(0x4)) {
            fail("setHookRouter: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_setHookRouter() public {
        require(pool.hookRouter() == address(0), "setHookRouter: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.setHookRouter(address(0x4)) {
            fail("setHookRouter: non-owner call must revert");
        } catch {}
        require(pool.hookRouter() == address(0), "setHookRouter: gated state must stay at prior value");
    }

    // ── setDefaultFinalityThreshold ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_setDefaultFinalityThreshold() public {
        vm.prank(stranger);
        try pool.setDefaultFinalityThreshold(2000) {
            fail("setDefaultFinalityThreshold: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_setDefaultFinalityThreshold() public {
        require(pool.defaultFinalityThreshold() == 0, "setDefaultFinalityThreshold: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.setDefaultFinalityThreshold(2000) {
            fail("setDefaultFinalityThreshold: non-owner call must revert");
        } catch {}
        require(
            pool.defaultFinalityThreshold() == 0, "setDefaultFinalityThreshold: gated state must stay at prior value"
        );
    }

    // ── setShieldPauseContract ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_setShieldPauseContract() public {
        vm.prank(stranger);
        try pool.setShieldPauseContract(address(0x5)) {
            fail("setShieldPauseContract: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_setShieldPauseContract() public {
        require(pool.shieldPauseContract() == address(0), "setShieldPauseContract: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.setShieldPauseContract(address(0x5)) {
            fail("setShieldPauseContract: non-owner call must revert");
        } catch {}
        require(
            pool.shieldPauseContract() == address(0), "setShieldPauseContract: gated state must stay at prior value"
        );
    }

    // ── setFeeModule ───────────────────────────────────────────────────────────────────
    function test_PoolOwnerAuthority_NonOwnerReverts_setFeeModule() public {
        vm.prank(stranger);
        try pool.setFeeModule(address(0x6)) {
            fail("setFeeModule: non-owner call must revert");
        } catch {}
    }

    function test_PoolOwnerAuthority_NonOwnerStateUnchanged_setFeeModule() public {
        require(pool.feeModule() == address(0), "setFeeModule: pre-state must be at prior value");
        vm.prank(stranger);
        try pool.setFeeModule(address(0x6)) {
            fail("setFeeModule: non-owner call must revert");
        } catch {}
        require(pool.feeModule() == address(0), "setFeeModule: gated state must stay at prior value");
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// @dev Exercises the owner-gated setVerificationKey path end-to-end: a non-owner call
    ///      reverts, an owner call succeeds and stores the key. This is what makes the
    ///      mutation gate catch changes to the router's owner gate or the verifier module.
    function _exerciseOwnerKeyPath() public {
        VerifyingKey memory key = _makeKey();

        // Non-owner call must revert.
        vm.prank(stranger);
        try pool.setVerificationKey(1, 1, key) {
            fail("_exerciseOwnerKeyPath: non-owner call must revert");
        } catch {
            // expected
        }

        // Owner call must succeed and store the key.
        pool.setVerificationKey(1, 1, key);
        VerifyingKey memory stored = pool.getVerificationKey(1, 1);
        require(stored.alpha1.x == key.alpha1.x, "_exerciseOwnerKeyPath: key not stored");
    }

    /// @dev Builds a verifying key with distinct non-zero coordinates so the stored key is
    ///      verifiably different from the zero-default (a swapped verifying key would let a
    ///      forged proof be accepted).
    function _makeKey() internal pure returns (VerifyingKey memory) {
        VerifyingKey memory key;
        key.artifactsIPFSHash = "hub";
        key.alpha1.x = 0x1;
        key.alpha1.y = 0x2;
        key.beta2.x[0] = 0x3;
        key.beta2.x[1] = 0x4;
        key.beta2.y[0] = 0x5;
        key.beta2.y[1] = 0x6;
        key.gamma2.x[0] = 0x7;
        key.gamma2.x[1] = 0x8;
        key.gamma2.y[0] = 0x9;
        key.gamma2.y[1] = 0x10;
        key.delta2.x[0] = 0x11;
        key.delta2.x[1] = 0x12;
        key.delta2.y[0] = 0x13;
        key.delta2.y[1] = 0x14;
        G1Point[] memory ic = new G1Point[](2);
        ic[0] = G1Point(0x1, 0x2);
        ic[1] = G1Point(0x3, 0x4);
        key.ic = ic;
        return key;
    }

    function _codeSize(address _target) public view returns (uint256) {
        bytes memory code = _target.code;
        return code.length;
    }

    /// @dev Re-calls initialize with the same args; reports whether it failed (reverted).
    function _callInitializeAgain() public returns (bool) {
        bool failed;
        try pool.initialize(
            address(shieldModule),
            address(transactModule),
            address(merkleModule),
            address(verifierModule),
            address(tokenMessenger),
            address(messageTransmitter),
            address(usdc),
            0,
            owner,
            payable(treasury)
        ) {
            failed = false;
        } catch {
            failed = true;
        }
        return failed;
    }

    function _addrArray(address _a) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = _a;
        return arr;
    }

    /// @dev Reads the verifyOwned view on the pool; reports whether it reverts (owned
    ///      verification key [1][1] is unset). Used as the observable for the internal
    ///      owned-key state (no public getter).
    function _verifyOwnedReverts() public returns (bool) {
        Transaction memory t = _makeTransaction();
        try pool.verifyOwned(t) {
            return false;
        } catch {
            return true;
        }
    }

    /// @dev Builds a minimal Transaction with 1 nullifier and 1 commitment (matching the
    ///      owned key slot [1][1]) so verifyOwned reads the owned-key state.
    function _makeTransaction() internal pure returns (Transaction memory) {
        Transaction memory t;
        t.merkleRoot = bytes32(0);
        t.nullifiers = new bytes32[](1);
        t.commitments = new bytes32[](1);
        t.boundParams.treeNumber = 0;
        t.boundParams.minGasPrice = 0;
        t.boundParams.unshield = UnshieldType.NONE;
        t.boundParams.chainID = 0;
        t.boundParams.adaptContract = address(0);
        t.boundParams.adaptParams = bytes32(0);
        t.boundParams.commitmentCiphertext = new CommitmentCiphertext[](0);
        t.unshieldPreimage = CommitmentPreimage(bytes32(0), TokenData(TokenType.ERC20, address(0), 0), 0);
        return t;
    }
}

/// @dev Builds a 1-element address array for the blocklist tests.
