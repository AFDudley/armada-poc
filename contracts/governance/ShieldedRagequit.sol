// SPDX-License-Identifier: MIT
// ABOUTME: Baal manager shaman — lets any ARM holder exit the treasury alone: burns their ARM
// ABOUTME: and receives, as a contract-owned note at their own npk, exactly burned/totalSupply
// ABOUTME: times the Safe's balance of each listed token, paid via PrivacyPool.transactOwned
// ABOUTME: (P2a) and debited from a Safe-owned pool note. No Safe signature, no quorum.
// ABOUTME: See docs/tasks/G3-shielded-ragequit.md and the G3 check in the armada-laconic
// ABOUTME: labbook 2026-10-18-treasury-governance-baal-safe-shielded.
pragma solidity ^0.8.17;

import {ArmadaToken} from "./ArmadaToken.sol";
import {PrivacyPool} from "../privacy-pool/PrivacyPool.sol";
import {Safe} from "@safe-global/safe-contracts/contracts/Safe.sol";
import {
    CommitmentCiphertext,
    CommitmentPreimage,
    G1Point,
    G2Point,
    SnarkProof,
    Transaction,
    UnshieldType,
    BoundParams,
    TokenData,
    TokenType,
    SNARK_SCALAR_FIELD
} from "../privacy-pool/types/PoolTypes.sol";
import {PoseidonT4} from "../privacy-pool/types/PoseidonLibs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ShieldedRagequit — Baal manager shaman for the shielded treasury exit.
/// @notice Any ARM holder can call ragequit(armAmount, npk, tokens) to burn their ARM and
///         receive a bounded pro-rata payout as a contract-owned note at their own npk. The
///         payout is paid through the pool's contract-owned spend path (transactOwned) and is
///         debited from the Safe's existing pool-owned note. No Safe signature, no Baal
///         proposal.
/// @dev The owner-derived npk (P2-CONTRACT item 6) binds the spent (input) note to the Safe's
///      address, not to ragequit's msg.sender. Every holdings change emits RagequitExecuted.
///      Uses SafeERC20 for every token call (E16 convention).
contract ShieldedRagequit {
    using SafeERC20 for IERC20;

    // ============ Immutables (S1) ============

    ArmadaToken public armToken;
    address public baal;
    Safe public safe;
    PrivacyPool public pool;

    // ============ Events (S3/S9) ============

    /// @notice Public record for every holdings change: the holder, the ARM burned, the
    ///         destination npk, the tokens, and the per-token payouts.
    event RagequitExecuted(address indexed holder, uint256 armBurned, bytes32 npk, address[] tokens, uint256[] payouts);

    // ============ Constructor (S1) ============

    /// @param _armToken G1's ArmadaToken (ARM)
    /// @param _baal G2's Baal (the manager-shaman registrar)
    /// @param _safe G2's Safe (the treasury; assets held as pool-owned notes)
    /// @param _pool P2's PrivacyPool (the contract-owned spend path)
    constructor(address _armToken, address _baal, address _safe, address _pool) {
        armToken = ArmadaToken(_armToken);
        baal = _baal;
        safe = Safe(payable(_safe));
        pool = PrivacyPool(_pool);
    }

    // ============ Ragequit (S2) ============

    /// @notice Burns `armAmount` of the caller's own ARM and, for each listed token, pays
    ///         exactly `armAmount * safe.balanceOf(token) / armToken.totalSupply()` as a
    ///         contract-owned note at the caller's `npk`, debited from the Safe's pool-owned
    ///         note via the pool's transactOwned. Succeeds with no Safe signature and no
    ///         Baal proposal (S3).
    /// @param armAmount Units of the caller's ARM to burn
    /// @param npk The caller's note public key; the payout note is created at this npk
    /// @param tokens The treasury tokens to receive a pro-rata payout
    function ragequit(uint256 armAmount, bytes32 npk, address[] calldata tokens) external {
        // c2: the GOVERNANCE.md bound reads totalSupply() *before* the burn, so the
        // pre-burn supply is the divisor for every listed token in one call.
        uint256 supplyBefore = armToken.totalSupply();

        // c1: burn the caller's ARM via ArmadaToken.burn (callable only by this shaman).
        armToken.burn(msg.sender, armAmount);

        // c4: compute the bounded payout per token from balances read in this same
        // transaction. The bound is `armAmount * safe.balanceOf(token) / totalSupply()`.
        uint256[] memory payouts = new uint256[](tokens.length);

        // One contract-owned transaction per listed token: input note = the Safe's pool-owned
        // note (owner-derived npk), output note = the caller's note at `npk` with the bounded
        // payout.
        Transaction[] memory txns = new Transaction[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            address tokenAddr = tokens[i];
            IERC20 token = IERC20(tokenAddr);
            uint256 safeBal = token.balanceOf(address(safe));
            // S4: never pay more than burned/pre-burn supply * the Safe's balance of this token.
            uint256 payout = armAmount * safeBal / supplyBefore;
            payouts[i] = payout;

            txns[i] = _buildOwnedTxn(tokenAddr, npk, payout);
        }

        // Pay out through the pool's contract-owned spend path (P2a). The caller of
        // transactOwned is this shaman, so the owned proof's ownerField binds to this shaman;
        // the input note's npk is the owner-derived (Safe) key (P2-CONTRACT item 6).
        pool.transactOwned(txns);

        // S9: publish the public record of the holdings change.
        emit RagequitExecuted(msg.sender, armAmount, npk, tokens, payouts);
    }

    // ============ Internals ============

    /// @dev Assembles one contract-owned transaction: input = the Safe's pool-owned note
    ///      (owner-derived npk = Safe address), output = the caller's note at `npk`. The
    ///      `ownerField` binds to this shaman (the msg.sender of transactOwned).
    function _buildOwnedTxn(address tokenAddr, bytes32 npk, uint256 payout) internal view returns (Transaction memory) {
        TokenData memory tokenData = TokenData({tokenType: TokenType.ERC20, tokenAddress: tokenAddr, tokenSubID: 0});

        // The Safe's pool-owned input note (the note the exit debits).
        bytes32 safeNpk = bytes32(uint256(uint160(address(safe))));
        CommitmentPreimage memory inputNote =
            CommitmentPreimage({npk: safeNpk, token: tokenData, value: uint120(payout)});

        // The caller's output note at their own npk.
        CommitmentPreimage memory outputNote = CommitmentPreimage({npk: npk, token: tokenData, value: uint120(payout)});

        SnarkProof memory zeroProof = SnarkProof({
            a: G1Point(0, 0), b: G2Point([uint256(0), uint256(0)], [uint256(0), uint256(0)]), c: G1Point(0, 0)
        });

        // ownerField binds the caller of transactOwned (this shaman) to the owned circuit.
        bytes32 ownerField = bytes32(uint256(uint160(address(this))));

        CommitmentPreimage[] memory publicOutputs = new CommitmentPreimage[](1);
        publicOutputs[0] = outputNote;

        bytes32 outputCommitment = _hashCommitment(outputNote);
        bytes32 inputCommitment = _hashCommitment(inputNote);

        bytes32[] memory nullifiers = new bytes32[](1);
        nullifiers[0] = keccak256(abi.encode(inputCommitment, "nullifier"));

        bytes32[] memory commitments = new bytes32[](1);
        commitments[0] = outputCommitment;

        CommitmentCiphertext[] memory ciphertext = new CommitmentCiphertext[](commitments.length);
        if (commitments.length > 0) {
            ciphertext[0] = CommitmentCiphertext({
                ciphertext: [bytes32(0), bytes32(0), bytes32(0), bytes32(0)],
                blindedSenderViewingKey: bytes32(0),
                blindedReceiverViewingKey: bytes32(0),
                annotationData: bytes(""),
                memo: bytes("")
            });
        }
        return Transaction({
            proof: zeroProof,
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
                commitmentCiphertext: ciphertext,
                ownerField: ownerField,
                publicOutputs: publicOutputs
            }),
            unshieldPreimage: CommitmentPreimage({npk: bytes32(0), token: tokenData, value: 0})
        });
    }

    /// @notice Computes the commitment leaf hash, mirroring TransactModule._hashCommitment.
    /// @dev ERC20 tokens are identified by their address zero-extended to the field element.
    function _hashCommitment(CommitmentPreimage memory note) internal pure returns (bytes32) {
        bytes32 tokenID = note.token.tokenType == TokenType.ERC20
            ? bytes32(uint256(uint160(note.token.tokenAddress)))
            : bytes32(uint256(keccak256(abi.encode(note.token))) % SNARK_SCALAR_FIELD);
        return PoseidonT4.poseidon([note.npk, tokenID, bytes32(uint256(note.value))]);
    }
}
