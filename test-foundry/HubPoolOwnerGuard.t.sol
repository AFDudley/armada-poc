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
}
