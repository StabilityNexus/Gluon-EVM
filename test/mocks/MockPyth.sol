// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPyth, Price} from "../../src/interfaces/IPyth.sol";

/// @dev Minimal mock of the Pyth oracle for testing.
contract MockPyth is IPyth {
    mapping(bytes32 => Price) private _prices;
    uint256 private _updateFee;

    constructor(uint256 updateFee_) {
        _updateFee = updateFee_;
    }

    function setPrice(bytes32 id, int64 price, int32 expo, uint64 conf) external {
        _prices[id] = Price({
            price: price,
            conf: conf,
            expo: expo,
            publishTime: block.timestamp
        });
    }

    function getValidTimePeriod() external pure returns (uint) {
        return 60;
    }

    function getPrice(bytes32 id) external view returns (Price memory) {
        return _prices[id];
    }

    function getEmaPrice(bytes32 id) external view returns (Price memory) {
        return _prices[id];
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory) {
        return _prices[id];
    }

    function getPriceNoOlderThan(bytes32 id, uint) external view returns (Price memory) {
        return _prices[id];
    }

    function updatePriceFeeds(bytes[] calldata) external payable {}

    function updatePriceFeedsIfNecessary(
        bytes[] calldata,
        bytes32[] calldata,
        uint64[] calldata
    ) external payable {}

    function getUpdateFee(bytes[] calldata) external view returns (uint) {
        return _updateFee;
    }
}