// SPDX-License-Identifier: UNLICENSED
// Licensing information: https://github.com/StabilityNexus/Gluon-EVM
pragma solidity ^0.8.20;

/// @notice Shared compile-time constants for Reactor, Factory and oracle adapter.
/// @dev Addresses, fees, reserve ratios and beta parameters remain deployment-time inputs.
library ProtocolConstants {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q_STAR_WAD = 99e16;
    uint256 internal constant PEGGED_ASSET_WAD = WAD;
    uint256 internal constant UPPER_RESERVE_RATIO = 2e18;
    uint256 internal constant PEG_FACTOR_SCALE = 1e36;
    uint256 internal constant PEG_DOWN_FACTOR_WAD = 99e16;
    uint256 internal constant PEG_UP_FACTOR_WAD = 101e16;
    uint256 internal constant WAD_DECIMALS = 18;
    uint256 internal constant ORACLE_PRICE_DECIMALS = WAD_DECIMALS;
}
