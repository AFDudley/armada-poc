// SPDX-License-Identifier: MIT
// ABOUTME: Baal's loot token for the Armada DAO. The Armada design has no loot: only ARM
// ABOUTME: (ArmadaToken) carries votes and the treasury. Baal still requires a loot token,
// ABOUTME: so this token implements the minimal surface Baal calls on its loot token and its
// ABOUTME: mint reverts unconditionally. The loot total supply is zero at every moment, so no
// ABOUTME: loot holder can ever use Baal's native ragequit to move Safe assets. ARM is the one
// ABOUTME: shares token and ShieldedRagequit is the one exit (lab book decisions 3, 20-21).
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title BaalLootToken — a permanently frozen Baal loot token (zero supply forever)
/// @notice Baal reads lootToken.paused() and lootToken.totalSupply(), and its proposals may
///         call lootToken.mint/burn/pause/unpause. This contract implements exactly that
///         surface. Its mint and burn always revert, so the loot total supply stays zero and
///         Baal's native loot ragequit has nothing to move.
contract BaalLootToken is Ownable {
    string public constant name = "Armada Loot";
    string public constant symbol = "LOOT";

    /// @dev Set only by the Baal owner via pause()/unpause(); it never affects supply.
    bool private _paused;

    /// @notice Baal reads this via totalLoot(); the loot supply is always zero.
    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    /// @notice Baal reads this during setUp and admin config.
    function paused() external view returns (bool) {
        return _paused;
    }

    /// @notice Baal's _mintLoot calls this. It always reverts, so no loot can ever be created
    ///         — not even through a Baal proposal — and no loot holder can use the native
    ///         ragequit to move Safe assets.
    function mint(address, uint256) external pure {
        revert("BaalLootToken: loot is frozen");
    }

    /// @notice Baal's _burnLoot calls this. There is never any loot to burn, so it reverts.
    function burn(address, uint256) external pure {
        revert("BaalLootToken: loot is frozen");
    }

    /// @notice Baal's _setAdminConfig may pause or unpause loot. Owner (Baal) only; the flag
    ///         never affects the supply, which is always zero.
    function pause() external onlyOwner {
        _paused = true;
    }

    function unpause() external onlyOwner {
        _paused = false;
    }
}
