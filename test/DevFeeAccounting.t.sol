// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm, stdError} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockOracle} from "./GenericIOracleIntegration.t.sol";
import {MockDecimalERC20} from "./GluonIntegration.t.sol";

contract DevFeeAccountingTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant DEV_FEE = 1e15;
    address private dev = makeAddr("dev authority");
    address private receiver = dev;
    address private user = makeAddr("fee user");

    event Fission(
        address indexed from,
        address indexed to,
        uint256 baseIn,
        uint256 neutronOut,
        uint256 protonOut,
        uint256 protocolFee,
        uint256 devFeeAmount
    );
    event Fusion(
        address indexed from,
        address indexed to,
        uint256 neutronBurn,
        uint256 protonBurn,
        uint256 baseOut,
        uint256 protocolFee,
        uint256 devFeeAmount
    );
    event TransmutePlus(
        address indexed from,
        address indexed to,
        uint256 protonIn,
        uint256 neutronOut,
        uint256 feeWad,
        uint256 newDecayedVolumePlusBase,
        uint256 newDecayedVolumeMinusBase,
        uint256 devFeeAmount
    );
    event TransmuteMinus(
        address indexed from,
        address indexed to,
        uint256 neutronIn,
        uint256 protonOut,
        uint256 feeWad,
        uint256 newDecayedVolumePlusBase,
        uint256 newDecayedVolumeMinusBase,
        uint256 devFeeAmount
    );

    function _deploy(uint8 decimals_, uint256 fissionFee, uint256 fusionFee, uint256 betaFee, uint256 devRate)
        private
        returns (MockDecimalERC20 base, StableCoinReactor reactor)
    {
        base = new MockDecimalERC20("Base", "B", decimals_);
        StableCoinFactory factory = new StableCoinFactory();
        GenericMockOracle oracle = new GenericMockOracle(WAD);
        uint256 seed = 100 * 10 ** uint256(decimals_);
        base.mint(address(this), seed);
        base.approve(address(factory), seed);
        reactor = StableCoinReactor(
            factory.deployReactor(
                "Vault",
                "Base",
                "B",
                "Neutron",
                "N",
                address(base),
                address(oracle),
                "Proton",
                "P",
                dev,
                devRate,
                fissionFee,
                fusionFee,
                12e17,
                seed,
                betaFee,
                0,
                WAD
            )
        );
    }

    function _fund(MockDecimalERC20 base, StableCoinReactor reactor, uint256 amount) private {
        base.mint(user, amount);
        vm.startPrank(user);
        base.approve(address(reactor), amount);
        reactor.fission(amount, user);
        vm.stopPrank();
    }

    function testInitialProtocolFeeStaysInReserveAndOnlyDevFeeIsPaid() public {
        (MockDecimalERC20 base, StableCoinReactor reactor) = _deploy(18, 2e16, 3e16, 1e16, DEV_FEE);
        assertEq(base.balanceOf(receiver), 1e17);
        assertEq(reactor.devFeeReceiver(), reactor.dev());
        assertEq(reactor.reserve(), 999e17);
        assertEq(reactor.dev(), dev);
        assertEq(reactor.devFeeReceiver(), receiver);
        assertEq(reactor.devFee(), DEV_FEE);
        uint256 credited = 979e17;
        assertEq(reactor.NEUTRON_TOKEN().totalSupply(), Math.mulDiv(credited, WAD, 15e17));
        assertEq(reactor.PROTON_TOKEN().totalSupply(), credited - Math.mulDiv(credited, WAD, 15e17));
    }

    function testFissionAndFusionChargeBothFeesOnGrossAmounts() public {
        (MockDecimalERC20 base, StableCoinReactor reactor) = _deploy(18, 2e16, 3e16, 1e16, DEV_FEE);
        uint256 reserveBefore = reactor.reserve();
        uint256 receiverBefore = base.balanceOf(receiver);
        uint256 nSupply = reactor.NEUTRON_TOKEN().totalSupply();
        uint256 pSupply = reactor.PROTON_TOKEN().totalSupply();
        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();
        base.mint(user, 20e18);
        vm.startPrank(user);
        base.approve(address(reactor), 20e18);
        vm.expectEmit(true, true, false, true, address(reactor));
        emit Fission(
            user,
            user,
            20e18,
            Math.mulDiv(1958e16, WAD, ratioBefore),
            Math.mulDiv(1958e16, pSupply, reserveBefore),
            4e17,
            2e16
        );
        reactor.fission(20e18, user);
        vm.stopPrank();
        assertEq(reactor.reserve(), reserveBefore + 20e18 - 2e16);
        assertEq(base.balanceOf(receiver), receiverBefore + 2e16);
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), Math.mulDiv(1958e16, WAD, ratioBefore));
        assertEq(reactor.PROTON_TOKEN().balanceOf(user), Math.mulDiv(1958e16, pSupply, reserveBefore));
        reserveBefore = reactor.reserve();
        nSupply = reactor.NEUTRON_TOKEN().totalSupply();
        pSupply = reactor.PROTON_TOKEN().totalSupply();
        uint256 nBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 pBefore = reactor.PROTON_TOKEN().balanceOf(user);
        receiverBefore = base.balanceOf(receiver);
        vm.expectEmit(true, true, false, true, address(reactor));
        emit Fusion(
            user,
            user,
            Math.mulDiv(10e18, nSupply, reserveBefore),
            Math.mulDiv(10e18, pSupply, reserveBefore),
            969e16,
            3e17,
            1e16
        );
        vm.prank(user);
        reactor.fusion(10e18, user);
        assertEq(base.balanceOf(user), 969e16);
        assertEq(base.balanceOf(receiver), receiverBefore + 1e16);
        assertEq(reactor.reserve(), reserveBefore - 97e17);
        assertEq(nBefore - reactor.NEUTRON_TOKEN().balanceOf(user), Math.mulDiv(10e18, nSupply, reserveBefore));
        assertEq(pBefore - reactor.PROTON_TOKEN().balanceOf(user), Math.mulDiv(10e18, pSupply, reserveBefore));
    }

    function testBothBetaDirectionsRetainProtocolFeeAndPaySeparateDevFee() public {
        (MockDecimalERC20 base, StableCoinReactor reactor) = _deploy(18, 0, 0, 1e16, DEV_FEE);
        _fund(base, reactor, 100e18);
        uint256 reserveBefore = reactor.reserve();
        uint256 receiverBefore = base.balanceOf(receiver);
        uint256 protonIn = 1e18;
        uint256 gross = Math.mulDiv(protonIn, reactor.protonPriceInBase(), WAD);
        uint256 expectedDevFee = Math.mulDiv(gross, DEV_FEE, WAD);
        uint256 expectedNet = gross - Math.mulDiv(gross, 1e16, WAD) - expectedDevFee;
        uint256 expectedOut = Math.mulDiv(expectedNet, WAD, reactor.neutronPriceInBase());
        uint256 nBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        vm.expectEmit(true, true, false, true, address(reactor));
        emit TransmutePlus(user, user, protonIn, expectedOut, 1e16, gross, 0, expectedDevFee);
        vm.prank(user);
        (uint256 neutronOut, uint256 fee) = reactor.transmuteProtonToNeutron(protonIn, 0, user);
        assertEq(fee, 1e16);
        assertEq(neutronOut, expectedOut);
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), nBefore + expectedOut);
        assertEq(reactor.reserve(), reserveBefore - expectedDevFee);
        assertEq(base.balanceOf(receiver), receiverBefore + expectedDevFee);
        reserveBefore = reactor.reserve();
        receiverBefore = base.balanceOf(receiver);
        uint256 plusVolume = gross;
        gross = reactor.neutronPriceInBase();
        expectedDevFee = Math.mulDiv(gross, DEV_FEE, WAD);
        expectedNet = gross - Math.mulDiv(gross, 1e16, WAD) - expectedDevFee;
        expectedOut = Math.mulDiv(expectedNet, WAD, reactor.protonPriceInBase());
        vm.expectEmit(true, true, false, true, address(reactor));
        emit TransmuteMinus(user, user, WAD, expectedOut, 1e16, plusVolume, gross, expectedDevFee);
        vm.prank(user);
        (uint256 protonOut, uint256 minusFee) = reactor.transmuteNeutronToProton(WAD, 0, user);
        assertEq(minusFee, 1e16);
        assertEq(protonOut, expectedOut);
        assertEq(reactor.reserve(), reserveBefore - expectedDevFee);
        assertEq(base.balanceOf(receiver), receiverBefore + expectedDevFee);
    }

    function testBetaPlusRangeCheckIncludesDevPaymentAndRollsBackOnFailure() public {
        (MockDecimalERC20 base, StableCoinReactor reactor) = _deploy(18, 0, 0, 0, DEV_FEE);
        _fund(base, reactor, 200e18);
        uint256 r = reactor.reserve();
        uint256 n = reactor.NEUTRON_TOKEN().totalSupply();
        uint256 maxOutput = Math.mulDiv(r, WAD, reactor.CRITICAL_RESERVE_RATIO()) - n - 1000;
        uint256 grossTarget = Math.mulDiv(maxOutput, WAD, WAD - DEV_FEE, Math.Rounding.Ceil);
        uint256 input = Math.mulDiv(grossTarget, WAD, reactor.protonPriceInBase(), Math.Rounding.Ceil);
        uint256 gross = Math.mulDiv(input, reactor.protonPriceInBase(), WAD);
        uint256 d = Math.mulDiv(gross, DEV_FEE, WAD);
        uint256 output = Math.mulDiv(gross - d, WAD, reactor.neutronPriceInBase());
        assertGe(Math.mulDiv(r, WAD, n + output), reactor.CRITICAL_RESERVE_RATIO());
        assertLt(Math.mulDiv(r - d, WAD, n + output), reactor.CRITICAL_RESERVE_RATIO());
        uint256 receiverBefore = base.balanceOf(receiver);
        uint256 userProtons = reactor.PROTON_TOKEN().balanceOf(user);
        vm.prank(user);
        vm.expectRevert(StableCoinReactor.ResultingReserveRatioBelowCritical.selector);
        reactor.transmuteProtonToNeutron(input, 0, user);
        assertEq(reactor.reserve(), r);
        assertEq(base.balanceOf(receiver), receiverBefore);
        assertEq(reactor.PROTON_TOKEN().balanceOf(user), userProtons);
        assertEq(reactor.NEUTRON_TOKEN().totalSupply(), n);
    }

    function testSixDecimalBetaPaymentUsesNativeReserveUnits() public {
        (MockDecimalERC20 base, StableCoinReactor reactor) = _deploy(6, 0, 0, 1e16, DEV_FEE);
        _fund(base, reactor, 100e6);
        uint256 gross = Math.mulDiv(1e18, reactor.protonPriceInBase(), WAD);
        uint256 expectedDevNative = Math.mulDiv(Math.mulDiv(gross, DEV_FEE, WAD), 1e6, WAD);
        uint256 r = reactor.reserve();
        uint256 before = base.balanceOf(receiver);
        uint256 devWad = Math.mulDiv(gross, DEV_FEE, WAD);
        uint256 expectedOut =
            Math.mulDiv(gross - Math.mulDiv(gross, 1e16, WAD) - devWad, WAD, reactor.neutronPriceInBase());
        vm.expectEmit(true, true, false, true, address(reactor));
        emit TransmutePlus(user, user, 1e18, expectedOut, 1e16, gross, 0, expectedDevNative);
        vm.prank(user);
        reactor.transmuteProtonToNeutron(1e18, 0, user);
        assertEq(reactor.reserve(), r - expectedDevNative);
        assertEq(base.balanceOf(receiver), before + expectedDevNative);
    }

    function testBetaEventReportsZeroWhenNativeDevPaymentRoundsToZero() public {
        (MockDecimalERC20 base, StableCoinReactor reactor) = _deploy(0, 0, 0, 0, DEV_FEE);
        _fund(base, reactor, 100);
        uint256 r = reactor.reserve();
        uint256 receiverBefore = base.balanceOf(receiver);
        uint256 gross = reactor.neutronPriceInBase();
        assertGt(Math.mulDiv(gross, DEV_FEE, WAD), 0);
        assertEq(Math.mulDiv(Math.mulDiv(gross, DEV_FEE, WAD), 1, WAD), 0);
        uint256 expectedOut = Math.mulDiv(gross - Math.mulDiv(gross, DEV_FEE, WAD), WAD, reactor.protonPriceInBase());
        vm.recordLogs();
        vm.expectEmit(true, true, false, true, address(reactor));
        emit TransmuteMinus(user, user, WAD, expectedOut, 0, 0, gross, 0);
        vm.prank(user);
        reactor.transmuteNeutronToProton(WAD, 0, user);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(base), "zero dev payment must not transfer base tokens");
        }
        assertEq(reactor.reserve(), r);
        assertEq(base.balanceOf(receiver), receiverBefore);
    }

    function testFuzzFissionBalanceConservationAcrossDecimals(uint8 decimals_, uint96 input) public {
        decimals_ = uint8(bound(decimals_, 0, 18));
        uint256 amount = bound(input, 2, 1e24);
        (MockDecimalERC20 base, StableCoinReactor reactor) = _deploy(decimals_, 2e16, 3e16, 0, DEV_FEE);
        uint256 r = reactor.reserve();
        uint256 d = base.balanceOf(receiver);
        _fund(base, reactor, amount);
        uint256 paid = Math.mulDiv(amount, DEV_FEE, WAD);
        assertEq(reactor.reserve(), r + amount - paid);
        assertEq(base.balanceOf(receiver), d + paid);
        assertEq(base.balanceOf(user), 0);
    }

    function testOneUnitDepositRevertsWithoutStateChange() public {
        (MockDecimalERC20 base, StableCoinReactor reactor) = _deploy(18, 2e16, 3e16, 0, DEV_FEE);
        uint256 r = reactor.reserve();
        uint256 d = base.balanceOf(receiver);
        base.mint(user, 1);
        vm.startPrank(user);
        base.approve(address(reactor), 1);
        vm.expectRevert(StableCoinReactor.AmountTooSmall.selector);
        reactor.fission(1, user);
        vm.stopPrank();
        assertEq(base.balanceOf(user), 1);
        assertEq(base.balanceOf(receiver), d);
        assertEq(reactor.reserve(), r);
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), 0);
        assertEq(reactor.PROTON_TOKEN().balanceOf(user), 0);
    }

    function testFullBetaFeeWithDevFeeRevertsWithoutPaying() public {
        (MockDecimalERC20 base, StableCoinReactor reactor) = _deploy(18, 0, 0, WAD, DEV_FEE);
        _fund(base, reactor, 100e18);
        uint256 r = reactor.reserve();
        uint256 d = base.balanceOf(receiver);
        vm.prank(user);
        vm.expectRevert(stdError.arithmeticError);
        reactor.transmuteNeutronToProton(1e18, 0, user);
        vm.prank(user);
        vm.expectRevert(stdError.arithmeticError);
        reactor.transmuteProtonToNeutron(1e18, 0, user);
        assertEq(reactor.reserve(), r);
        assertEq(base.balanceOf(receiver), d);
    }

    function testRejectsDevFeeAtOneHundredPercent() public {
        MockDecimalERC20 base = new MockDecimalERC20("Base", "B", 18);
        GenericMockOracle oracle = new GenericMockOracle(WAD);
        StableCoinFactory factory = new StableCoinFactory();
        vm.expectRevert(StableCoinFactory.InvalidDevFee.selector);
        factory.deployReactor(
            "Vault",
            "Base",
            "B",
            "Neutron",
            "N",
            address(base),
            address(oracle),
            "Proton",
            "P",
            dev,
            WAD,
            0,
            0,
            WAD,
            100e18,
            0,
            0,
            WAD
        );
    }
}
