// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {ChainlinkToOracleAdapter} from "../src/oracles/ChainlinkToOracleAdapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// mock chainlink style feed
contract MockFeed {
    int256 public price;
    uint8 public decimalsVal;
    uint256 public updatedAtVal;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimalsVal = _decimals;
        updatedAtVal = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, 0, updatedAtVal, 0);
    }

    function decimals() external view returns (uint8) {
        return decimalsVal;
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }
}

contract GluonIntegrationTest is Test {
    StableCoinFactory factory;
    StableCoinReactor reactor;
    ChainlinkToOracleAdapter adapter;
    MockFeed mockFeed;
    MockERC20 baseToken;
    address treasury = makeAddr("treasury");

    function setUp() public {
        baseToken = new MockERC20("USD Coin", "USDC");

        // price = $1.00, 8 decimals like chainlink
        mockFeed = new MockFeed(100000000, 8);
        adapter = new ChainlinkToOracleAdapter(address(mockFeed));

        factory = new StableCoinFactory();

        address reactorAddr = factory.deployReactor(
            "Gluon Vault",
            "USD Coin",
            "USDC",
            "Gluon USD",
            "GUSD",
            address(baseToken),
            address(adapter),
            "Gluon Gov",
            "GOV",
            treasury,
            0,
            0,
            15e17 // 150% collateral ratio
        );
        reactor = StableCoinReactor(reactorAddr);
    }

    function testFissionWithAdapter() public {
        address user = makeAddr("user");
        baseToken.mint(user, 1000 * 1e18);

        vm.startPrank(user);
        baseToken.approve(address(reactor), 1000 * 1e18);

        reactor.fission(100 * 1e18, user);

        uint256 neutronBal = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonBal = reactor.PROTON_TOKEN().balanceOf(user);

        assertTrue(neutronBal > 0, "Neutron tokens not minted");
        assertTrue(protonBal > 0, "Proton tokens not minted");

        console.log("Neutron Minted:", neutronBal);
        console.log("Proton Minted:", protonBal);

        vm.stopPrank();
    }

    function testReactorRejectsZeroOracle() public {
        vm.expectRevert("Invalid oracle");

        factory.deployReactor(
            "Gluon Vault",
            "USD Coin",
            "USDC",
            "Gluon USD",
            "GUSD",
            address(baseToken),
            address(0),
            "Gluon Gov",
            "GOV",
            treasury,
            0,
            0,
            15e17
        );
    }

    function testReactorRejectsEOAOracle() public {
        address eoaOracle = makeAddr("eoaOracle");

        vm.expectRevert("Oracle not contract");

        factory.deployReactor(
            "Gluon Vault",
            "USD Coin",
            "USDC",
            "Gluon USD",
            "GUSD",
            address(baseToken),
            eoaOracle,
            "Gluon Gov",
            "GOV",
            treasury,
            0,
            0,
            15e17
        );
    }
}
