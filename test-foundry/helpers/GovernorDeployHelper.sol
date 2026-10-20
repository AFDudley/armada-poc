// ABOUTME: Shared test helper for deploying Governor behind an ERC1967 UUPS proxy.
// ABOUTME: Used by all Foundry test files that need a governor instance.

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../contracts/governance/Governor.sol";

abstract contract GovernorDeployHelper {
    /// @dev Deploy Governor implementation + ERC1967Proxy and return the proxied instance.
    function _deployGovernorProxy(address _armToken, address payable _timelock, address _treasury)
        internal
        returns (Governor)
    {
        Governor impl = new Governor();
        bytes memory initData =
            abi.encodeWithSelector(Governor.initialize.selector, _armToken, _timelock, _treasury);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        Governor governor = Governor(address(proxy));

        // Extended selectors are hardcoded in initialize() — no setup step needed.

        return governor;
    }
}
