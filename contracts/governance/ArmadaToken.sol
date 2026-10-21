// SPDX-License-Identifier: MIT
// ABOUTME: ARM governance token with ERC20Votes for on-chain delegation and voting checkpoints.
// ABOUTME: Transfer-restricted until the timelock opens transfers; treasury address blocked from delegation.
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ArmadaToken — ARM governance token with delegation and transfer restrictions
/// @notice ERC20Votes provides Compound-style delegation and voting power checkpoints.
///         Tokens have zero voting power until delegated. Transfer-restricted until the
///         timelock enables free transfers via setTransferable(true).
contract ArmadaToken is ERC20Votes {
    uint256 public constant INITIAL_SUPPLY = 12_000_000 * 1e18; // 12M ARM

    // ============ Immutable References ============

    address public immutable timelock;
    address public immutable tokenDeployer;

    // ============ Packed Flag/Address Slot ============
    // Pack 5 bools + address into one slot (audit-68): 5 + 20 = 25 bytes. Declared
    // ahead of the mappings so the small fields stay contiguous; mapping slots
    // (one each, hash-derived storage location) are unaffected by ordering.
    /// @notice When false, only whitelisted senders can transfer. Starts false.
    bool public transferable;
    /// @notice Whitelist init lock (one-shot deployer setter).
    bool public whitelistInitialized;
    /// @notice noDelegation init lock (one-shot deployer setter).
    bool public noDelegationSet;
    /// @notice authorizedDelegator init lock (one-shot deployer setter).
    bool public authorizedDelegatorsInitialized;

    // ============ Transfer Restriction State ============

    /// @notice Addresses exempt from transfer restrictions (add-only, no removal).
    mapping(address => bool) public transferWhitelist;

    // ============ Delegation Restriction State ============

    /// @notice Addresses blocked from delegating (e.g. treasury). Their ARM never enters
    ///         the voting power denominator.
    mapping(address => bool) public noDelegation;

    // ============ Authorized Delegator State ============

    /// @notice Contracts authorized to call delegateOnBehalf (e.g. RevenueLock, Crowdfund).
    mapping(address => bool) public authorizedDelegator;

    // ============ Authorized Burner State ============

    /// @notice The G3 burn gate: addresses authorized to call burn. The deployer registers
    ///          ShieldedRagequit one-shot via initBurners. After that, the set is frozen; no
    ///          address (the timelock/Safe included) can add a burner (E5, "No clawback").
    mapping(address => bool) public authorizedBurner;
    /// @notice One-shot deployer lock for the authorizedBurner registry.
    bool public burnersInitialized;

    // ============ Events ============

    event WhitelistRemoved(address indexed account);
    event WhitelistInitialized(address[] accounts);
    event TransferableSet(bool transferable);
    event NoDelegationInitialized(address[] accounts);
    event AuthorizedDelegatorsInitialized(address[] delegators);
    event AuthorizedDelegatorAdded(address indexed delegator);
    event BurnersInitialized(address[] burners);

    // ============ Constructor ============

    /// @param initialHolder Address that receives the entire initial supply
    /// @param _timelock TimelockController address (the governance gate on the token)
    constructor(address initialHolder, address _timelock) ERC20("Armada", "ARM") ERC20Permit("Armada") {
        require(initialHolder != address(0), "ArmadaToken: zero initialHolder");
        require(_timelock != address(0), "ArmadaToken: zero timelock");
        timelock = _timelock;
        tokenDeployer = msg.sender;
        _mint(initialHolder, INITIAL_SUPPLY);
    }

    // ============ One-Time Setup (deployer-only, pre-renounce) ============

    /// @notice Set initial whitelist addresses. Callable once by deployer.
    ///         Matches the deployer-gated one-shot setter pattern.
    function initWhitelist(address[] calldata accounts) external {
        require(msg.sender == tokenDeployer, "ArmadaToken: not deployer");
        require(!whitelistInitialized, "ArmadaToken: whitelist already initialized");
        whitelistInitialized = true;
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "ArmadaToken: zero address");
            transferWhitelist[accounts[i]] = true;
        }
        emit WhitelistInitialized(accounts);
    }

    /// @notice Set addresses blocked from delegation (e.g. treasury). Callable once by deployer.
    ///         Follows the same one-time array pattern as initWhitelist and initAuthorizedDelegators.
    function initNoDelegation(address[] calldata accounts) external {
        require(msg.sender == tokenDeployer, "ArmadaToken: not deployer");
        require(!noDelegationSet, "ArmadaToken: noDelegation already set");
        noDelegationSet = true;
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "ArmadaToken: zero address");
            noDelegation[accounts[i]] = true;
        }
        emit NoDelegationInitialized(accounts);
    }

    /// @notice Set contracts authorized to call delegateOnBehalf. Callable once by deployer.
    ///         Follows the same one-time pattern as initWhitelist.
    function initAuthorizedDelegators(address[] calldata delegators) external {
        require(msg.sender == tokenDeployer, "ArmadaToken: not deployer");
        require(!authorizedDelegatorsInitialized, "ArmadaToken: delegators already initialized");
        authorizedDelegatorsInitialized = true;
        for (uint256 i = 0; i < delegators.length; i++) {
            require(delegators[i] != address(0), "ArmadaToken: zero address");
            authorizedDelegator[delegators[i]] = true;
        }
        emit AuthorizedDelegatorsInitialized(delegators);
    }

    // ============ Governance Functions ============

    /// @notice Authorize a contract to call delegateOnBehalf. Timelock-only, add-only (no removal).
    ///         Mirrors the initWhitelist construction-allowlist pattern to let governance authorize
    ///         new delegators (e.g. follow-on RevenueLock cohorts or replacement Crowdfund instances)
    ///         after deployment without requiring token redeployment.
    function addAuthorizedDelegator(address delegator) external {
        require(msg.sender == timelock, "ArmadaToken: not timelock");
        require(delegator != address(0), "ArmadaToken: zero address");
        if (authorizedDelegator[delegator]) return;
        authorizedDelegator[delegator] = true;
        emit AuthorizedDelegatorAdded(delegator);
    }

    /// @notice Register the addresses authorized to call burn (G3). Deployer-only, one-shot.
    ///         Mirrors the one-shot authorized-caller pattern of addAuthorizedDelegator; only
    ///         ShieldedRagequit may be registered as the sole authorized burner.
    function initBurners(address[] calldata burners) external {
        require(msg.sender == tokenDeployer, "ArmadaToken: not deployer");
        require(!burnersInitialized, "ArmadaToken: burners already initialized");
        for (uint256 i = 0; i < burners.length; i++) {
            require(burners[i] != address(0), "ArmadaToken: zero address");
            authorizedBurner[burners[i]] = true;
        }
        burnersInitialized = true;
        emit BurnersInitialized(burners);
    }

    /// @notice IBaalToken `burn` entry point (G3): destroys `amount` of `account`'s ARM.
    ///         Only callable by an authorized burner (the ShieldedRagequit shaman); any other
    ///         caller reverts, including a call from the Baal. Baal's native ragequit calls
    ///         sharesToken.burn, so it reverts for ARM and cannot move ARM or Safe assets —
    ///         ShieldedRagequit stays the one exit (lab book decisions 20-21).
    function burn(address account, uint256 amount) external {
        require(authorizedBurner[msg.sender], "ArmadaToken: not authorized burner");
        require(account != address(0), "ArmadaToken: zero address");
        _burn(account, amount);
    }

    /// @notice ARM has a fixed supply minted once in the constructor; there is no later mint
    ///         path. This public mint always reverts, so a Baal mintShares proposal that calls
    ///         sharesToken.mint cannot inflate ARM (lab book decision 3).
    function mint(address, uint256) external pure {
        revert("ArmadaToken: minting disabled");
    }

    /// @notice Baal reads sharesToken.paused() during setUp and admin config. ARM is never
    ///         Baal-pausable; its transfer control is the allowlist, so this is always false.
    function paused() external pure returns (bool) {
        return false;
    }

    /// @notice ARM measures vote time by block TIMESTAMP, not block number (ERC-6372). Baal
    ///         reads getPastVotes(voter, prop.votingStarts) where votingStarts is a block
    ///         timestamp, so the vote checkpoints must be timestamp-keyed.
    function clock() public view override returns (uint48) {
        return SafeCast.toUint48(block.timestamp);
    }

    /// @notice ERC-6372 machine-readable clock mode. Must agree with clock().
    function CLOCK_MODE() public view override returns (string memory) {
        require(clock() == block.timestamp, "ArmadaToken: broken clock mode");
        return "mode=timestamp";
    }

    /// @notice Remove the deployer from the transfer whitelist. Deployer-only, callable once.
    ///         The deployer is whitelisted during deployment to distribute ARM tokens.
    ///         After distribution completes and the deployer holds 0 ARM, this removes the
    ///         residual whitelist entry to eliminate the deployer as a transfer-capable address.
    function removeDeployerFromWhitelist() external {
        require(msg.sender == tokenDeployer, "ArmadaToken: not deployer");
        require(transferWhitelist[tokenDeployer], "ArmadaToken: deployer not whitelisted");
        transferWhitelist[tokenDeployer] = false;
        emit WhitelistRemoved(tokenDeployer);
    }

    /// @notice Enable unrestricted transfers. Callable only by the timelock via governance
    ///         proposal.
    ///         One-way: transfers cannot be re-restricted once enabled.
    function setTransferable(bool _transferable) external {
        require(msg.sender == timelock, "ArmadaToken: not authorized");
        require(_transferable, "ArmadaToken: can only enable transfers");
        require(!transferable, "ArmadaToken: transfers already enabled");
        transferable = true;
        emit TransferableSet(true);
    }

    /// @notice Delegate voting power on behalf of another address. Only callable by
    ///         authorized contracts (e.g. RevenueLock, Crowdfund) for atomic transfer+delegation.
    /// @param delegator The address whose voting power is being delegated
    /// @param delegatee The address to receive the voting power
    function delegateOnBehalf(address delegator, address delegatee) external {
        require(authorizedDelegator[msg.sender], "ArmadaToken: not authorized delegator");
        _delegate(delegator, delegatee);
    }

    /// @notice Combined transfer + delegateOnBehalf for atomic credit + delegation.
    ///         Replaces the paired (transfer, delegateOnBehalf) sequence in
    ///         RevenueLock.release and ArmadaCrowdfund.claim. Restricted to authorized
    ///         delegators (the same gate as delegateOnBehalf), since the underlying
    ///         delegation step is privileged.
    /// @param to Recipient of the ARM transfer (also the delegator whose voting power moves)
    /// @param amount ARM amount to transfer from msg.sender to `to`
    /// @param delegatee Address to delegate `to`'s voting power to
    function transferAndDelegate(address to, uint256 amount, address delegatee) external {
        require(authorizedDelegator[msg.sender], "ArmadaToken: not authorized delegator");
        _transfer(msg.sender, to, amount);
        _delegate(to, delegatee);
    }

    /// @notice Helper for redemption denominator math: returns totalSupply minus the
    ///         sum of balanceOf(excluded[i]). Collapses the (1 totalSupply + N balanceOf)
    ///         multi-call pattern in the redemption circulating-supply math to a single CALL.
    /// @param excluded Addresses whose ARM is non-circulating (treasury, redemption contract, etc.)
    function circulatingSupplyOf(address[] calldata excluded) external view returns (uint256 result) {
        result = totalSupply();
        for (uint256 i; i < excluded.length; i++) {
            result -= balanceOf(excluded[i]);
        }
    }

    // ============ Transfer Restriction ============

    /// @dev When transferable is false:
    ///      - the exit path (burn: to == address(0)) is open for every holder, so a captured
    ///        majority that keeps ARM transfers locked cannot block ragequit (E1).
    ///      - ordinary transfers (to != address(0)) stay restricted to whitelisted senders
    ///        (or mints from == address(0)).
    ///      Burns reach _burn only through burn(account, amount), which is authorized-burner
    ///      only, so opening to == address(0) creates no public burn path.
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);
        if (!transferable && to != address(0)) {
            require(from == address(0) || transferWhitelist[from], "ArmadaToken: transfers restricted");
        }
    }

    // ============ Delegation Restriction ============

    /// @dev Block delegation for addresses in the noDelegation set (e.g. treasury).
    ///      Overrides the internal _delegate which is called by both delegate() and delegateBySig().
    function _delegate(address delegator, address delegatee) internal override {
        require(!noDelegation[delegator], "ArmadaToken: delegation blocked");
        super._delegate(delegator, delegatee);
    }
}
