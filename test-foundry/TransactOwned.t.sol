// ABOUTME: Foundry tests for P2a — the contract-owned spend path (transactOwned) and the
// ABOUTME: public preimage registry (preimageOf), plus publicOutputs hash binding on transact.
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../contracts/privacy-pool/PrivacyPool.sol";
import "../contracts/test/PrivacyPoolProofBypass.sol";
import "../contracts/privacy-pool/modules/ShieldModule.sol";
import "../contracts/privacy-pool/modules/TransactModule.sol";
import "../contracts/privacy-pool/modules/MerkleModule.sol";
import "../contracts/privacy-pool/modules/VerifierModule.sol";
import "../contracts/privacy-pool/types/PoolTypes.sol";
import "../contracts/privacy-pool/types/PoseidonLibs.sol";
import "../contracts/cctp/MockUSDCV2.sol";
import "../contracts/cctp/MockCCTPV2.sol";
import "./helpers/PoseidonLinker.sol";

/// @title TransactOwnedTest — P2a contract-owned spend path and preimage registry
/// @dev Runs in testingMode so the SNARK proof is bypassed; this isolates the
///      authorization (msg.sender == ownerField), the no-unshield rule, the
///      publicOutputs hash binding, and the preimageOf registry writes — the rules
///      the derivation could not express as an oracle (fund-moving Solidity reverts).
contract TransactOwnedTest is Test, PoseidonLinker {
    PrivacyPoolProofBypass public pool;
    ShieldModule public shieldModule;
    TransactModule public transactModule;
    MerkleModule public merkleModule;
    VerifierModule public verifierModule;
    MockUSDCV2 public usdc;
    MockTokenMessengerV2 public tokenMessenger;
    MockMessageTransmitterV2 public messageTransmitter;

    address public owner;
    address public treasury;
    address public noteOwner = address(0xB0B);
    address public stranger = address(0xBAD);
    uint120 constant VALUE = 1000;

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

        pool = new PrivacyPoolProofBypass();
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
        // POC testing mode bypasses only the SNARK proof; every other check (merkle
        // root, caller authorization, publicOutputs hashing) runs for real.
        pool.setSkipProofVerification(true);
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _token() internal view returns (TokenData memory) {
        return TokenData({tokenType: TokenType.ERC20, tokenAddress: address(usdc), tokenSubID: 0});
    }

    /// @notice Mirrors TransactModule._hashCommitment for an ERC20 note.
    function _commitment(CommitmentPreimage memory n) internal pure returns (bytes32) {
        bytes32 tokenID = bytes32(uint256(uint160(n.token.tokenAddress)));
        return PoseidonT4.poseidon([n.npk, tokenID, bytes32(uint256(n.value))]);
    }

    function _emptyCiphertext(uint256 count) internal pure returns (CommitmentCiphertext[] memory ct) {
        ct = new CommitmentCiphertext[](count);
        for (uint256 i = 0; i < count; i++) {
            ct[i] = CommitmentCiphertext({
                ciphertext: [bytes32(0), bytes32(0), bytes32(0), bytes32(0)],
                blindedSenderViewingKey: bytes32(0),
                blindedReceiverViewingKey: bytes32(0),
                annotationData: "",
                memo: ""
            });
        }
    }

    function _zeroProof() internal pure returns (SnarkProof memory) {
        return SnarkProof({a: G1Point(0, 0), b: G2Point([uint256(0), 0], [uint256(0), 0]), c: G1Point(0, 0)});
    }

    /// @notice Build a single-output transaction. `declaredCommitment` is the commitment
    ///         the pool sees; `preimage` is the plaintext output supplied. When they
    ///         disagree the hash check must reject the transaction.
    function _buildTxn(
        UnshieldType unshieldType,
        bytes32 ownerField,
        CommitmentPreimage memory preimage,
        bytes32 declaredCommitment,
        bool includePublicOutput
    ) internal view returns (Transaction memory) {
        bytes32[] memory nullifiers = new bytes32[](1);
        nullifiers[0] = keccak256(abi.encode(declaredCommitment, "nullifier"));

        bytes32[] memory commitments = new bytes32[](1);
        commitments[0] = declaredCommitment;

        CommitmentPreimage[] memory publicOutputs;
        if (includePublicOutput) {
            publicOutputs = new CommitmentPreimage[](1);
            publicOutputs[0] = preimage;
        } else {
            publicOutputs = new CommitmentPreimage[](0);
        }

        return Transaction({
            proof: _zeroProof(),
            merkleRoot: pool.merkleRoot(),
            nullifiers: nullifiers,
            commitments: commitments,
            boundParams: BoundParams({
                treeNumber: 0,
                minGasPrice: 0,
                unshield: unshieldType,
                chainID: uint64(block.chainid),
                adaptContract: address(0),
                adaptParams: bytes32(0),
                commitmentCiphertext: _emptyCiphertext(1),
                ownerField: ownerField,
                publicOutputs: publicOutputs
            }),
            unshieldPreimage: CommitmentPreimage({npk: bytes32(0), token: _token(), value: 0})
        });
    }

    function _single(Transaction memory t) internal pure returns (Transaction[] memory arr) {
        arr = new Transaction[](1);
        arr[0] = t;
    }

    // ── tests ────────────────────────────────────────────────────────────────

    /// @notice A transact with one contract-owned output records its preimage, readable
    ///         by any caller with the correct token and value.
    function test_transact_contractOwnedOutput_recordsPreimage() public {
        CommitmentPreimage memory preimage =
            CommitmentPreimage({npk: bytes32(uint256(0x1111)), token: _token(), value: VALUE});
        bytes32 commitment = _commitment(preimage);

        Transaction memory t = _buildTxn(UnshieldType.NONE, bytes32(0), preimage, commitment, true);
        pool.transact(_single(t));

        (bytes32 npk, TokenData memory token, uint120 value) = pool.preimageOf(commitment);
        assertEq(npk, bytes32(uint256(0x1111)), "preimage npk recorded");
        assertEq(token.tokenAddress, address(usdc), "preimage token recorded");
        assertEq(uint256(value), uint256(VALUE), "preimage value recorded");
    }

    /// @notice A transact whose plaintext output does not hash to its commitment reverts,
    ///         so the registry can never record an unverified preimage.
    function test_transact_publicOutputHashMismatch_reverts() public {
        CommitmentPreimage memory honest =
            CommitmentPreimage({npk: bytes32(uint256(0x1111)), token: _token(), value: VALUE});
        bytes32 commitment = _commitment(honest);

        // Supply a DIFFERENT preimage than the one the commitment hashes.
        CommitmentPreimage memory tampered =
            CommitmentPreimage({npk: bytes32(uint256(0x2222)), token: _token(), value: VALUE});

        Transaction memory t = _buildTxn(UnshieldType.NONE, bytes32(0), tampered, commitment, true);
        vm.expectRevert("TransactModule: Invalid Public Output");
        pool.transact(_single(t));
    }

    /// @notice transactOwned from the correct owner, with a valid (bypassed) proof,
    ///         succeeds and records the preimage for every output.
    function test_transactOwned_fromOwner_succeeds_recordsPreimage() public {
        bytes32 ownerField = bytes32(uint256(uint160(noteOwner)));
        CommitmentPreimage memory preimage =
            CommitmentPreimage({npk: bytes32(uint256(0x3333)), token: _token(), value: VALUE});
        bytes32 commitment = _commitment(preimage);

        Transaction memory t = _buildTxn(UnshieldType.NONE, ownerField, preimage, commitment, true);
        vm.prank(noteOwner);
        pool.transactOwned(_single(t));

        (,, uint120 value) = pool.preimageOf(commitment);
        assertEq(uint256(value), uint256(VALUE), "owned preimage recorded");
    }

    /// @notice transactOwned called by any address other than the proof's owner reverts.
    function test_transactOwned_wrongOwner_reverts() public {
        bytes32 ownerField = bytes32(uint256(uint160(noteOwner)));
        CommitmentPreimage memory preimage =
            CommitmentPreimage({npk: bytes32(uint256(0x3333)), token: _token(), value: VALUE});
        bytes32 commitment = _commitment(preimage);

        Transaction memory t = _buildTxn(UnshieldType.NONE, ownerField, preimage, commitment, true);
        vm.prank(stranger);
        vm.expectRevert("TransactModule: Caller not owner");
        pool.transactOwned(_single(t));
    }

    /// @notice transactOwned with any unshield reverts: the owned circuit carries no
    ///         signature witness, so nothing authorizes paying an arbitrary address.
    function test_transactOwned_withUnshield_reverts() public {
        bytes32 ownerField = bytes32(uint256(uint160(noteOwner)));
        CommitmentPreimage memory preimage =
            CommitmentPreimage({npk: bytes32(uint256(0x3333)), token: _token(), value: VALUE});
        bytes32 commitment = _commitment(preimage);

        Transaction memory t = _buildTxn(UnshieldType.NORMAL, ownerField, preimage, commitment, true);
        vm.prank(noteOwner);
        vm.expectRevert("TransactModule: Unshield not allowed");
        pool.transactOwned(_single(t));
    }

    /// @notice A plain transact that carries a non-zero ownerField reverts. The plain
    ///         circuit (armada-circuits src/main/main_1x2_owned.circom contrasts with
    ///         main_1x2.circom:6, which has no ownerField public input), so a plain proof
    ///         never binds ownerField and the plain path never reads it. A caller must not
    ///         imply an owner the proof did not constrain; owned spends use transactOwned.
    function test_transact_ownerFieldSet_reverts() public {
        CommitmentPreimage memory preimage =
            CommitmentPreimage({npk: bytes32(uint256(0x1111)), token: _token(), value: VALUE});
        bytes32 commitment = _commitment(preimage);

        bytes32 ownerField = bytes32(uint256(uint160(stranger)));
        Transaction memory t = _buildTxn(UnshieldType.NONE, ownerField, preimage, commitment, false);
        vm.expectRevert("TransactModule: Owner field set on plain transact");
        pool.transact(_single(t));
    }

    /// @notice A transactOwned whose plaintext output does not hash to its commitment
    ///         reverts, so the registry can never record an unverified preimage on the
    ///         owned path either.
    function test_transactOwned_publicOutputHashMismatch_reverts() public {
        bytes32 ownerField = bytes32(uint256(uint160(noteOwner)));
        CommitmentPreimage memory honest =
            CommitmentPreimage({npk: bytes32(uint256(0x3333)), token: _token(), value: VALUE});
        bytes32 commitment = _commitment(honest);

        CommitmentPreimage memory tampered =
            CommitmentPreimage({npk: bytes32(uint256(0x4444)), token: _token(), value: VALUE});

        Transaction memory t = _buildTxn(UnshieldType.NONE, ownerField, tampered, commitment, true);
        vm.prank(noteOwner);
        vm.expectRevert("TransactModule: Invalid Public Output");
        pool.transactOwned(_single(t));
    }

    /// @notice Changing ownerField makes the owned spend fail. ownerField is the owned
    ///         circuit's public owner input (main_1x2_owned.circom:6) and transactOwned
    ///         also checks msg.sender against it. A transaction whose ownerField names a
    ///         different address than the caller reverts, so ownerField cannot be swapped.
    function test_transactOwned_differentOwnerField_reverts() public {
        bytes32 ownerField = bytes32(uint256(uint160(stranger)));
        CommitmentPreimage memory preimage =
            CommitmentPreimage({npk: bytes32(uint256(0x3333)), token: _token(), value: VALUE});
        bytes32 commitment = _commitment(preimage);

        Transaction memory t = _buildTxn(UnshieldType.NONE, ownerField, preimage, commitment, true);
        vm.prank(noteOwner);
        vm.expectRevert("TransactModule: Caller not owner");
        pool.transactOwned(_single(t));
    }
}
