// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChainlinkToOracleAdapter} from "../src/oracles/ChainlinkToOracleAdapter.sol";

// mock chainlink feed for adapter tests
contract MockChainlinkFeed {
    uint8 public decimalsVal;
    int256 public answerVal;
    uint256 public updatedAtVal;

    constructor(uint8 _decimals, int256 _answer) {
        decimalsVal = _decimals;
        answerVal = _answer;
        updatedAtVal = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return decimalsVal;
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answerVal, 0, updatedAtVal, 0);
    }
}

contract ChainlinkAdapterTest is Test {
    function testScalesEightDecimalsToWad() public {
        // $50000 with 8 decimals
        MockChainlinkFeed feed = new MockChainlinkFeed(8, 50000 * 1e8);
        ChainlinkToOracleAdapter adapter = new ChainlinkToOracleAdapter(address(feed));
        assertEq(adapter.readValue(), 50000 * 1e18, "8 dec scaling failed");
    }

    function testSupportsEighteenDecimals() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(18, 2000 * 1e18);
        ChainlinkToOracleAdapter adapter = new ChainlinkToOracleAdapter(address(feed));
        assertEq(adapter.readValue(), 2000 * 1e18, "18 dec scaling failed");
    }

    function testSupportsMoreThanEighteenDecimals() public {
        // 20 decimals, should divide down to WAD
        MockChainlinkFeed feed = new MockChainlinkFeed(20, 2000 * 1e20);
        ChainlinkToOracleAdapter adapter = new ChainlinkToOracleAdapter(address(feed));
        assertEq(adapter.readValue(), 2000 * 1e18, "20 dec scaling failed");
    }

    function testValueIntervalEqualsValue() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(8, 100 * 1e8);
        ChainlinkToOracleAdapter adapter = new ChainlinkToOracleAdapter(address(feed));

        (uint256 minValue, uint256 maxValue) = adapter.readValueInterval();

        assertEq(minValue, adapter.readValue(), "min != value");
        assertEq(maxValue, adapter.readValue(), "max != value");
    }

    function testLastUpdatedReturnsFeedTimestamp() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(8, 100 * 1e8);
        ChainlinkToOracleAdapter adapter = new ChainlinkToOracleAdapter(address(feed));
        assertEq(adapter.lastUpdated(), block.timestamp, "wrong timestamp");
    }

    function testRevertsOnZeroAnswer() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(8, 0);
        ChainlinkToOracleAdapter adapter = new ChainlinkToOracleAdapter(address(feed));
        vm.expectRevert(ChainlinkToOracleAdapter.BadValue.selector);
        adapter.readValue();
    }

    function testRevertsOnZeroFeedAddress() public {
        vm.expectRevert(ChainlinkToOracleAdapter.InvalidFeed.selector);
        new ChainlinkToOracleAdapter(address(0));
    }

    function testRevertsOnNegativeAnswer() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(8, -1);
        ChainlinkToOracleAdapter adapter = new ChainlinkToOracleAdapter(address(feed));

        vm.expectRevert(ChainlinkToOracleAdapter.BadValue.selector);
        adapter.readValue();
    }

    function testScalesSixDecimalsToWad() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(6, 1234 * 1e6);
        ChainlinkToOracleAdapter adapter = new ChainlinkToOracleAdapter(address(feed));

        assertEq(adapter.readValue(), 1234 * 1e18, "6 dec scaling failed");
    }

    function testScalesZeroDecimalsToWad() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(0, 1234);
        ChainlinkToOracleAdapter adapter = new ChainlinkToOracleAdapter(address(feed));

        assertEq(adapter.readValue(), 1234 * 1e18, "0 dec scaling failed");
    }

    function testDescriptionReturnsFeedDescription() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(8, 100 * 1e8);
        ChainlinkToOracleAdapter adapter = new ChainlinkToOracleAdapter(address(feed));

        assertEq(adapter.description(), "MOCK / USD", "wrong description");
    }
}
