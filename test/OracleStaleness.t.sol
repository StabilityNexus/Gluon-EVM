// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockERC20, GenericMockOracle} from "./GenericIOracleIntegration.t.sol";

contract OracleStalenessTest is Test {
    uint256 internal constant MAX_STALENESS = 1 hours;

    StableCoinFactory internal factory;
    GenericMockERC20 internal baseToken;
    GenericMockOracle internal oracle;
    address internal user = makeAddr("user");

    function setUp() public {
        factory = new StableCoinFactory(address(this), 0, MAX_STALENESS);
        baseToken = new GenericMockERC20();
        oracle = new GenericMockOracle(1e18);
    }

    function testFactoryRejectsZeroMaxStaleness() public {
        vm.expectRevert(StableCoinFactory.InvalidMaxStaleness.selector);
        new StableCoinFactory(address(this), 0, 0);
    }

    function testReactorUsesFactoryStalenessLimit() public {
        StableCoinReactor reactor = _deploy();
        assertEq(reactor.MAX_STALENESS(), MAX_STALENESS);
    }

    function testStateChangingOperationRejectsStalePrice() public {
        StableCoinReactor reactor = _deploy();
        _fund(reactor);
        uint256 updatedAt = oracle.lastUpdated();
        vm.warp(updatedAt + MAX_STALENESS + 1);

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StableCoinReactor.OraclePriceStale.selector, updatedAt, MAX_STALENESS));
        reactor.fission(1e18, user);
        vm.stopPrank();
    }

    function testFreshPriceAfterWarpIsAccepted() public {
        StableCoinReactor reactor = _deploy();
        _fund(reactor);
        vm.warp(block.timestamp + 2 hours);
        oracle.setValue(1e18);
        baseToken.mint(user, 1e18);
        vm.prank(user);
        baseToken.approve(address(reactor), 1e18);

        vm.prank(user);
        reactor.fission(1e18, user);
    }

    function testViewStillReturnsOraclePriceWhenStale() public {
        StableCoinReactor reactor = _deploy();
        vm.warp(block.timestamp + 2 hours);
        assertEq(reactor.getBasePriceInPeggedAsset(), 1e18);
    }

    function _deploy() internal returns (StableCoinReactor) {
        baseToken.mint(user, 100e18);
        vm.prank(user);
        baseToken.approve(address(factory), 100e18);
        vm.prank(user);
        return StableCoinReactor(
            factory.deployReactor(
                "Vault",
                "Base",
                "BASE",
                "Neutron",
                "N",
                address(baseToken),
                address(oracle),
                "Proton",
                "P",
                0,
                0,
                12e17,
                15e17,
                100e18,
                0,
                0,
                1e18
            )
        );
    }

    function _fund(StableCoinReactor reactor) internal {
        baseToken.mint(user, 100e18);
        vm.startPrank(user);
        baseToken.approve(address(reactor), 100e18);
        reactor.fission(100e18, user);
        vm.stopPrank();
    }
}
