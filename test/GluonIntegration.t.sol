// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GluonChainlinkAdapter} from "../src/oracles/GluonChainlinkAdapter.sol";
// Use OpenZeppelin directly to avoid forge-std path issues
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Simple Inline Mock ERC20
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock for Chainlink/Orb Feed
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
}

contract GluonIntegrationTest is Test {
    StableCoinFactory factory;
    StableCoinReactor reactor;
    GluonChainlinkAdapter adapter;
    MockFeed mockFeed;
    MockERC20 baseToken;
    address treasury = makeAddr("treasury");

    function setUp() public {
        // Fixed: Use standard ERC20 constructor (name, symbol)
        baseToken = new MockERC20("USD Coin", "USDC");

        // 2. Setup Oracle (Price = $1.00, 8 decimals like Chainlink)
        mockFeed = new MockFeed(100000000, 8); 
        adapter = new GluonChainlinkAdapter(address(mockFeed), 3600); // 1 hour staleness

        // 3. Deploy Factory
        factory = new StableCoinFactory();

        // 4. Deploy Reactor via Factory
        address reactorAddr = factory.deployReactor(
            "Gluon Vault", "USD Coin", "USDC", "Gluon USD", "GUSD",
            address(baseToken),
            address(adapter), 
            "Gluon Gov", "GOV",
            treasury,
            0, 0, 15e17 // 150% collateral ratio
        );
        reactor = StableCoinReactor(reactorAddr);
    }

    function testFissionWithAdapter() public {
        address user = makeAddr("user");
        baseToken.mint(user, 1000 * 1e18);

        vm.startPrank(user);
        baseToken.approve(address(reactor), 1000 * 1e18);

        bytes[] memory updateData = new bytes[](0);
        
        reactor.fission(100 * 1e18, user, updateData);

        uint256 neutronBal = reactor.NEUTRON_TOKEN().balanceOf(user);
        
        assertTrue(neutronBal > 0, "Neutron tokens not minted");
        console.log("Neutron Minted:", neutronBal);
        
        vm.stopPrank();
    }
}