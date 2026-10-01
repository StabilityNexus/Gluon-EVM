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
    uint256 internal constant UPDATED_ORACLE_VALUE = 2e18;
    uint256 internal constant FALLBACK_ORACLE_VALUE = 11e17;
    uint256 internal constant ORACLE_WEIGHT = 100e18;
    uint256 internal constant INITIAL_RESERVE = 100e18;
    uint256 internal constant DEPOSIT_LOCKING_PERIOD = 1;

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

        orbOracle = new Oracle(
            address(this),
            "Orb BASE / USD",
            "Orb BASE / USD",
            address(weightToken),
            0,
            0,
            DEPOSIT_LOCKING_PERIOD,
            0,
            0,
            0,
            1
        );

        weightToken.mint(reporter, ORACLE_WEIGHT);

        vm.startPrank(reporter);
        weightToken.approve(address(orbOracle), ORACLE_WEIGHT);
        orbOracle.depositTokens(ORACLE_WEIGHT);
        vm.stopPrank();

        vm.warp(block.timestamp + DEPOSIT_LOCKING_PERIOD);

        vm.prank(reporter);
        orbOracle.submitValue(ORACLE_VALUE);
    }

    function testOrbSatisfiesGluonIOracle() public view {
        IOracle oracle = IOracle(address(orbOracle));

        assertEq(oracle.readValue(), ORACLE_VALUE);

        (uint256 minValue, uint256 maxValue) = oracle.readValueInterval();

        assertEq(minValue, ORACLE_VALUE);
        assertEq(maxValue, ORACLE_VALUE);
        assertEq(oracle.lastUpdated(), block.timestamp);
        assertEq(oracle.description(), "Orb BASE / USD");
    }

    function testFactoryDeploysReactorWithOrbDirectly() public {
        reactor = _deployReactor();

        assertEq(address(reactor.ORACLE()), address(orbOracle));
        assertEq(reactor.lastSuccessfulBasePrice(), ORACLE_VALUE);
        assertEq(factory.getDeployedReactorsCount(), 1);
    }

    function testReactorReadsUpdatedOrbValue() public {
        reactor = _deployReactor();

        assertEq(reactor.getBasePriceInPeggedAsset(), ORACLE_VALUE);

        vm.warp(block.timestamp + 1);

        vm.prank(reporter);
        orbOracle.submitValue(UPDATED_ORACLE_VALUE);

        assertEq(orbOracle.readValue(), UPDATED_ORACLE_VALUE);
        assertEq(reactor.getBasePriceInPeggedAsset(), UPDATED_ORACLE_VALUE);

        // Reading through a view does not persist: only state-changing operations refresh the cache.
        assertEq(reactor.lastSuccessfulBasePrice(), ORACLE_VALUE);
    }

    function testFusionUsesCachedPriceWhenOrbBlacklistsReactor() public {
        reactor = _deployReactor();

        address user = makeAddr("blacklistUser");
        uint256 fissionAmount = 100e18;
        uint256 fusionAmount = 10e18;

        vm.warp(block.timestamp + 1);

        vm.prank(reporter);
        orbOracle.submitValue(FALLBACK_ORACLE_VALUE);

        baseToken.mint(user, fissionAmount);

        vm.startPrank(user);
        baseToken.approve(address(reactor), fissionAmount);
        reactor.fission(fissionAmount, user);
        vm.stopPrank();

        assertEq(reactor.lastSuccessfulBasePrice(), FALLBACK_ORACLE_VALUE);

        vm.prank(reporter);
        orbOracle.voteBlacklist(address(reactor));

        assertTrue(orbOracle.isBlacklisted(address(reactor)));

        // Move Orb's live value so the cached price is provably distinct from what Orb now reports.
        vm.warp(block.timestamp + 1);

        vm.prank(reporter);
        orbOracle.submitValue(UPDATED_ORACLE_VALUE);

        assertEq(orbOracle.readValue(), UPDATED_ORACLE_VALUE);
        assertEq(reactor.getBasePriceInPeggedAsset(), FALLBACK_ORACLE_VALUE);

        uint256 userBaseBefore = baseToken.balanceOf(user);
        uint256 reserveBefore = reactor.reserve();

        vm.prank(user);
        reactor.fusion(fusionAmount, user);

        assertEq(baseToken.balanceOf(user) - userBaseBefore, fusionAmount);
        assertEq(reserveBefore - reactor.reserve(), fusionAmount);
        assertEq(reactor.lastSuccessfulBasePrice(), FALLBACK_ORACLE_VALUE);
    }

    function testFissionWorksWithOrbOracle() public {
        reactor = _deployReactor();

        address user = makeAddr("fissionUser");
        uint256 amount = 100e18;

        baseToken.mint(user, amount);

        vm.startPrank(user);
        baseToken.approve(address(reactor), amount);
        reactor.fission(amount, user);
        vm.stopPrank();

        assertGt(reactor.NEUTRON_TOKEN().balanceOf(user), 0);
        assertGt(reactor.PROTON_TOKEN().balanceOf(user), 0);
    }

    function testFusionReturnsExactBaseAmountWithOrbOracle() public {
        reactor = _deployReactor();

        address user = makeAddr("fusionUser");
        uint256 fissionAmount = 100e18;
        uint256 fusionAmount = 10e18;

        baseToken.mint(user, fissionAmount);

        vm.startPrank(user);
        baseToken.approve(address(reactor), fissionAmount);
        reactor.fission(fissionAmount, user);
        vm.stopPrank();

        uint256 userBaseBefore = baseToken.balanceOf(user);
        uint256 reserveBefore = reactor.reserve();
        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonBefore = reactor.PROTON_TOKEN().balanceOf(user);

        vm.prank(user);
        reactor.fusion(fusionAmount, user);

        assertEq(baseToken.balanceOf(user) - userBaseBefore, fusionAmount);
        assertEq(reserveBefore - reactor.reserve(), fusionAmount);
        assertLt(reactor.NEUTRON_TOKEN().balanceOf(user), neutronBefore);
        assertLt(reactor.PROTON_TOKEN().balanceOf(user), protonBefore);
    }

    function _deployReactor() internal returns (StableCoinReactor) {
        baseToken.mint(address(this), INITIAL_RESERVE);
        baseToken.approve(address(factory), INITIAL_RESERVE);

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
            15e17,
            INITIAL_RESERVE
        );

        return StableCoinReactor(reactorAddress);
    }
}
