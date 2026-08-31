// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Oracle} from "../lib/OrbOracle-Solidity/src/Oracle.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract OrbOracleIntegrationTest is Test {
    uint256 internal constant ORACLE_VALUE = 1e18;
    uint256 internal constant ORACLE_WEIGHT = 100e18;

    StableCoinFactory internal factory;
    StableCoinReactor internal reactor;
    MockERC20 internal baseToken;
    MockERC20 internal weightToken;
    Oracle internal orbOracle;

    address internal reporter = makeAddr("reporter");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        factory = new StableCoinFactory();

        baseToken = new MockERC20("USD Coin", "USDC");
        weightToken = new MockERC20("Orb Weight Token", "ORB");

        orbOracle =
            new Oracle(address(this), "Orb ETH / USD", "Orb ETH / USD", address(weightToken), 1 days, 0, 0, 0, 0, 0, 1);

        weightToken.mint(reporter, ORACLE_WEIGHT);

        vm.startPrank(reporter);
        weightToken.approve(address(orbOracle), ORACLE_WEIGHT);
        orbOracle.depositTokens(ORACLE_WEIGHT);
        orbOracle.submitValue(ORACLE_VALUE);
        vm.stopPrank();
    }

    function testOrbOracleSatisfiesGluonIOracle() public view {
        IOracle oracle = IOracle(address(orbOracle));

        assertEq(oracle.readValue(), ORACLE_VALUE);

        (uint256 minValue, uint256 maxValue) = oracle.readValueInterval();

        assertEq(minValue, ORACLE_VALUE);
        assertEq(maxValue, ORACLE_VALUE);
        assertEq(oracle.lastUpdated(), block.timestamp);
        assertEq(oracle.description(), "Orb ETH / USD");
    }

    function testFactoryDeploysReactorWithOrbOracleDirectly() public {
        reactor = _deployReactor();

        assertEq(address(reactor.ORACLE()), address(orbOracle));
    }

    function testReactorReadsOrbOracleValue() public {
        reactor = _deployReactor();

        assertEq(reactor.getBasePriceInPeggedAsset(), ORACLE_VALUE);

        vm.warp(block.timestamp + 1);

        vm.prank(reporter);
        orbOracle.submitValue(2e18);

        assertEq(reactor.getBasePriceInPeggedAsset(), 2e18);
    }

    function testFissionAndFusionWorkWithOrbOracle() public {
        reactor = _deployReactor();

        address user = makeAddr("user");

        baseToken.mint(user, 100e18);

        vm.startPrank(user);
        baseToken.approve(address(reactor), 100e18);
        reactor.fission(100e18, user);
        vm.stopPrank();

        assertGt(reactor.NEUTRON_TOKEN().balanceOf(user), 0);
        assertGt(reactor.PROTON_TOKEN().balanceOf(user), 0);

        uint256 baseBalanceBefore = baseToken.balanceOf(user);

        vm.prank(user);
        reactor.fusion(10e18, user);

        assertGt(baseToken.balanceOf(user), baseBalanceBefore);
    }

    function _deployReactor() internal returns (StableCoinReactor) {
        address reactorAddress = factory.deployReactor(
            "Orb Vault",
            "USD Coin",
            "USDC",
            "Gluon USD",
            "GUSD",
            address(baseToken),
            address(orbOracle),
            "Gluon Proton",
            "PRO",
            treasury,
            0,
            0,
            15e17
        );

        return StableCoinReactor(reactorAddress);
    }
}
