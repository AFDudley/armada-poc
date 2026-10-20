// ABOUTME: Shared helper that deploys an initialized privacy pool (router + 4 modules + mock CCTP)
// ABOUTME: against the test's USDC, so ArmadaCrowdfund tests can pass a real pool address.

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../../contracts/privacy-pool/PrivacyPool.sol";
import "../../contracts/privacy-pool/modules/ShieldModule.sol";
import "../../contracts/privacy-pool/modules/TransactModule.sol";
import "../../contracts/privacy-pool/modules/MerkleModule.sol";
import "../../contracts/privacy-pool/modules/VerifierModule.sol";
import "../../contracts/cctp/MockCCTPV2.sol";
import "./PoseidonLinker.sol";

abstract contract CrowdfundPoolDeploy is PoseidonLinker {
    /// @notice Deploys a fully-initialized pool + modules + mock CCTP wired to `usdcAddr`.
    /// @dev Enables testing mode (bypasses SNARK proofs) and, when `safeNpk` is non-zero,
    ///      registers it as the pool's feeRecipient (the Safe's owner-derived npk, P2b).
    /// @param usdcAddr The test's USDC address (must match the crowdfund's usdc).
    /// @param treasury The pool's fee treasury (a plain address is fine).
    /// @param owner The pool owner (this test contract).
    /// @param safeNpk The Safe's owner-derived npk to register as feeRecipient (bytes32(0) skips).
    function _deployPool(address usdcAddr, address treasury, address owner, bytes32 safeNpk)
        public
        returns (PrivacyPool pool)
    {
        _linkRealPoseidon();

        // Deploy the pool, its four modules, and the mock CCTP. The two CCTP mocks are
        // built through private helpers so no nested `new` temporaries coexist in the
        // 10-argument initialize call — this avoids a "stack too deep" without via-IR.
        pool = new PrivacyPool();
        pool.initialize(
            address(new ShieldModule()),
            address(new TransactModule()),
            address(new MerkleModule()),
            address(new VerifierModule()),
            _deployTokenMessenger(usdcAddr, owner),
            _deployTransmitter(owner),
            usdcAddr,
            0,
            owner,
            payable(treasury)
        );
        pool.setTestingMode(true);
        if (safeNpk != bytes32(0)) {
            pool.setFeeRecipient(safeNpk);
        }
    }

    /// @dev Deploys a mock CCTP token messenger wrapping its own mock transmitter.
    function _deployTokenMessenger(address usdcAddr, address owner) private returns (address) {
        return address(new MockTokenMessengerV2(_deployTransmitter(owner), usdcAddr, 0));
    }

    /// @dev Deploys a mock CCTP message transmitter.
    function _deployTransmitter(address owner) private returns (address) {
        return address(new MockMessageTransmitterV2(0, owner));
    }
}
