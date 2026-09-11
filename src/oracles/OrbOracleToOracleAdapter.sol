// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../interfaces/IOracle.sol";
import {OracleScalingLib} from "./OracleScalingLib.sol";

interface OrbOracleInterface {
    function readValue() external view returns (int256);
    function readMaxValue(uint256 sampleSize) external view returns (int256);
    function readMinValue(uint256 sampleSize) external view returns (int256);
    function lastSubmissionTime() external view returns (uint256);
    function description() external view returns (string memory);
}

contract OrbOracleToOracleAdapter is IOracle {
    OrbOracleInterface public immutable feed;
    uint8 public immutable valueDecimals;
    uint256 public immutable sampleSize;

    constructor(address feedParam, uint8 valueDecimalsParam, uint256 sampleSizeParam) {
        require(feedParam != address(0), "invalid feed");
        require(sampleSizeParam > 0, "invalid sample size");

        feed = OrbOracleInterface(feedParam);
        valueDecimals = valueDecimalsParam;
        sampleSize = sampleSizeParam;
    }

    function readValue() public view returns (uint256 value) {
        return _scaleIntToWad(feed.readValue());
    }

    function readMaxValue() external view returns (uint256 maxValue) {
        return _scaleIntToWad(feed.readMaxValue(sampleSize));
    }

    function readMinValue() external view returns (uint256 minValue) {
        return _scaleIntToWad(feed.readMinValue(sampleSize));
    }

    function lastUpdated() external view returns (uint256 timestamp) {
        return feed.lastSubmissionTime();
    }

    function description() external view returns (string memory) {
        return feed.description();
    }

    function _scaleIntToWad(int256 value) internal view returns (uint256) {
        require(value > 0, "bad value");
        // forge-lint: disable-next-line(unsafe-typecast)
        return OracleScalingLib.scaleToWad(uint256(value), valueDecimals);
    }
}
