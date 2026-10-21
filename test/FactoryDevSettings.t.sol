// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockERC20, GenericMockOracle} from "./GenericIOracleIntegration.t.sol";

contract FactoryDevSettingsTest is Test {
    address private dev = makeAddr("factory dev");
    GenericMockERC20 private base;
    GenericMockOracle private oracle;

    function setUp() public {
        base = new GenericMockERC20();
        oracle = new GenericMockOracle(1e18);
    }

    function _create(StableCoinFactory factory, address creator) private returns (StableCoinReactor) {
        base.mint(creator, 1e36);
        vm.startPrank(creator);
        base.approve(address(factory), 1e36);
        address deployed = factory.deployReactor(
            "Vault",
            "Base",
            "B",
            "Neutron",
            "N",
            address(base),
            address(oracle),
            "Proton",
            "P",
            0,
            0,
            103e16,
            15e17,
            1e36,
            0,
            0,
            1e18
        );
        vm.stopPrank();
        return StableCoinReactor(deployed);
    }

    function testFuzzPublicCreatorUsesFactorySettings(address creator, uint64 rate) public {
        vm.assume(creator != address(0) && creator != dev && creator != address(base));
        uint256 fee = bound(uint256(rate), 0, 1e18 - 1);
        StableCoinFactory factory = new StableCoinFactory(dev, fee);
        vm.assume(creator != address(factory));
        StableCoinReactor reactor = _create(factory, creator);
        assertEq(reactor.dev(), dev);
        assertEq(reactor.devFeeReceiver(), dev);
        assertEq(reactor.devFee(), fee);
        assertEq(base.balanceOf(dev), 1e36 * fee / 1e18);
        assertEq(base.balanceOf(creator), 0);
        assertEq(base.balanceOf(address(factory)), 0);
        assertEq(factory.getDeployedReactorsCount(), 1);
    }

    function testReactorDevChangesDoNotChangeFactoryOrLaterReactors() public {
        StableCoinFactory factory = new StableCoinFactory(dev, 1e15);
        StableCoinReactor first = _create(factory, address(this));
        address nextDev = makeAddr("next dev");
        vm.prank(dev);
        first.proposeDev(nextDev);
        vm.prank(nextDev);
        first.acceptDev();
        vm.prank(nextDev);
        first.setDevFeeReceiver(nextDev);
        StableCoinReactor second = _create(factory, makeAddr("another creator"));
        assertEq(first.devFeeReceiver(), nextDev);
        assertEq(second.dev(), dev);
        assertEq(second.devFeeReceiver(), dev);
        assertEq(factory.dev(), dev);
        assertEq(factory.devFee(), 1e15);
    }
}
