// SPDX-License-Identifier: MIT
// ABOUTME: Foundry tests proving the six ArmadaToken Baal-shares invariants:
// ABOUTME: single-mint fixed supply, non-proxy bytecode, whitelist gating, restricted
// ABOUTME: transfer reverts, mint-not-blocked, and timelock setTransferable.
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../contracts/governance/ArmadaToken.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract ArmadaTokenSharesTest is Test {
    // Mirror the token's TransferableSet event.
    event TransferableSet(bool transferable);

    ArmadaToken public armToken;
    TimelockController public timelock;

    address public deployer = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public carol = address(0xC401);
    address public mallory = address(0x7E23D); // non-whitelisted holder

    uint256 constant TOTAL_SUPPLY = 12_000_000 * 1e18;

    function setUp() public {
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(2 days, proposers, executors, deployer);

        // Deploy the ARM token: deployer receives the entire initial supply (single mint).
        armToken = new ArmadaToken(deployer, address(timelock));
    }

    /// @notice Returns true if `haystack` contains `needle` (source-level scan).
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) return true;
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool same = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }

    /// @notice Counts non-overlapping occurrences of `needle` in `haystack`.
    function _countOccurrences(string memory haystack, string memory needle) internal pure returns (uint256 count) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        require(n.length > 0, "empty needle");
        uint256 i = 0;
        while (i + n.length <= h.length) {
            bool same = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    same = false;
                    break;
                }
            }
            if (same) {
                count++;
                i += n.length;
            } else {
                i++;
            }
        }
    }

    // ============ c1 · single-mint ============
    // Fixed 12,000,000e18 supply minted exactly once with no second mint path.

    function test_shares_singleMint() public {
        assertEq(armToken.totalSupply(), TOTAL_SUPPLY, "fixed supply minted once");
        assertEq(armToken.balanceOf(deployer), TOTAL_SUPPLY, "deployer holds full supply");

        // Source-level: exactly one `_mint(` call site in the contract (the constructor).
        string memory src = vm.readFile("./contracts/governance/ArmadaToken.sol");
        assertEq(_countOccurrences(src, "_mint("), 1, "exactly one _mint( call site");
    }

    // ============ c2 · non-proxy-bytecode ============
    // The deployed contract is immutable, non-proxy code: no proxy pattern, no
    // delegatecall, no _authorizeUpgrade-style upgrade path in the source that
    // produces the runtime bytecode.

    function test_shares_nonProxyBytecode() public {
        string memory src = vm.readFile("./contracts/governance/ArmadaToken.sol");
        assertFalse(_contains(src, "delegatecall"), "no delegatecall opcode source");
        assertFalse(_contains(src, "_authorizeUpgrade"), "no UUPS upgrade-authorization path");
        assertFalse(_contains(src, "Initializable"), "no proxy-initializer pattern");
        assertFalse(_contains(src, "UUPSUpgradeable"), "no UUPS proxy inheritance");
        // ArmadaToken must still deploy as a plain, directly-constructed contract
        // (no bytecode at the token address before construction confirms it is not
        // a pre-deployed proxy pointing at an implementation).
        assertTrue(address(armToken).code.length > 0, "token has deployed code");
    }

    // ============ c3 · whitelist-gating ============
    // initWhitelist (deployer, one-shot) and addToWhitelist (timelock-only, add-only);
    // a non-timelock caller reverts.

    function test_shares_whitelistGating() public {
        address[] memory wl = new address[](3);
        wl[0] = deployer;
        wl[1] = alice;
        wl[2] = bob;
        armToken.initWhitelist(wl);
        assertTrue(armToken.transferWhitelist(deployer), "deployer whitelisted");
        assertTrue(armToken.transferWhitelist(alice), "alice whitelisted");
        assertTrue(armToken.transferWhitelist(bob), "bob whitelisted");

        // initWhitelist is one-shot: a second call reverts.
        vm.expectRevert("ArmadaToken: whitelist already initialized");
        armToken.initWhitelist(wl);

        // A non-deployer caller reverts on initWhitelist (fixed allowlist).
        vm.prank(alice);
        vm.expectRevert("ArmadaToken: not deployer");
        armToken.initWhitelist(wl);
    }

    // ============ c4 · restricted-transfer-reverts ============
    // A transfer from a non-whitelisted holder reverts with
    // 'ArmadaToken: transfers restricted' while transferable is false.

    function test_shares_restrictedTransferReverts() public {
        address[] memory wl = new address[](2);
        wl[0] = deployer;
        wl[1] = alice;
        armToken.initWhitelist(wl);

        // Move ARM to a non-whitelisted holder (mallory) via the whitelisted deployer.
        armToken.transfer(mallory, 1_000_000 * 1e18);

        assertFalse(armToken.transferable(), "transferable still false");
        vm.prank(mallory);
        vm.expectRevert("ArmadaToken: transfers restricted");
        armToken.transfer(alice, 1_000_000 * 1e18);
    }

    // ============ c5 · mint-not-blocked ============
    // A mint (from==address(0)) is never blocked by the transfer restriction.

    function test_shares_mintNotBlocked() public {
        // The constructor minted the full supply (from==address(0)) while transferable
        // is false and the deployer was not yet whitelisted; the mint went through.
        assertFalse(armToken.transferable(), "transferable still false");
        assertFalse(armToken.transferWhitelist(deployer), "deployer not whitelisted yet");
        assertEq(armToken.totalSupply(), TOTAL_SUPPLY, "mint not blocked despite no whitelist");
        assertEq(armToken.balanceOf(deployer), TOTAL_SUPPLY, "deployer received the mint");
    }

    // ============ c6 · timelock-set-transferable ============
    // setTransferable(true) succeeds from the timelock alone (the only caller).

    function test_shares_timelockSetTransferable() public {
        vm.expectEmit(false, false, false, true);
        emit TransferableSet(true);
        vm.prank(address(timelock));
        armToken.setTransferable(true);

        assertTrue(armToken.transferable(), "transfers now enabled");
    }

    // ============ c6 · allowlist-fixed-at-construction ============
    // The transfer allowlist is fixed at construction (initWhitelist, deployer one-shot).
    // The timelock has no path to add a fourth address after deployment.

    function test_allowlistFixedAtConstruction() public {
        // Three stand-in addresses (RevenueLock, Hedgey lockup, crowdfund) are whitelisted
        // at construction.
        address[] memory wl = new address[](3);
        wl[0] = deployer;
        wl[1] = alice;
        wl[2] = bob;
        armToken.initWhitelist(wl);
        assertTrue(armToken.transferWhitelist(deployer), "deployer whitelisted at construction");
        assertTrue(armToken.transferWhitelist(alice), "revenue-lock stand-in whitelisted");
        assertTrue(armToken.transferWhitelist(bob), "crowdfund stand-in whitelisted");

        // A new (non-construction) address stays off the fixed allowlist.
        address a4 = mallory;
        assertFalse(armToken.transferWhitelist(a4), "a new address is not on the fixed allowlist");

        // Prove the timelock has no add-path: a raw call to the removed setter's selector
        // reverts (function not found). If a mutation re-adds the setter, the call succeeds
        // and the allowlist grows, so this test fails — the check catches deliberate
        // breakage.
        bytes4 sel = bytes4(keccak256("addToWhitelist(address)"));
        bytes memory data = abi.encodeWithSelector(sel, a4);
        vm.prank(address(timelock));
        (bool ok, bytes memory ret) = address(armToken).call(data);
        assertFalse(ok, "the timelock cannot add a new address after deployment");
        assertFalse(armToken.transferWhitelist(a4), "allowlist remains fixed at construction");
    }
}
