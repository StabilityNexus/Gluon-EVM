// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OrbOracleToOracleAdapter} from "../src/oracles/OrbOracleToOracleAdapter.sol";

contract MockOrbOracle {
    int256 public valueVal;
    int256 public maxVal;
    int256 public minVal;
    uint256 public lastSubmissionTimeVal;
    uint256 public expectedSampleSize;
    string private descriptionVal;

    constructor(int256 value_, int256 max_, int256 min_, uint256 sampleSize_, string memory description_) {
        valueVal = value_;
        maxVal = max_;
        minVal = min_;
        expectedSampleSize = sampleSize_;
        descriptionVal = description_;
        lastSubmissionTimeVal = block.timestamp;
    }

    function readValue() external view returns (int256) {
        return valueVal;
    }

    function readMaxValue(uint256 sampleSize) external view returns (int256) {
        require(sampleSize == expectedSampleSize, "wrong sample size");
        return maxVal;
    }

    function readMinValue(uint256 sampleSize) external view returns (int256) {
        require(sampleSize == expectedSampleSize, "wrong sample size");
        return minVal;
    }

    function lastSubmissionTime() external view returns (uint256) {
        return lastSubmissionTimeVal;
    }

    function description() external view returns (string memory) {
        return descriptionVal;
    }
}

contract OrbOracleAdapterTest is Test {
    function testScalesEightDecimalsToWad() public {
        MockOrbOracle feed = new MockOrbOracle(3000 * 1e8, 3100 * 1e8, 2900 * 1e8, 3, "ORB / USD");
        OrbOracleToOracleAdapter adapter = new OrbOracleToOracleAdapter(address(feed), 8, 3);

        assertEq(adapter.readValue(), 3000 * 1e18, "8 dec scaling failed");
    }

    function testSupportsEighteenDecimals() public {
        MockOrbOracle feed = new MockOrbOracle(2000 * 1e18, 2100 * 1e18, 1900 * 1e18, 3, "ORB / USD");
        OrbOracleToOracleAdapter adapter = new OrbOracleToOracleAdapter(address(feed), 18, 3);

        assertEq(adapter.readValue(), 2000 * 1e18, "18 dec scaling failed");
    }

    function testSupportsMoreThanEighteenDecimals() public {
        MockOrbOracle feed = new MockOrbOracle(2000 * 1e20, 2100 * 1e20, 1900 * 1e20, 3, "ORB / USD");
        OrbOracleToOracleAdapter adapter = new OrbOracleToOracleAdapter(address(feed), 20, 3);

        assertEq(adapter.readValue(), 2000 * 1e18, "20 dec scaling failed");
    }

    function testMinAndMaxUseSampleSize() public {
        MockOrbOracle feed = new MockOrbOracle(3000 * 1e8, 3200 * 1e8, 2800 * 1e8, 5, "ORB / USD");
        OrbOracleToOracleAdapter adapter = new OrbOracleToOracleAdapter(address(feed), 8, 5);

        assertEq(adapter.readMaxValue(), 3200 * 1e18, "wrong max value");
        assertEq(adapter.readMinValue(), 2800 * 1e18, "wrong min value");
    }

    function testLastUpdatedReturnsSubmissionTime() public {
        MockOrbOracle feed = new MockOrbOracle(100 * 1e8, 110 * 1e8, 90 * 1e8, 3, "ORB / USD");
        OrbOracleToOracleAdapter adapter = new OrbOracleToOracleAdapter(address(feed), 8, 3);

        assertEq(adapter.lastUpdated(), block.timestamp, "wrong timestamp");
    }

    function testDescriptionReturnsFeedDescription() public {
        MockOrbOracle feed = new MockOrbOracle(100 * 1e8, 110 * 1e8, 90 * 1e8, 3, "ORB / USD");
        OrbOracleToOracleAdapter adapter = new OrbOracleToOracleAdapter(address(feed), 8, 3);

        assertEq(adapter.description(), "ORB / USD", "wrong description");
    }

    function testRevertsOnZeroValue() public {
        MockOrbOracle feed = new MockOrbOracle(0, 110 * 1e8, 90 * 1e8, 3, "ORB / USD");
        OrbOracleToOracleAdapter adapter = new OrbOracleToOracleAdapter(address(feed), 8, 3);

        vm.expectRevert("bad value");
        adapter.readValue();
    }

    function testRevertsOnNegativeValue() public {
        MockOrbOracle feed = new MockOrbOracle(-1, 110 * 1e8, 90 * 1e8, 3, "ORB / USD");
        OrbOracleToOracleAdapter adapter = new OrbOracleToOracleAdapter(address(feed), 8, 3);

        vm.expectRevert("bad value");
        adapter.readValue();
    }

    function testRevertsOnZeroFeedAddress() public {
        vm.expectRevert("invalid feed");
        new OrbOracleToOracleAdapter(address(0), 8, 3);
    }

    function testRevertsOnZeroSampleSize() public {
        MockOrbOracle feed = new MockOrbOracle(100 * 1e8, 110 * 1e8, 90 * 1e8, 3, "ORB / USD");

        vm.expectRevert("invalid sample size");
        new OrbOracleToOracleAdapter(address(feed), 8, 0);
    }

    function testScalesZeroDecimalsToWad() public {
        MockOrbOracle feed = new MockOrbOracle(1234, 1300, 1200, 3, "ORB / USD");
        OrbOracleToOracleAdapter adapter = new OrbOracleToOracleAdapter(address(feed), 0, 3);

        assertEq(adapter.readValue(), 1234 * 1e18, "0 dec scaling failed");
    }
}
