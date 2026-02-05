// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGluonOracle {
    /// @notice Returns the price (WAD) ensuring it is fresh/valid.
    function getPrice() external view returns (uint256);

    /// @notice Calculates the fee required to update the oracle (for Pull Oracles like Pyth).
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    /// @notice Updates the oracle price feeds.
    /// @dev Renamed to match the call in StableCoin.sol
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}