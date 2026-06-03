// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGluonOracle} from "../interfaces/IGluonOracle.sol";

interface IOrbPriceFeed {
    function getPrice() external view returns (uint256);
    function decimals() external view returns (uint8);
    function updatedAt() external view returns (uint256);
}

contract GluonOrbAdapter is IGluonOracle {
    IOrbPriceFeed public immutable orbFeed;
    uint256 public immutable scalingFactor;
    uint256 public immutable maxAge;

    constructor(address _orbFeed, uint256 _maxAge) {
        orbFeed = IOrbPriceFeed(_orbFeed);
        maxAge = _maxAge;
        
        uint8 decimals = orbFeed.decimals();
        if (decimals < 18) {
            scalingFactor = 10**(18 - decimals);
        } else {
            scalingFactor = 1;
        }
    }

    function getPrice() external view override returns (uint256) {
        uint256 price = orbFeed.getPrice();
        require(price > 0, "Orb: price <= 0");
        
        uint256 updatedAt = orbFeed.updatedAt();
        require(block.timestamp - updatedAt <= maxAge, "Orb: Stale price");
        
        return price * scalingFactor;
    }

    function getUpdateFee(bytes[] calldata) external pure override returns (uint256) {
        return 0;
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {
        // No-op for Orb
    }
}
