// SPDX-License-Identifier: MIT
// ABOUTME: Revenue-gated token release contract for team and airdrop ARM allocations.
// ABOUTME: Releases ARM to beneficiaries as the pool's per-asset cumulativeFees milestones are reached.
pragma solidity ^0.8.17;

// Minimal interfaces for cross-contract calls
interface IPoolRevenueLock {
    function cumulativeFees(address asset) external view returns (uint256);
}

interface IArmadaTokenRevenueLock {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function delegateOnBehalf(address delegator, address delegatee) external;
    function transferAndDelegate(address to, uint256 amount, address delegatee) external;
}

/// @title RevenueLock — Revenue-gated token release for team and airdrop ARM
/// @notice Holds ARM for beneficiaries and releases it as the pool's per-asset
///         cumulativeFees milestones are reached. Released ARM is atomically
///         delegated via delegateOnBehalf.
///
///         Entitlements derive from the pool's real per-asset `cumulativeFees(asset)`
///         — a fee-tagged running total the pool itself maintains (P2b) — so every
///         unlock corresponds to real USDC the pool collected, not a free-to-raise
///         attested revenue figure. `cumulativeFees` is monotonic by the pool's own
///         construction (it increases in the same transaction as a fee-tagged note),
///         so no rate-limit ratchet is needed to defend `release()`/`releasable()`
///         (decision 22) — those always read the live, monotonic fee total, frozen
///         or not. The one piece of wind-down bookkeeping kept is a snapshot of the
///         locked (unvested) portion at trigger time (`freezeAtWindDown`/
///         `lockedAtWindDown`): RevenueReserveDistributor's unmodified, already-
///         deployed contract and the redemption contract.s circulating-supply accounting
///         both read a wind-down-frozen state from this contract and cannot be
///         changed here. No admin controls entitlements: `setWindDownContract` only
///         binds the one authorized caller of `freezeAtWindDown`, a deployer-gated
///         one-shot operation that cannot move `cumulativeFees` or anyone's allocation.
contract RevenueLock {
    // ============ Constants ============

    /// @notice Maximum basis points (100%)
    uint256 private constant BPS_100 = 10000;

    /// @notice Unlock-schedule milestones. Revenue thresholds are denominated in
    ///         18-decimal USD to the pool's per-asset cumulativeFees. Each
    ///         tier maps a cumulative-revenue threshold to an unlock percentage in
    ///         basis points (out of `BPS_100`). `_unlockBpsForRevenue` checks tiers
    ///         in descending order and returns the first match.
    uint256 private constant MILESTONE_100PCT_REVENUE_USD = 1_000_000e18;
    uint256 private constant MILESTONE_100PCT_BPS = 10000;
    uint256 private constant MILESTONE_80PCT_REVENUE_USD = 500_000e18;
    uint256 private constant MILESTONE_80PCT_BPS = 8000;
    uint256 private constant MILESTONE_60PCT_REVENUE_USD = 250_000e18;
    uint256 private constant MILESTONE_60PCT_BPS = 6000;
    uint256 private constant MILESTONE_40PCT_REVENUE_USD = 100_000e18;
    uint256 private constant MILESTONE_40PCT_BPS = 4000;
    uint256 private constant MILESTONE_25PCT_REVENUE_USD = 50_000e18;
    uint256 private constant MILESTONE_25PCT_BPS = 2500;
    uint256 private constant MILESTONE_10PCT_REVENUE_USD = 10_000e18;
    uint256 private constant MILESTONE_10PCT_BPS = 1000;

    // ============ Immutable References ============

    /// @notice ARM governance token
    IArmadaTokenRevenueLock public immutable armToken;

    /// @notice Fee pool maintaining the per-asset cumulativeFees total (P2b).
    ///         RevenueLock reads `pool.cumulativeFees(asset)` as its release source
    ///         instead of a free-to-raise attestation.
    IPoolRevenueLock public immutable pool;

    /// @notice The asset (token address) whose cumulativeFees bounds this lock's
    ///         release entitlements — one named asset per P2-CONTRACT item 5.
    address public immutable asset;

    /// @notice Total ARM allocated across all beneficiaries
    uint256 public immutable totalAllocation;

    /// @notice Deployer — gates the one-shot windDown setter so it cannot be
    ///         front-run and permanently bound to a foreign address between this
    ///         contract's deployment and the deployer wiring it.
    address public immutable deployer;

    // ============ State ============

    /// @notice Per-beneficiary total allocation
    mapping(address => uint256) public allocation;

    /// @notice Per-beneficiary cumulative released amount
    mapping(address => uint256) public released;

    /// @notice Ordered list of beneficiaries (for enumeration)
    address[] internal _beneficiaries;

    /// @notice Whether the contract has been verified as fully funded. Releases are
    ///         blocked until activation. Set once via the permissionless `activate()`.
    bool public activated;

    /// @notice Wind-down contract authorized to freeze the locked-portion snapshot
    ///         at trigger time. Set once via setWindDownContract. Cannot move
    ///         cumulativeFees or any beneficiary's allocation/release amount.
    address public windDownContract;
    /// @notice One-time setter lock for windDownContract.
    bool public windDownContractSet;

    /// @notice Whether the locked-portion snapshot has been taken. release()/releasable()
    ///         are NOT gated by this — they always read the live pool.cumulativeFees(asset).
    bool public frozenAtWindDown;

    /// @notice Unlock bps snapshotted at freeze time, for lockedAtWindDown()'s stable
    ///         redemption-window denominator (the redemption contract.s circulatingSupply).
    uint256 public frozenUnlockBps;

    // ============ Events ============

    event Released(address indexed beneficiary, uint256 amount, address delegatee, uint256 cumulativeReleased);

    /// @notice Emitted once when activation succeeds. fundedBalance is the contract's
    ///         ARM balance at activation time (must be >= totalAllocation).
    event Activated(uint256 fundedBalance);

    event WindDownContractSet(address indexed windDownContract);
    event FrozenAtWindDown(uint256 frozenUnlockBps);

    // ============ Constructor ============

    /// @param _armToken ARM token address (must whitelist this contract for transfers)
    /// @param _pool Pool contract maintaining per-asset cumulativeFees
    /// @param _asset Asset whose cumulativeFees bounds release entitlements
    /// @param beneficiaries Array of beneficiary addresses
    /// @param amounts Array of allocation amounts (18-decimal ARM), parallel to beneficiaries
    constructor(
        address _armToken,
        address _pool,
        address _asset,
        address[] memory beneficiaries,
        uint256[] memory amounts
    ) {
        require(_armToken != address(0), "RevenueLock: zero armToken");
        require(_pool != address(0), "RevenueLock: zero pool");
        require(_asset != address(0), "RevenueLock: zero asset");
        require(beneficiaries.length > 0, "RevenueLock: empty beneficiaries");
        require(beneficiaries.length == amounts.length, "RevenueLock: length mismatch");

        armToken = IArmadaTokenRevenueLock(_armToken);
        pool = IPoolRevenueLock(_pool);
        asset = _asset;
        deployer = msg.sender;

        uint256 total;
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            require(beneficiaries[i] != address(0), "RevenueLock: zero beneficiary");
            require(amounts[i] > 0, "RevenueLock: zero amount");
            require(allocation[beneficiaries[i]] == 0, "RevenueLock: duplicate beneficiary");

            allocation[beneficiaries[i]] = amounts[i];
            _beneficiaries.push(beneficiaries[i]);
            total += amounts[i];
        }

        totalAllocation = total;
    }

    // ============ Activation ============

    /// @notice Permissionless: verify the contract holds at least totalAllocation ARM
    ///         and unlock release() for all beneficiaries. One-shot — once activated,
    ///         the gate cannot be re-armed. Must be called after the deployer/governance
    ///         funds the contract and before any beneficiary attempts to release.
    /// @dev Without this gate, partial funding produces order-dependent claims. This
    ///      check fails fast for ALL beneficiaries until funding is fully topped up.
    function activate() external {
        require(!activated, "RevenueLock: already activated");
        uint256 balance = armToken.balanceOf(address(this));
        require(balance >= totalAllocation, "RevenueLock: underfunded");
        activated = true;
        emit Activated(balance);
    }

    // ============ Release ============

    /// @notice Release unlocked ARM to the caller and delegate their voting power.
    /// @param delegatee Address to receive the caller's voting power delegation.
    ///        Self-delegation is valid. Cannot be address(0).
    function release(address delegatee) external {
        require(activated, "RevenueLock: not activated");
        require(delegatee != address(0), "RevenueLock: zero delegatee");
        uint256 alloc = allocation[msg.sender];
        require(alloc > 0, "RevenueLock: not a beneficiary");

        // P2b: entitlement derives from the pool's real per-asset fee total, not from
        // a free-to-raise attested figure. cumulativeFees is monotonic by the pool's
        // own construction (increased in the same tx as a fee-tagged note), so no
        // rate-limit ratchet or wind-down freeze is needed (decision 22).
        uint256 cumulative = pool.cumulativeFees(asset);
        uint256 unlockBps = _unlockBpsForRevenue(cumulative);
        uint256 entitled = (alloc * unlockBps) / BPS_100;
        uint256 alreadyReleased = released[msg.sender];
        uint256 amount = entitled - alreadyReleased;
        require(amount > 0, "RevenueLock: nothing to release");

        // Compute new released into a local first to avoid SLOAD in the emit (audit-76).
        uint256 newReleased = alreadyReleased + amount;
        released[msg.sender] = newReleased;

        // Combined transfer + delegateOnBehalf — atomic by construction, one CALL.
        armToken.transferAndDelegate(msg.sender, amount, delegatee);

        emit Released(msg.sender, amount, delegatee, newReleased);
    }

    // ============ View Functions ============

    /// @notice Amount currently available for a beneficiary to release.
    /// @dev Reads `pool.cumulativeFees(asset)` — the same real per-asset fee total
    ///      that `release()` uses, so this view reflects exactly what `release()`
    ///      would deliver. Callers should prefer this over simulating the logic.
    function releasable(address beneficiary) external view returns (uint256) {
        uint256 alloc = allocation[beneficiary];
        if (alloc == 0) return 0;
        uint256 cumulative = pool.cumulativeFees(asset);
        uint256 entitled = (alloc * _unlockBpsForRevenue(cumulative)) / BPS_100;
        uint256 alreadyReleased = released[beneficiary];
        if (entitled <= alreadyReleased) return 0;
        return entitled - alreadyReleased;
    }

    /// @notice Current unlock percentage in basis points (0 = 0%, 10000 = 100%).
    ///         Step function based on the pool's real per-asset cumulativeFees.
    function unlockPercentage() public view returns (uint256) {
        return _unlockBpsForRevenue(pool.cumulativeFees(asset));
    }

    /// @notice Number of beneficiaries in the list.
    function beneficiaryCount() external view returns (uint256) {
        return _beneficiaries.length;
    }

    // ============ Wind-Down ============

    /// @notice Register the wind-down contract. One-shot setter; locks after the
    ///         first non-zero call. Deployer-only so it cannot be front-run and
    ///         bound to a foreign address.
    function setWindDownContract(address _windDownContract) external {
        require(msg.sender == deployer, "RevenueLock: not deployer");
        require(!windDownContractSet, "RevenueLock: wind-down already set");
        require(_windDownContract != address(0), "RevenueLock: zero windDown");
        windDownContractSet = true;
        windDownContract = _windDownContract;
        emit WindDownContractSet(_windDownContract);
    }

    /// @notice Snapshot the locked (unvested) portion at the current pool fee level.
    ///         Wind-down only; one-shot. Does NOT affect release()/releasable(), which
    ///         always read the live pool.cumulativeFees(asset) — this snapshot exists
    ///         solely so lockedAtWindDown() gives a stable denominator across the
    ///         redemption window (the redemption contract.s circulatingSupply).
    function freezeAtWindDown() external {
        require(msg.sender == windDownContract, "RevenueLock: not wind-down");
        require(!frozenAtWindDown, "RevenueLock: already frozen");

        frozenUnlockBps = _unlockBpsForRevenue(pool.cumulativeFees(asset));
        frozenAtWindDown = true;
        emit FrozenAtWindDown(frozenUnlockBps);
    }

    /// @notice Locked (unvested) ARM portion, used by the redemption contract.s circulatingSupply
    ///         as the non-circulating share of this contract.
    /// @dev Pre-freeze: computed from the live pool.cumulativeFees(asset). Post-freeze:
    ///      uses the bps snapshotted at trigger time, stable across the redemption window.
    function lockedAtWindDown() external view returns (uint256) {
        uint256 unlockBps = frozenAtWindDown ? frozenUnlockBps : _unlockBpsForRevenue(pool.cumulativeFees(asset));
        return totalAllocation - (totalAllocation * unlockBps) / BPS_100;
    }

    // ============ Internal ============

    /// @dev Step function: returns the unlock bps for a given cumulative revenue.
    ///      No interpolation — jumps at each threshold. Revenue is 18-decimal USD;
    ///      the milestone constants above carry the canonical thresholds.
    function _unlockBpsForRevenue(uint256 revenue) internal pure returns (uint256) {
        // Milestones checked in descending order for early return at highest reached
        if (revenue >= MILESTONE_100PCT_REVENUE_USD) return MILESTONE_100PCT_BPS;
        if (revenue >= MILESTONE_80PCT_REVENUE_USD) return MILESTONE_80PCT_BPS;
        if (revenue >= MILESTONE_60PCT_REVENUE_USD) return MILESTONE_60PCT_BPS;
        if (revenue >= MILESTONE_40PCT_REVENUE_USD) return MILESTONE_40PCT_BPS;
        if (revenue >= MILESTONE_25PCT_REVENUE_USD) return MILESTONE_25PCT_BPS;
        if (revenue >= MILESTONE_10PCT_REVENUE_USD) return MILESTONE_10PCT_BPS;
        return 0;
    }
}
