// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockERC20, GenericMockOracle} from "./GenericIOracleIntegration.t.sol";

contract ReserveRatioConfigurationTest is Test {
    StableCoinFactory private factory;
    GenericMockERC20 private base;
    GenericMockOracle private oracle;
    uint256 private constant SEED = 1e36;

    function setUp() public {
        factory = new StableCoinFactory();
        base = new GenericMockERC20();
        oracle = new GenericMockOracle(1e18);
        base.mint(address(this), 10 * SEED);
        base.approve(address(factory), type(uint256).max);
    }

    function _create(uint256 critical, uint256 initial, uint256 fissionFee) private returns (StableCoinReactor) {
        return StableCoinReactor(
            factory.deployReactor(
                "Ratio Vault",
                "Base",
                "B",
                "Neutron",
                "N",
                address(base),
                address(oracle),
                "Proton",
                "P",
                address(1),
                0,
                fissionFee,
                0,
                critical,
                initial,
                SEED,
                0,
                0,
                1e18
            )
        );
    }

    function testDeployerChoosesRatiosAbovePreviousLimit() public {
        StableCoinReactor reactor = _create(16e17, 18e17, 0);
        assertEq(reactor.CRITICAL_RESERVE_RATIO(), 16e17);
        assertEq(reactor.reserveRatioPeggedAsset(), 18e17);
        assertEq(reactor.reserve(), SEED);
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(address(reactor)), SEED * 1e18 / 18e17);
        assertEq(factory.getDeployedReactorsCount(), 1);
    }

    function testCriticalRatioStrictBoundaries() public {
        vm.expectRevert(StableCoinReactor.InvalidCriticalReserveRatio.selector);
        _create(1e18, 15e17, 0);
        vm.expectRevert(StableCoinReactor.InvalidCriticalReserveRatio.selector);
        _create(2e18, 15e17, 0);

        StableCoinReactor low = _create(1e18 + 1, 15e17, 0);
        assertEq(low.CRITICAL_RESERVE_RATIO(), 1e18 + 1);
        StableCoinReactor high = _create(2e18 - 2, 2e18 - 1, 0);
        assertEq(high.CRITICAL_RESERVE_RATIO(), 2e18 - 2);
        assertEq(high.reserveRatioPeggedAsset(), 2e18 - 1);
    }

    function testInitialRatioStrictBoundaries() public {
        vm.expectRevert(StableCoinReactor.InvalidInitialReserveRatio.selector);
        _create(12e17, 12e17, 0);
        vm.expectRevert(StableCoinReactor.InvalidInitialReserveRatio.selector);
        _create(12e17, 12e17 - 1, 0);
        vm.expectRevert(StableCoinReactor.InvalidInitialReserveRatio.selector);
        _create(12e17, 2e18, 0);

        StableCoinReactor reactor = _create(12e17, 12e17 + 1, 0);
        assertEq(reactor.reserveRatioPeggedAsset(), 12e17 + 1);
    }

    function testRetainedFeeCannotInitializeAtUpperBound() public {
        vm.expectRevert(StableCoinReactor.InvalidInitialReserve.selector);
        _create(12e17, 15e17, 25e16);
        assertEq(factory.getDeployedReactorsCount(), 0);
        assertEq(base.balanceOf(address(this)), 10 * SEED);
        assertEq(base.balanceOf(address(factory)), 0);
    }

    function testRetainedFeeCanInitializeBelowUpperBound() public {
        StableCoinReactor reactor = _create(12e17, 15e17, 2e17);
        assertGt(reactor.reserveRatioPeggedAsset(), 15e17);
        assertLt(reactor.reserveRatioPeggedAsset(), 2e18);
        assertEq(reactor.reserve(), SEED);
    }

    function testFuzzDeploysChosenRatios(uint256 critical, uint256 initial) public {
        critical = bound(critical, 1e18 + 1, 2e18 - 2);
        initial = bound(initial, critical + 1, 2e18 - 1);
        StableCoinReactor reactor = _create(critical, initial, 0);
        assertEq(reactor.CRITICAL_RESERVE_RATIO(), critical);
        assertEq(reactor.reserveRatioPeggedAsset(), initial);
        assertEq(reactor.reserve(), SEED);
        assertGt(reactor.PROTON_TOKEN().totalSupply(), 0);
    }

    function testFuzzRejectsInvalidInitialWithoutMovingFunds(uint256 initial, bool belowCritical) public {
        initial = belowCritical ? bound(initial, 0, 12e17) : bound(initial, 2e18, type(uint256).max);

        vm.expectRevert(StableCoinReactor.InvalidInitialReserveRatio.selector);
        _create(12e17, initial, 0);
        assertEq(factory.getDeployedReactorsCount(), 0);
        assertEq(base.balanceOf(address(this)), 10 * SEED);
        assertEq(base.balanceOf(address(factory)), 0);
    }

    function testFuzzRejectsInvalidCritical(uint256 critical, bool belowOne) public {
        critical = belowOne ? bound(critical, 0, 1e18) : bound(critical, 2e18, type(uint256).max);

        vm.expectRevert(StableCoinReactor.InvalidCriticalReserveRatio.selector);
        _create(critical, 15e17, 0);
        assertEq(factory.getDeployedReactorsCount(), 0);
    }
}
