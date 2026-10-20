// ABOUTME: Foundry tests for P2b — fee-tagged outputs and the cumulativeFees running total.
// ABOUTME: The pool itself recognizes an output paid to feeRecipient; no caller flag is trusted.
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../contracts/privacy-pool/PrivacyPool.sol";
import "../contracts/privacy-pool/modules/ShieldModule.sol";
import "../contracts/privacy-pool/modules/TransactModule.sol";
import "../contracts/privacy-pool/modules/MerkleModule.sol";
import "../contracts/privacy-pool/modules/VerifierModule.sol";
import "../contracts/privacy-pool/types/PoolTypes.sol";
import "../contracts/privacy-pool/types/PoseidonLibs.sol";
import "../contracts/cctp/MockUSDCV2.sol";
import "../contracts/cctp/MockCCTPV2.sol";
import "./helpers/PoseidonLinker.sol";

/// @title FeeTaggedOutputsTest — P2b fee recognition and cumulativeFees
/// @dev Runs in testingMode for the transact path (SNARK bypassed) so the test isolates
///      the pool's own fee recognition: an output paid to feeRecipient is counted, and
///      nothing a caller asserts can inflate the counter. The shield path runs for real
///      (real token transfer, shieldFee defaults to 0).
contract FeeTaggedOutputsTest is Test, PoseidonLinker {
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
    bytes32 public feeNpk = bytes32(uint256(0xFEE0));
    bytes32 public otherNpk = bytes32(uint256(0xBEEF));
    bytes32 public thirdNpk = bytes32(uint256(0xCAFE));
    uint120 constant VALUE = 1000;
    uint120 constant VALUE2 = 500;

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
        pool.setTestingMode(true);
        pool.setFeeRecipient(feeNpk);
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _token() internal view returns (TokenData memory) {
        return TokenData({tokenType: TokenType.ERC20, tokenAddress: address(usdc), tokenSubID: 0});
    }

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

    function _emptyShieldCiphertext() internal pure returns (ShieldCiphertext memory) {
        return ShieldCiphertext({encryptedBundle: [bytes32(0), bytes32(0), bytes32(0)], shieldKey: bytes32(0)});
    }

    function _zeroProof() internal pure returns (SnarkProof memory) {
        return SnarkProof({a: G1Point(0, 0), b: G2Point([uint256(0), 0], [uint256(0), 0]), c: G1Point(0, 0)});
    }

    function _shieldNote(bytes32 npk, uint120 value) internal view returns (ShieldRequest[] memory arr) {
        arr = new ShieldRequest[](1);
        arr[0] = ShieldRequest({
            preimage: CommitmentPreimage({npk: npk, token: _token(), value: value}),
            ciphertext: _emptyShieldCiphertext()
        });
    }

    /// @notice A 1x2 plain transact whose two plaintext outputs hash to their commitments.
    function _twoOutputTxn(CommitmentPreimage memory p0, CommitmentPreimage memory p1)
        internal
        view
        returns (Transaction[] memory arr)
    {
        bytes32[] memory nullifiers = new bytes32[](1);
        nullifiers[0] = keccak256(abi.encode("nf", p0.npk, p1.npk, p0.value, p1.value));

        bytes32[] memory commitments = new bytes32[](2);
        commitments[0] = _commitment(p0);
        commitments[1] = _commitment(p1);

        CommitmentPreimage[] memory publicOutputs = new CommitmentPreimage[](2);
        publicOutputs[0] = p0;
        publicOutputs[1] = p1;

        Transaction memory t = Transaction({
            proof: _zeroProof(),
            merkleRoot: pool.merkleRoot(),
            nullifiers: nullifiers,
            commitments: commitments,
            boundParams: BoundParams({
                treeNumber: 0,
                minGasPrice: 0,
                unshield: UnshieldType.NONE,
                chainID: uint64(block.chainid),
                adaptContract: address(0),
                adaptParams: bytes32(0),
                commitmentCiphertext: _emptyCiphertext(2),
                ownerField: bytes32(0),
                publicOutputs: publicOutputs
            }),
            unshieldPreimage: CommitmentPreimage({npk: bytes32(0), token: _token(), value: 0})
        });
        arr = new Transaction[](1);
        arr[0] = t;
    }

    // ── tests ────────────────────────────────────────────────────────────────

    /// @notice A local shield whose note pays feeRecipient increases cumulativeFees by the
    ///         fee-adjusted value; a shield to any other npk does not.
    function test_shield_toFeeRecipient_incrementsCumulativeFees() public {
        usdc.mint(owner, VALUE);
        usdc.approve(address(pool), VALUE);
        pool.shield(_shieldNote(feeNpk, VALUE), address(0));
        assertEq(pool.cumulativeFees(address(usdc)), uint256(VALUE), "fee note counted");

        usdc.mint(owner, VALUE);
        usdc.approve(address(pool), VALUE);
        pool.shield(_shieldNote(otherNpk, VALUE), address(0));
        assertEq(pool.cumulativeFees(address(usdc)), uint256(VALUE), "non-fee note not counted");
    }

    /// @notice A transact with one contract-owned output to feeRecipient increases
    ///         cumulativeFees by that output's value only; a second output to a different
    ///         npk in the same call is not counted.
    function test_transact_feeOutput_countsOnlyFeeRecipient() public {
        CommitmentPreimage memory feeOut = CommitmentPreimage({npk: feeNpk, token: _token(), value: VALUE});
        CommitmentPreimage memory otherOut = CommitmentPreimage({npk: otherNpk, token: _token(), value: VALUE2});

        pool.transact(_twoOutputTxn(feeOut, otherOut));
        assertEq(pool.cumulativeFees(address(usdc)), uint256(VALUE), "only the feeRecipient output counts");
    }

    /// @notice A transaction that creates no feeRecipient-targeted output leaves every
    ///         cumulativeFees entry unchanged — the counter cannot be inflated for free.
    ///         G4's RevenueLock rewrite relies on this.
    function test_cumulativeFees_notInflatedWithoutMatchingOutput() public {
        CommitmentPreimage memory out0 = CommitmentPreimage({npk: otherNpk, token: _token(), value: VALUE});
        CommitmentPreimage memory out1 = CommitmentPreimage({npk: thirdNpk, token: _token(), value: VALUE2});

        pool.transact(_twoOutputTxn(out0, out1));
        assertEq(pool.cumulativeFees(address(usdc)), 0, "no fee output must leave the counter at zero");
    }
}
