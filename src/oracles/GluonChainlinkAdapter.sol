// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGluonOracle} from "../interfaces/IGluonOracle.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract GluonChainlinkAdapter is IGluonOracle {
    AggregatorV3Interface public immutable dataFeed;
    uint256 public immutable scalingFactor;
    uint256 public immutable maxAge;

    constructor(address _dataFeed, uint256 _maxAge) {
        dataFeed = AggregatorV3Interface(_dataFeed);
        maxAge = _maxAge;
        uint8 decimals = dataFeed.decimals();
        
        if (decimals <= 18) {
            scalingFactor = 10**(18 - decimals);
        } else {
            // For feeds with > 18 decimals, we need to divide, not multiply
            // Store decimals - 18 and handle in getPrice()
            revert("Decimals > 18 not supported");
        }
    }

    function getPrice() external view override returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = dataFeed.latestRoundData();
        require(answer > 0, "Chainlink: price <= 0");
        require(block.timestamp - updatedAt <= maxAge, "Chainlink: Stale price");
        
        return uint256(answer) * scalingFactor;
    }

    function getUpdateFee(bytes[] calldata) external pure override returns (uint256) {
        return 0;
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {
        require(msg.value == 0, "Chainlink: no payment required");
    }
}