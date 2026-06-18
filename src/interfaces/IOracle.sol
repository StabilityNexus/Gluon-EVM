// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// org-wide oracle interface
// values are WAD, implementer handles scaling
interface IOracle {
    // latest value in WAD
    function getValue() external view returns (uint256 value);

    // upper value in WAD
    function getMaxValue() external view returns (uint256 maxValue);

    // lower value in WAD
    function getMinValue() external view returns (uint256 minValue);

    // when value was last updated
    function lastUpdated() external view returns (uint256 timestamp);

    // feed description
    function description() external view returns (string memory);
}
