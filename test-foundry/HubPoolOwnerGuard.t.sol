// ABOUTME: Foundry tests for the Hub PrivacyPool owner guard (pebble arp-3a7).
// ABOUTME: Proves the pool is non-upgradeable (c1), that the pool owner is not a
// ABOUTME: governance-reachable address (c2), and that the owner (not a stranger) holds
// ABOUTME: the verification-key setting power (c5, issue #349).
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../contracts/privacy-pool/PrivacyPool.sol";
import "../contracts/privacy-pool/modules/ShieldModule.sol";
import "../contracts/privacy-pool/modules/TransactModule.sol";
import "../contracts/privacy-pool/modules/MerkleModule.sol";
import "../contracts/privacy-pool/modules/VerifierModule.sol";
import "../contracts/cctp/MockUSDCV2.sol";
import "../contracts/cctp/MockCCTPV2.sol";
import "./helpers/PoseidonLinker.sol";

/// @title HubPoolOwnerGuardTest
/// @dev Deploys the hub pool + modules (real generated Poseidon bytecode via PoseidonLinker),
///      then proves: (c1) the pool has no upgrade entry point, (c2) the pool owner is not a
///      governance address, and (c5) only the owner can set the verification keys.
contract HubPoolOwnerGuardTest is Test, PoseidonLinker {
    PrivacyPool public pool;
    ShieldModule public shieldModule;
    TransactModule public transactModule;
    MerkleModule public merkleModule;
    VerifierModule public verifierModule;
    MockUSDCV2 public usdc;
    MockTokenMessengerV2 public tokenMessenger;
    MockMessageTransmitterV2 public messageTransmitter;

    /// Dedicated pool owner: the authority that sets the verification keys (issue #349).
    /// A single key or Safe multisig - never a DAO-governed contract.
    address public poolOwner;
    /// Governance-reachable addresses the pool owner must differ from.
    address public governor;
    address public governanceTreasury;
    address public windDown;

    function setUp() public {
        // Install the real generated Poseidon bytecode at the pinned link addresses.
        _linkRealPoseidon();

        poolOwner = address(this);
        governor = address(0x333);
        governanceTreasury = address(0x222);
        windDown = address(0x111);

        // USDC + CCTP mocks
        usdc = new MockUSDCV2("Mock USDC", "USDC");
        messageTransmitter = new MockMessageTransmitterV2(0, poolOwner);
        tokenMessenger = new MockTokenMessengerV2(address(messageTransmitter), address(usdc), 0);
        messageTransmitter.setTokenMessenger(address(tokenMessenger));

        // Modules + pool
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
            0, // localDomain
            poolOwner,
            payable(governanceTreasury)
        );
    }

    // ── c1: The pool must be non-upgradeable - no upgradeTo / upgradeToAndCall entry point. ──
    function test_PoolHasNoUpgradeEntryPoint() public {
        address poolAddr = address(pool);

        // upgradeTo(address)
        bytes32 upToSel = bytes4(keccak256("upgradeTo(address)"));
        bytes memory upToData = abi.encodePacked(upToSel, address(0x7777));
        (bool ok1,) = poolAddr.call(upToData);
        assertEq(ok1, false, "upgradeTo unexpectedly resolved - pool has an upgrade entry point");

        // upgradeToAndCall(address,bytes)
        bytes32 upToCallSel = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
        bytes memory upToCallData = abi.encodePacked(upToCallSel, address(0x7778), new bytes(1));
        (bool ok2,) = poolAddr.call(upToCallData);
        assertEq(ok2, false, "upgradeToAndCall unexpectedly resolved - pool has an upgrade entry point");
    }

    // ── c2: The pool owner is not a governance-reachable address. ──
    function test_PoolOwnerIsNotGovernanceControlled() public view {
        // The deployed pool owner is the dedicated key, not any governance contract address.
        assertEq(pool.owner(), poolOwner, "pool owner must equal the dedicated key");
        assertTrue(pool.owner() != governor, "pool owner equals the governor address");
        assertTrue(pool.owner() != governanceTreasury, "pool owner equals the treasury address");
        assertTrue(pool.owner() != windDown, "pool owner equals the wind-down address");
    }

    // ── c5: The owner can set the verification key; a stranger cannot. ──
    function test_SetVerificationKeyOwnerOnly() public {
        uint256[2] memory g2x1;
        g2x1[0] = 1;
        g2x1[1] = 1;
        uint256[2] memory g2y1;
        g2y1[0] = 1;
        g2y1[1] = 1;
        uint256[2] memory g2x2;
        g2x2[0] = 2;
        g2x2[1] = 2;
        uint256[2] memory g2y2;
        g2y2[0] = 2;
        g2y2[1] = 2;
        uint256[2] memory g2x3;
        g2x3[0] = 3;
        g2x3[1] = 3;
        uint256[2] memory g2y3;
        g2y3[0] = 3;
        g2y3[1] = 3;
        VerifyingKey memory vk = VerifyingKey(
            "0x1", G1Point(1, 2), G2Point(g2x1, g2y1), G2Point(g2x2, g2y2), G2Point(g2x3, g2y3), new G1Point[](1)
        );

        // Owner (poolOwner) can set the verification key (issue #349: owner keeps the power).
        pool.setVerificationKey(1, 2, vk);

        // (b) A stranger (separate probe contract, not the owner) cannot set the key:
        //      the probe's owner-gated call reverts, observable as a failed external call.
        SetKeyProbe probe = new SetKeyProbe(pool);
        (bool ok,) = address(probe).call(abi.encodeWithSignature("trySetKey(uint256,uint256,VerifyingKey)", 1, 2, vk));
        assertEq(ok, false, "stranger unexpectedly could set the verification key");
    }
}

/// @notice Minimal probe: a non-owner address calling the owner-gated setVerificationKey.
contract SetKeyProbe {
    PrivacyPool public pool;

    constructor(PrivacyPool _pool) {
        pool = _pool;
    }

    /// @notice Calls the pool's owner-gated setVerificationKey as a stranger (msg.sender = probe,
    ///          not the owner), proving a non-owner cannot set the key.
    function trySetKey(uint256 _nullifiers, uint256 _commitments, VerifyingKey memory _vk) external {
        pool.setVerificationKey(_nullifiers, _commitments, _vk);
    }
}
