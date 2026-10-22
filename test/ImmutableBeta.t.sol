// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockERC20, GenericMockOracle} from "./GenericIOracleIntegration.t.sol";

contract ImmutableBetaTest is Test {
    StableCoinFactory internal factory;
    GenericMockERC20 internal baseToken;
    GenericMockOracle internal oracle;
    address internal dev = makeAddr("dev");
    address internal user = makeAddr("user");

    function setUp() public {
        factory = new StableCoinFactory();
        baseToken = new GenericMockERC20();
        oracle = new GenericMockOracle(1e18);
    }

    function testFuzzConstructorStoresValidBetaParameters(uint256 phi0, uint256 phi1, uint256 decay) public {
        phi0 = bound(phi0, 0, 1e18);
        phi1 = bound(phi1, 0, 1e18);
        decay = bound(decay, 0, 1e18);
        StableCoinReactor reactor = _deploy(user, phi0, phi1, decay);

        assertEq(reactor.betaPhi0(), phi0);
        assertEq(reactor.betaPhi1(), phi1);
        assertEq(reactor.decayPerSecondWad(), decay);
        assertEq(factory.getDeployedReactorsCount(), 1);
    }

    function testRejectsInvalidPhi0() public {
        _prepare(user);
        vm.expectRevert(StableCoinReactor.InvalidPhi.selector);
        _create(user, 1e18 + 1, 0, 1e18);
        assertEq(factory.getDeployedReactorsCount(), 0);
        assertEq(baseToken.balanceOf(user), 100e18);
    }

    function testRejectsInvalidPhi1() public {
        _prepare(user);
        vm.expectRevert(StableCoinReactor.InvalidPhi.selector);
        _create(user, 0, 1e18 + 1, 1e18);
    }

    function testRejectsInvalidDecay() public {
        _prepare(user);
        vm.expectRevert(StableCoinReactor.InvalidDecay.selector);
        _create(user, 0, 0, 1e18 + 1);
    }

    function testDifferentDeployersChooseIndependentSettings() public {
        StableCoinReactor first = _deploy(user, 0, 0, 1e18);
        StableCoinReactor second = _deploy(makeAddr("secondUser"), 1e16, 5e17, 999e15);

        assertEq(first.betaPhi0(), 0);
        assertEq(first.decayPerSecondWad(), 1e18);
        assertEq(second.betaPhi0(), 1e16);
        assertEq(second.betaPhi1(), 5e17);
        assertEq(second.decayPerSecondWad(), 999e15);
        assertEq(factory.getDeployedReactorsCount(), 2);
    }

    function testDevAndDeployerCannotUseRemovedSetter() public {
        StableCoinReactor reactor = _deploy(user, 1e16, 5e17, 999e15);
        bytes memory data = abi.encodeWithSignature("setBetaParams(uint256,uint256,uint256)", 0, 0, 1e18);

        vm.prank(dev);
        (bool devSuccess,) = address(reactor).call(data);
        vm.prank(user);
        (bool deployerSuccess,) = address(reactor).call(data);

        assertFalse(devSuccess);
        assertFalse(deployerSuccess);
        assertEq(reactor.betaPhi0(), 1e16);
        assertEq(reactor.betaPhi1(), 5e17);
        assertEq(reactor.decayPerSecondWad(), 999e15);
    }

    function testConfiguredBaseFeeAppliesInBothDirections() public {
        StableCoinReactor reactor = _deploy(user, 1e16, 0, 1e18);
        _fund(reactor);

        vm.startPrank(user);
        (uint256 neutronOut, uint256 plusFee) = reactor.transmuteProtonToNeutron(1e18, 0, user);
        (uint256 protonOut, uint256 minusFee) = reactor.transmuteNeutronToProton(1e18, 0, user);
        vm.stopPrank();

        assertGt(neutronOut, 0);
        assertGt(protonOut, 0);
        assertEq(plusFee, 1e16);
        assertEq(minusFee, 1e16);
    }

    function testConfiguredDecayReducesVolumeDependentFee() public {
        StableCoinReactor retained = _deploy(user, 0, 5e17, 1e18);
        StableCoinReactor decayed = _deploy(user, 0, 5e17, 5e17);
        _fund(retained);
        _fund(decayed);

        vm.startPrank(user);
        retained.transmuteProtonToNeutron(1e18, 0, user);
        decayed.transmuteProtonToNeutron(1e18, 0, user);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        vm.startPrank(user);
        (, uint256 retainedFee) = retained.transmuteProtonToNeutron(1e18, 0, user);
        (, uint256 decayedFee) = decayed.transmuteProtonToNeutron(1e18, 0, user);
        vm.stopPrank();

        assertGt(retainedFee, 0);
        assertEq(decayedFee, retainedFee / 2);
        assertEq(decayed.decayPerSecondWad(), 5e17);
    }

    function _prepare(address deployer) internal {
        baseToken.mint(deployer, 100e18);
        vm.prank(deployer);
        baseToken.approve(address(factory), 100e18);
    }

    function _deploy(address deployer, uint256 phi0, uint256 phi1, uint256 decay) internal returns (StableCoinReactor) {
        _prepare(deployer);
        return _create(deployer, phi0, phi1, decay);
    }

    function _create(address deployer, uint256 phi0, uint256 phi1, uint256 decay) internal returns (StableCoinReactor) {
        vm.prank(deployer);
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
                dev,
                0,
                0,
                0,
                12e17,
                15e17,
                100e18,
                phi0,
                phi1,
                decay
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
