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
    error InvalidFeed();
    error BadValue();
    AggregatorV3Interface public immutable feed;

    constructor(address feedParam) {
        if (feedParam == address(0)) revert InvalidFeed();
        feed = AggregatorV3Interface(feedParam);
    }

    // reads chainlink answer and scales to WAD
    function readValue() public view returns (uint256 value) {
        (, int256 answer,,,) = feed.latestRoundData();
        if (answer <= 0) revert BadValue();
        // casting is safe because answer > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        return OracleScalingLib.scaleToWad(uint256(answer), feed.decimals());
    }

    // Chainlink provides one value, so min and max are equal
    function readValueInterval() external view returns (uint256 minValue, uint256 maxValue) {
        uint256 value = readValue();
        return (value, value);
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
