// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GluonChainlinkAdapter} from "../src/oracles/GluonChainlinkAdapter.sol";
import {GluonPythAdapter} from "../src/oracles/GluonPythAdapter.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {IGluonOracle} from "../src/interfaces/IGluonOracle.sol";

// Mock Chainlink Aggregator
contract MockChainlinkAggregator {
    uint8 public decimalsVal;
    int256 public priceVal;
    uint256 public updatedAtVal;

    constructor(uint8 _decimals, int256 _price) {
        decimalsVal = _decimals;
        priceVal = _price;
        updatedAtVal = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return decimalsVal;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, priceVal, 0, updatedAtVal, 0);
    }
}

// Mock Pyth
contract MockPyth {
    int64 public priceVal;
    int32 public expoVal;
    uint256 public publishTimeVal;

    constructor(int64 _price, int32 _expo) {
        priceVal = _price;
        expoVal = _expo;
        publishTimeVal = block.timestamp;
    }

    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceUnsafe(bytes32) external view returns (Price memory) {
        return Price(priceVal, 0, expoVal, publishTimeVal);
    }

    // This is the function the Adapter calls for safety
    function getPriceNoOlderThan(bytes32, uint256) external view returns (Price memory) {
         return Price(priceVal, 0, expoVal, publishTimeVal);
    }

    function getUpdateFee(bytes[] calldata) external pure returns (uint256) {
        return 1 ether; // Mock fee
    }

    function updatePriceFeeds(bytes[] calldata) external payable {
        // Mock update
    }
}

contract GluonOracleTest is Test {
    GluonChainlinkAdapter chainlinkAdapter;
    GluonPythAdapter pythAdapter;
    MockChainlinkAggregator mockCL;
    MockPyth mockPyth;

    bytes32 constant MOCK_PRICE_ID = bytes32(uint256(1));
    uint256 constant MAX_AGE = 60; // Fixed: Defined Max Age

    function testChainlinkPriceScaling() public {
        // Case 1: Chainlink has 8 decimals (e.g., BTC/USD)
        mockCL = new MockChainlinkAggregator(8, 50000 * 1e8);
        
        // FIXED: Passed MAX_AGE to constructor
        chainlinkAdapter = new GluonChainlinkAdapter(address(mockCL), MAX_AGE);

        uint256 price = chainlinkAdapter.getPrice();
        
        // Expected: 50,000 * 1e18 (Standard WAD)
        assertEq(price, 50000 * 1e18, "Chainlink 8 dec scaling failed");
    }

    function testPythPriceScaling() public {
        // Case 1: Pyth price is 2000 * 1e-8
        mockPyth = new MockPyth(200000000000, -8);
        
        // FIXED: Passed MAX_AGE to constructor
        pythAdapter = new GluonPythAdapter(address(mockPyth), MOCK_PRICE_ID, MAX_AGE);

        uint256 price = pythAdapter.getPrice();

        // Expected: 2000 * 1e18
        assertEq(price, 2000 * 1e18, "Pyth neg expo scaling failed");
    }
    
    function testOracleInterfaceCompatibility() public {
        // Setup simple mocks again for this test
        mockCL = new MockChainlinkAggregator(8, 100 * 1e8);
        mockPyth = new MockPyth(100 * 1e8, -8);

        // FIXED: Passed MAX_AGE
        chainlinkAdapter = new GluonChainlinkAdapter(address(mockCL), MAX_AGE);
        pythAdapter = new GluonPythAdapter(address(mockPyth), MOCK_PRICE_ID, MAX_AGE);

        // Ensure both adapters can be stored in the generic interface
        IGluonOracle oracle1 = IGluonOracle(address(chainlinkAdapter));
        IGluonOracle oracle2 = IGluonOracle(address(pythAdapter));
        
        assertTrue(address(oracle1) != address(0));
        assertTrue(address(oracle2) != address(0));
    }
}