// SPDX-License-Identifier: MIT
// ABOUTME: Minimal ERC20Votes token implementing the function surface Baal's vendored
// ABOUTME: core (lib/baal/contracts/Baal.sol) calls on its sharesToken/lootToken: paused,
// ABOUTME: pause, unpause, name, symbol, getVotes, getPastVotes, mint, burn, totalSupply.
// ABOUTME: G1's ArmadaToken cannot fill this role directly — it has no paused()/mint()/
// ABOUTME: burn()/owner(), which lib/baal/contracts/interfaces/IBaalToken.sol and Baal's
// ABOUTME: own setUp/shareManagement calls require (BaalSummoner.sol's own comment on
// ABOUTME: bring-your-own tokens: "tokens need to be baalTokens"). scripts/summon-baal-safe.ts
// ABOUTME: deploys this contract (configured name/symbol "ARM") as Baal's registered
// ABOUTME: shares token, and transfers its ownership to the Baal so only Baal can mint,
// ABOUTME: burn, pause or unpause it. See docs/tasks/G2-baal-safe-summon.md.
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BaalSharesToken is ERC20Votes, Pausable, Ownable {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC20Permit(name_) {}

    /// @notice Baal-only mint (Baal.increaseShares/increaseLoot call this via sharesToken.mint).
    function mint(address recipient, uint256 amount) external onlyOwner {
        _mint(recipient, amount);
    }

    /// @notice Baal-only burn (Baal.decreaseShares/decreaseLoot call this via sharesToken.burn).
    function burn(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }

    /// @notice Baal-only pause (Baal.setShamanLock/sharesPaused toggling calls this).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Baal-only unpause.
    function unpause() external onlyOwner {
        _unpause();
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }
}
