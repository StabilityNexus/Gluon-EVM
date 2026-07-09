// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../interfaces/IOracle.sol";
import {OracleScalingLib} from "./OracleScalingLib.sol";

// minimal chainlink interface, only what we need
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

// wraps a chainlink feed and exposes it as IOracle
contract ChainlinkToOracleAdapter is IOracle {
    AggregatorV3Interface public immutable feed;

    constructor(address feedParam) {
        require(feedParam != address(0), "invalid feed");
        feed = AggregatorV3Interface(feedParam);
    }

    // reads chainlink answer and scales to WAD
    function readValue() public view returns (uint256 value) {
        (, int256 answer,,,) = feed.latestRoundData();
        require(answer > 0, "bad value");
        // casting is safe because answer > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        return OracleScalingLib.scaleToWad(uint256(answer), feed.decimals());
    }

    // chainlink has single value, so min = max = value
    function readMaxValue() external view returns (uint256 maxValue) {
        return readValue();
    }

    function readMinValue() external view returns (uint256 minValue) {
        return readValue();
    }

    // last update timestamp from chainlink
    function lastUpdated() external view returns (uint256 timestamp) {
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        return updatedAt;
    }

    function description() external view returns (string memory) {
        return feed.description();
    }
}
