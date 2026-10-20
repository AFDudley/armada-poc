// ABOUTME: Shared interface for the adapter registry used by the privacy pool and shield module.
// ABOUTME: Defines IAdapterRegistry (authorized / withdraw-only adapters).

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title IArmadaGovernance — adapter registry interface

interface IAdapterRegistry {
    function authorizedAdapters(address adapter) external view returns (bool);
    function withdrawOnlyAdapters(address adapter) external view returns (bool);
}
