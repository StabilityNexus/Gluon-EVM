// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../interfaces/IOracle.sol";

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
    function getValue() public view returns (uint256 value) {
        (, int256 answer,,,) = feed.latestRoundData();
        require(answer > 0, "bad value");
        // casting is safe because answer > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        return _scaleToWad(uint256(answer), feed.decimals());
    }

    // chainlink has single value, so min = max = value
    function getMaxValue() external view returns (uint256 maxValue) {
        return getValue();
    }

    function getMinValue() external view returns (uint256 minValue) {
        return getValue();
    }

    // last update timestamp from chainlink
    function lastUpdated() external view returns (uint256 timestamp) {
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        return updatedAt;
    }

    function description() external view returns (string memory) {
        return feed.description();
    }

    // scale native decimals to WAD (1e18)
    function _scaleToWad(uint256 value, uint8 valueDecimals) internal pure returns (uint256) {
        if (valueDecimals == 18) {
            return value;
        }
        if (valueDecimals < 18) {
            return value * (10 ** (18 - uint256(valueDecimals)));
        }
        return value / (10 ** (uint256(valueDecimals) - 18));
    }
}
