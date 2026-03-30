// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IPyth, Price} from "../../src/interfaces/IPyth.sol";

contract MockPyth is IPyth {
    Price internal currentPrice;
    uint256 internal updateFee;

    function setPrice(int64 price_, int32 expo_, uint256 publishTime_) external {
        currentPrice = Price({price: price_, conf: 0, expo: expo_, publishTime: publishTime_});
    }

    function setUpdateFee(uint256 fee_) external {
        updateFee = fee_;
    }

    function getValidTimePeriod() external pure returns (uint256 validTimePeriod) {
        return type(uint256).max;
    }

    function getPrice(bytes32) external view returns (Price memory price) {
        return currentPrice;
    }

    function getEmaPrice(bytes32) external view returns (Price memory price) {
        return currentPrice;
    }

    function getPriceUnsafe(bytes32) external view returns (Price memory price) {
        return currentPrice;
    }

    function getPriceNoOlderThan(bytes32, uint256 age) external view returns (Price memory price) {
        require(currentPrice.publishTime + age >= block.timestamp, "stale");
        return currentPrice;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {}

    function updatePriceFeedsIfNecessary(bytes[] calldata, bytes32[] calldata, uint64[] calldata) external payable {}

    function getUpdateFee(bytes[] calldata) external view returns (uint256 feeAmount) {
        return updateFee;
    }
}
