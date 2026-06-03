// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGluonOracle} from "../interfaces/IGluonOracle.sol";
import {IPyth, Price} from "../interfaces/IPyth.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract GluonPythAdapter is IGluonOracle {
    IPyth public immutable pyth;
    bytes32 public immutable priceId;
    uint256 public immutable maxAge;

    uint256 constant WAD = 1e18;
    uint32 private constant MAX_PRICE_EXP = 38;

    constructor(address _pyth, bytes32 _priceId, uint256 _maxAge) {
        pyth = IPyth(_pyth);
        priceId = _priceId;
        maxAge = _maxAge;
    }

    function getPrice() external view override returns (uint256) {
        Price memory p = pyth.getPriceNoOlderThan(priceId, maxAge);
        return _pythPriceToWad(p);
    }

    function getUpdateFee(bytes[] calldata updateData) external view override returns (uint256) {
        return pyth.getUpdateFee(updateData);
    }

    function updatePriceFeeds(bytes[] calldata updateData) external payable override {
        uint256 fee = pyth.getUpdateFee(updateData);
        require(msg.value >= fee, "GluonPythAdapter: insufficient fee");
        
        pyth.updatePriceFeeds{value: fee}(updateData);
        
        if (msg.value > fee) {
            (bool success, ) = msg.sender.call{value: msg.value - fee}("");
            require(success, "refund failed");
        }
    }

    function _pythPriceToWad(Price memory price) internal pure returns (uint256) {
        require(price.price > 0, "bad price");
        uint256 unsignedPrice = uint256(uint64(price.price));
        
        if (price.expo >= 0) {
            uint32 exp = uint32(uint32(price.expo));
            require(exp <= MAX_PRICE_EXP, "expo too large");
            uint256 scale = 10**exp;
            return Math.mulDiv(unsignedPrice, scale * WAD, 1);
        } else {
            uint32 exp = uint32(uint32(-price.expo));
            require(exp <= MAX_PRICE_EXP, "expo too large");
            uint256 scale = 10**exp;
            return Math.mulDiv(unsignedPrice, WAD, scale);
        }
    }
}