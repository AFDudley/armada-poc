// SPDX-License-Identifier: MIT
// ABOUTME: Baal manager shaman — lets any ARM holder exit the treasury alone: burns their ARM
// ABOUTME: and receives, as a contract-owned note at their own npk, exactly burned/totalSupply
// ABOUTME: times the Safe-owned pool note value of each token, paid via PrivacyPool.transactOwned
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
/// @notice Any ARM holder can call ragequit(armAmount, npk, tokens, safeNotes) to burn their ARM and
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
    ///         exactly `armAmount * (Safe-owned pool note value) / armToken.totalSupply()` as a
    ///         contract-owned note at the caller's `npk`. The payout base is the value of the
    ///         Safe-owned pool note of that token, read from the pool's preimage registry, not
    ///         the Safe's public ERC-20 balance. The spend debits that note and returns the
    ///         remainder to the Safe as a change note. No Safe signature, no Baal proposal (S3).
    /// @param armAmount Units of the caller's ARM to burn
    /// @param npk The caller's note public key; the payout note is created at this npk
    /// @param tokens The treasury tokens to receive a pro-rata payout
    /// @param safeNotes The commitment of the Safe-owned pool note spent for each token, in the
    ///        same order as `tokens`. Each must be an unspent Safe-owned note of that token.
    function ragequit(uint256 armAmount, bytes32 npk, address[] calldata tokens, bytes32[] calldata safeNotes)
        external
    {
        // arp-caf: the caller names the Safe-owned pool note it spends per token. The payout
        // base is that note's value, not the Safe's public ERC-20 balance, so a raw transfer
        // straight to the Safe (which credits no note) cannot change the payout.
        require(tokens.length == safeNotes.length, "ShieldedRagequit: notes length mismatch");

        // arp-6cc: capture the pre-burn total supply. The payout divisor is the supply BEFORE
        // this call burns the caller's ARM — reading totalSupply() after the burn would use a
        // smaller supply and inflate the payout.
        uint256 supply = armToken.totalSupply();
        armToken.burn(msg.sender, armAmount);

        uint256[] memory payouts = new uint256[](tokens.length);

        // One contract-owned transaction per listed token: input note = the Safe's pool-owned
        // note (named by its commitment), outputs = the caller's payout note at `npk` plus a
        // change note that returns the remainder to the Safe.
        Transaction[] memory txns = new Transaction[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            // The payout base is the value of the Safe-owned pool note of this token, read from
            // the pool registry (require it to be a Safe-owned note of this token).
            uint256 base = _safeNoteValue(safeNotes[i], tokens[i]);

            // S4: never pay more than burned/pre-burn-supply * the Safe-owned note value. The
            // divisor `supply` is the total supply captured before the burn (one value shared by
            // every listed token in the call).
            uint256 payout = armAmount * base / supply;
            payouts[i] = payout;

            txns[i] = _buildOwnedTxn(tokens[i], npk, safeNotes[i], base, payout);
        }

        // Pay out through the pool's contract-owned spend path (P2a). The caller of
        // transactOwned is this shaman, so the owned proof's ownerField binds to this shaman.
        pool.transactOwned(txns);

        // S9: publish the public record of the holdings change.
        emit RagequitExecuted(msg.sender, armAmount, npk, tokens, payouts);
    }

    // ============ Internals ============

    /// @dev Assembles one contract-owned transaction: input = the Safe's pool-owned note
    ///      (named by `inputCommitment`), outputs = the caller's payout note at `npk` and, when
    ///      the payout is less than the note value, a change note that returns the remainder to
    ///      the Safe. The `ownerField` binds to this shaman (the msg.sender of transactOwned).
    function _buildOwnedTxn(address tokenAddr, bytes32 npk, bytes32 inputCommitment, uint256 base, uint256 payout)
        internal
        view
        returns (Transaction memory)
    {
        TokenData memory tokenData = TokenData({tokenType: TokenType.ERC20, tokenAddress: tokenAddr, tokenSubID: 0});
        bytes32 safeNpk = bytes32(uint256(uint160(address(safe))));

        // The caller's output note at their own npk.
        CommitmentPreimage memory outputNote = CommitmentPreimage({npk: npk, token: tokenData, value: uint120(payout)});

        SnarkProof memory zeroProof = SnarkProof({
            a: G1Point(0, 0), b: G2Point([uint256(0), uint256(0)], [uint256(0), uint256(0)]), c: G1Point(0, 0)
        });

        // ownerField binds the caller of transactOwned (this shaman) to the owned circuit.
        bytes32 ownerField = bytes32(uint256(uint160(address(this))));

        // Nullify the Safe's named input note.
        bytes32[] memory nullifiers = new bytes32[](1);
        nullifiers[0] = keccak256(abi.encode(inputCommitment, "nullifier"));

        // Output set: the payout note, plus a change note to the Safe when payout < base.
        uint256 change = base - payout;
        uint256 outCount = change > 0 ? 2 : 1;

        CommitmentPreimage[] memory publicOutputs = new CommitmentPreimage[](outCount);
        bytes32[] memory commitments = new bytes32[](outCount);
        publicOutputs[0] = outputNote;
        commitments[0] = _hashCommitment(outputNote);
        if (change > 0) {
            CommitmentPreimage memory changeNote =
                CommitmentPreimage({npk: safeNpk, token: tokenData, value: uint120(change)});
            publicOutputs[1] = changeNote;
            commitments[1] = _hashCommitment(changeNote);
        }

        CommitmentCiphertext[] memory ciphertext = new CommitmentCiphertext[](commitments.length);
        for (uint256 j = 0; j < commitments.length; j++) {
            ciphertext[j] = CommitmentCiphertext({
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

    /// @dev Reads the value of the Safe-owned pool note named by `commitment`, the payout base.
    ///      Requires the note to belong to the Safe and to be of `tokenAddr`.
    function _safeNoteValue(bytes32 commitment, address tokenAddr) internal view returns (uint256) {
        (bytes32 noteNpk, TokenData memory noteToken, uint120 noteValue) = pool.preimageOf(commitment);
        require(noteNpk == bytes32(uint256(uint160(address(safe)))), "ShieldedRagequit: note not Safe-owned");
        require(noteToken.tokenAddress == tokenAddr, "ShieldedRagequit: note token mismatch");
        require(noteValue > 0, "ShieldedRagequit: empty Safe note");
        return uint256(noteValue);
    }
}
