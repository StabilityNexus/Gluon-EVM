// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library OracleScalingLib {
    function scaleToWad(uint256 value, uint8 valueDecimals) internal pure returns (uint256) {
        if (valueDecimals == 18) {
            return value;
        }
        if (valueDecimals < 18) {
            return value * (10 ** (18 - uint256(valueDecimals)));
        }
        return value / (10 ** (uint256(valueDecimals) - 18));
    }
}
