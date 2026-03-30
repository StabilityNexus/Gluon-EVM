// SPDX-License-Identifier: AEL
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {StableCoinReactor} from "../src/StableCoin.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract StableCoinPreviewTest is Test {
    uint256 internal constant WAD = 1e18;
    bytes32 internal constant PRICE_ID = keccak256("BASE/USD");

    MockERC20 internal baseToken;
    MockPyth internal pyth;
    StableCoinReactor internal reactor;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal treasury = address(0x7EA5);

    function setUp() external {
        baseToken = new MockERC20("Base Token", "BASE");
        pyth = new MockPyth();
        pyth.setPrice(200000000, -8, block.timestamp); // $2.00 with 1e18 scaling after conversion

        reactor = new StableCoinReactor(
            "Gluon Vault",
            "Base Token",
            "BASE",
            "Neutron",
            "NEU",
            address(baseToken),
            address(pyth),
            PRICE_ID,
            "Proton",
            "PRO",
            treasury,
            0.02e18, // 2%
            0.03e18, // 3%
            1.5e18
        );

        baseToken.mint(alice, 1_000e18);
        baseToken.mint(bob, 1_000e18);

        vm.prank(alice);
        baseToken.approve(address(reactor), type(uint256).max);
        vm.prank(bob);
        baseToken.approve(address(reactor), type(uint256).max);
    }

    function test_previewFission_matchesBootstrapExecution() external {
        uint256 amountIn = 300e18;

        (uint256 expectedNeutron, uint256 expectedProton, uint256 feeAmount, uint256 netBase, bool bootstrap) =
            reactor.previewFission(amountIn);

        assertTrue(bootstrap);
        assertEq(feeAmount, 6e18);
        assertEq(netBase, 294e18);

        vm.prank(alice);
        reactor.fission(amountIn, alice, new bytes[](0));

        assertEq(reactor.NEUTRON_TOKEN().balanceOf(alice), expectedNeutron);
        assertEq(reactor.PROTON_TOKEN().balanceOf(alice), expectedProton);
    }

    function test_previewFission_matchesSteadyStateExecution() external {
        vm.prank(alice);
        reactor.fission(300e18, alice, new bytes[](0));

        uint256 amountIn = 150e18;
        (uint256 expectedNeutron, uint256 expectedProton,,,) = reactor.previewFission(amountIn);

        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(bob);
        uint256 protonBefore = reactor.PROTON_TOKEN().balanceOf(bob);

        vm.prank(bob);
        reactor.fission(amountIn, bob, new bytes[](0));

        assertEq(reactor.NEUTRON_TOKEN().balanceOf(bob) - neutronBefore, expectedNeutron);
        assertEq(reactor.PROTON_TOKEN().balanceOf(bob) - protonBefore, expectedProton);
    }

    function test_previewFusion_matchesExecution() external {
        vm.prank(alice);
        reactor.fission(300e18, alice, new bytes[](0));

        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(alice);
        uint256 protonBefore = reactor.PROTON_TOKEN().balanceOf(alice);
        uint256 baseBefore = baseToken.balanceOf(alice);

        (uint256 expectedNeutronBurn, uint256 expectedProtonBurn, uint256 feeAmount, uint256 netBaseOut) =
            reactor.previewFusion(90e18);

        vm.prank(alice);
        reactor.fusion(90e18, alice);

        assertEq(neutronBefore - reactor.NEUTRON_TOKEN().balanceOf(alice), expectedNeutronBurn);
        assertEq(protonBefore - reactor.PROTON_TOKEN().balanceOf(alice), expectedProtonBurn);
        assertEq(baseToken.balanceOf(alice) - baseBefore, netBaseOut);
        assertEq(feeAmount, 90e18 * 3 / 100);
    }

    function test_previewTransmuteProtonToNeutron_matchesExecutionWithDecay() external {
        vm.prank(alice);
        reactor.fission(300e18, alice, new bytes[](0));

        vm.prank(treasury);
        reactor.setBetaParams(0.05e18, 0.1e18, 0.999e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        reactor.transmuteProtonToNeutron(20e18, alice, new bytes[](0));

        vm.warp(block.timestamp + 25);
        (uint256 expectedNeutronOut, uint256 expectedFeeWad,,) = reactor.previewTransmuteProtonToNeutron(15e18);
        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(alice);
        uint256 protonBefore = reactor.PROTON_TOKEN().balanceOf(alice);

        vm.prank(alice);
        (uint256 actualNeutronOut, uint256 actualFeeWad) =
            reactor.transmuteProtonToNeutron(15e18, alice, new bytes[](0));

        assertEq(actualNeutronOut, expectedNeutronOut);
        assertEq(actualFeeWad, expectedFeeWad);
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(alice) - neutronBefore, expectedNeutronOut);
        assertEq(protonBefore - reactor.PROTON_TOKEN().balanceOf(alice), 15e18);
    }

    function test_previewTransmuteNeutronToProton_matchesExecution() external {
        vm.prank(alice);
        reactor.fission(300e18, alice, new bytes[](0));

        (uint256 expectedProtonOut, uint256 expectedFeeWad,,) = reactor.previewTransmuteNeutronToProton(30e18);
        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(alice);
        uint256 protonBefore = reactor.PROTON_TOKEN().balanceOf(alice);

        vm.prank(alice);
        (uint256 actualProtonOut, uint256 actualFeeWad) = reactor.transmuteNeutronToProton(30e18, alice, new bytes[](0));

        assertEq(actualProtonOut, expectedProtonOut);
        assertEq(actualFeeWad, expectedFeeWad);
        assertEq(neutronBefore - reactor.NEUTRON_TOKEN().balanceOf(alice), 30e18);
        assertEq(reactor.PROTON_TOKEN().balanceOf(alice) - protonBefore, expectedProtonOut);
    }
}
