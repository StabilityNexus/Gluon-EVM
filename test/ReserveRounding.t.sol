// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockOracle} from "./GenericIOracleIntegration.t.sol";
import {MockDecimalERC20} from "./GluonIntegration.t.sol";

contract RoundingHarness is StableCoinReactor {
    constructor(address base, address oracle, uint256 protocolFee, uint256 devRate)
        StableCoinReactor(
            "Rounding",
            "Base",
            "B",
            "Neutron",
            "N",
            base,
            oracle,
            "Proton",
            "P",
            address(1),
            devRate,
            protocolFee,
            protocolFee,
            12e17,
            protocolFee,
            0,
            1e18
        )
    {}

    function fees(uint256 amount, uint256 rate) external view returns (uint256, uint256, uint256) {
        return _deductFees(amount, rate);
    }

    function target(uint256 price, Math.Rounding rounding) external view returns (uint256) {
        return _normalizedTargetPriceInBase(price, rounding);
    }

    function ratio(uint256 r, uint256 n, uint256 price) external view returns (uint256) {
        return _reserveRatioWad(r, n, price);
    }
}

contract ReserveRoundingTest is Test {
    uint256 private constant WAD = 1e18;
    address private user = makeAddr("rounding user");
    MockDecimalERC20 private base;
    GenericMockOracle private oracle;
    RoundingHarness private reactor;
    uint256 private unit;

    function _deploy(uint8 decimals_, uint256 price, uint256 protocolFee, uint256 devRate) private {
        unit = 10 ** uint256(decimals_);
        base = new MockDecimalERC20("Base", "B", decimals_);
        oracle = new GenericMockOracle(price);
        reactor = new RoundingHarness(address(base), address(oracle), protocolFee, devRate);
        base.mint(address(this), 100 * unit);
        base.approve(address(reactor), 100 * unit);
        reactor.initialFission(100 * unit, 15e17);
        _deposit(100 * unit);
    }

    function _deposit(uint256 amount) private {
        base.mint(user, amount);
        vm.startPrank(user);
        base.approve(address(reactor), amount);
        reactor.fission(amount, user);
        vm.stopPrank();
    }

    function _recover() private {
        uint256 count;
        while (
            (reactor.reserveRatioPeggedAsset() < reactor.CRITICAL_RESERVE_RATIO()
                    || reactor.reserveRatioPeggedAsset() > reactor.UPPER_RESERVE_RATIO()) && count < 10000
        ) {
            reactor.adjustPeg();
            ++count;
        }
        assertGe(reactor.reserveRatioPeggedAsset(), reactor.CRITICAL_RESERVE_RATIO());
        assertLe(reactor.reserveRatioPeggedAsset(), reactor.UPPER_RESERVE_RATIO());
    }

    function testTinyFusionBurnsBothClaimsInsteadOfRejecting() public {
        _deploy(18, WAD, 0, 0);
        uint256 n = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 p = reactor.PROTON_TOKEN().balanceOf(user);
        vm.prank(user);
        reactor.fusion(1, user);
        assertEq(n - reactor.NEUTRON_TOKEN().balanceOf(user), 1);
        assertEq(p - reactor.PROTON_TOKEN().balanceOf(user), 1);
        assertEq(base.balanceOf(user), 1);
    }

    function testFuzzReserveRatioMatchesUnroundedReference(uint64 rRaw, uint64 nRaw, uint64 priceRaw) public {
        _deploy(18, WAD, 0, 0);
        oracle.setValue(2 * WAD);
        reactor.adjustPeg();
        uint256 r = bound(rRaw, 0, WAD);
        uint256 n = bound(nRaw, 1, WAD);
        uint256 price = bound(priceRaw, 1, 1e19);
        // Bounded products fit uint256: one independent final division.
        uint256 expected = r * price * reactor.PEG_FACTOR_SCALE() / (n * reactor.pegFactor());
        assertEq(reactor.ratio(r, n, price), expected);
    }

    function testReserveRatioSaturatesInsteadOfOverflowing() public {
        _deploy(18, WAD, 0, 0);
        assertEq(reactor.ratio(type(uint256).max, 1, type(uint256).max), type(uint256).max);
        oracle.setValue(WAD / 2);
        reactor.adjustPeg();
        assertEq(reactor.ratio(type(uint256).max, 1, 1), type(uint256).max);
    }

    function testSmallSupplyDoesNotPrematurelyEnterOperatingRange() public {
        unit = 1;
        base = new MockDecimalERC20("Base", "B", 0);
        oracle = new GenericMockOracle(1);
        reactor = new RoundingHarness(address(base), address(oracle), 0, 0);
        base.mint(address(this), 3);
        base.approve(address(reactor), 3);
        reactor.initialFission(3, 15e17);
        _deposit(3);
        assertEq(reactor.NEUTRON_TOKEN().totalSupply(), 4);
        oracle.setValue(2);
        _recover();
        uint256 actual = reactor.reserve() * WAD * 2 * reactor.PEG_FACTOR_SCALE()
            / (reactor.NEUTRON_TOKEN().totalSupply() * reactor.pegFactor());
        assertEq(reactor.reserveRatioPeggedAsset(), actual);
        assertLe(actual, reactor.UPPER_RESERVE_RATIO());
        assertGt(reactor.protonPriceInBase(), 0);
    }

    function testSmallSeedRecoversAfterTinyPositivePriceAndRestoration() public {
        unit = WAD;
        base = new MockDecimalERC20("Base", "B", 18);
        oracle = new GenericMockOracle(WAD);
        reactor = new RoundingHarness(address(base), address(oracle), 0, 0);
        base.mint(address(this), 3);
        base.approve(address(reactor), 3);
        reactor.initialFission(3, 15e17);
        _deposit(3);
        oracle.setValue(1);
        _recover();
        assertGt(reactor.protonPriceInBase(), 0);
        vm.prank(user);
        reactor.fusion(1, user);
        assertEq(base.balanceOf(user), 1);
        oracle.setValue(WAD);
        _recover();
    }

    function testOraclePriceWhoseWadDenominatorOverflowsStillHasDefinedEquity() public {
        _deploy(18, 1e60, 0, 0);
        uint256 liability = Math.ceilDiv(reactor.NEUTRON_TOKEN().totalSupply(), 1e42);
        uint256 expected = Math.mulDiv(reactor.reserve() - liability, WAD, reactor.PROTON_TOKEN().totalSupply());
        assertEq(reactor.protonPriceInBase(), expected);
    }

    function testTinyFissionCanDonateWithoutMinting() public {
        _deploy(18, WAD, 0, 0);
        uint256 r = reactor.reserve();
        uint256 n = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 p = reactor.PROTON_TOKEN().balanceOf(user);
        _deposit(1);
        assertEq(reactor.reserve(), r + 1);
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), n);
        assertEq(reactor.PROTON_TOKEN().balanceOf(user), p);
    }

    function testTinyFeeRemainderStaysInReserve() public {
        _deploy(18, WAD, 1e15, 1e15);
        (uint256 net, uint256 retained, uint256 paid) = reactor.fees(1, 1e15);
        assertEq(net, 0);
        assertEq(retained, 1);
        assertEq(paid, 0);
        uint256 r = reactor.reserve();
        uint256 d = base.balanceOf(address(1));
        _deposit(1);
        assertEq(reactor.reserve(), r + 1);
        assertEq(base.balanceOf(address(1)), d);
    }

    function testFuzzFissionNeverOvermintsAfterPegAdjustment(uint96 rawAmount, uint8 decimals_) public {
        _deploy(decimals_ % 19, WAD, 0, 0);
        oracle.setValue(2 * WAD);
        _recover();
        uint256 amount = bound(rawAmount, 1, 10 * unit);
        uint256 r = reactor.reserve();
        uint256 n = reactor.NEUTRON_TOKEN().totalSupply();
        uint256 p = reactor.PROTON_TOKEN().totalSupply();
        uint256 nBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 pBefore = reactor.PROTON_TOKEN().balanceOf(user);
        _deposit(amount);
        uint256 nOut = reactor.NEUTRON_TOKEN().balanceOf(user) - nBefore;
        uint256 pOut = reactor.PROTON_TOKEN().balanceOf(user) - pBefore;
        assertLe(nOut * r, amount * n);
        assertLe(pOut * r, amount * p);
        assertGt((nOut + 1) * r, amount * n);
        assertGt((pOut + 1) * r, amount * p);
    }

    function testFuzzFusionChargesTheSmallestSufficientBurn(uint96 rawAmount, uint8 decimals_) public {
        _deploy(decimals_ % 19, 7e17, 0, 0);
        uint256 amount = bound(rawAmount, 1, 10 * unit);
        uint256 r = reactor.reserve();
        uint256 n = reactor.NEUTRON_TOKEN().totalSupply();
        uint256 p = reactor.PROTON_TOKEN().totalSupply();
        uint256 nBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 pBefore = reactor.PROTON_TOKEN().balanceOf(user);
        vm.prank(user);
        reactor.fusion(amount, user);
        uint256 nBurn = nBefore - reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 pBurn = pBefore - reactor.PROTON_TOKEN().balanceOf(user);
        assertGe(nBurn * r, amount * n);
        assertGe(pBurn * r, amount * p);
        assertLt((nBurn - 1) * r, amount * n);
        assertLt((pBurn - 1) * r, amount * p);
        assertEq(base.balanceOf(user), amount);
    }

    function testFuzzFeeRoundingConservesGrossAmount(uint128 amount, uint64 rateRaw, uint64 devRaw) public {
        uint256 rate = bound(rateRaw, 0, 2e17);
        uint256 devRate = bound(devRaw, 0, 1e17);
        _deploy(18, WAD, rate, devRate);
        (uint256 net, uint256 retained, uint256 paid) = reactor.fees(amount, rate);
        uint256 numerator = uint256(amount) * (WAD - rate - devRate);
        assertLe(net * WAD, numerator);
        assertGt((net + 1) * WAD, numerator);
        assertLe(paid * WAD, uint256(amount) * devRate);
        assertGt((paid + 1) * WAD, uint256(amount) * devRate);
        assertEq(net + retained + paid, amount);
        assertGe(retained * WAD, uint256(amount) * rate);
    }

    function testFuzzTargetPriceBoundsExactFraction(uint128 priceRaw) public {
        _deploy(18, WAD, 0, 0);
        uint256 price = bound(priceRaw, 1, 1e40);
        oracle.setValue(2 * WAD);
        reactor.adjustPeg();
        uint256 factor = reactor.pegFactor();
        uint256 low = reactor.target(price, Math.Rounding.Floor);
        uint256 high = reactor.target(price, Math.Rounding.Ceil);
        assertLe(low * price, factor);
        assertGe(high * price, factor);
        assertLe(high - low, 1);
    }

    function _assertTradeValue(uint256 input, bool plus) private {
        uint256 r = reactor.reserve() * WAD / unit;
        uint256 n = reactor.NEUTRON_TOKEN().totalSupply();
        uint256 p = reactor.PROTON_TOKEN().totalSupply();
        uint256 factor = reactor.pegFactor();
        uint256 price = oracle.readValue();
        uint256 a = factor;
        uint256 b = price;
        while (b != 0) (a, b) = (b, a % b);
        factor /= a;
        price /= a;

        // Exact rational values, independent of the reactor's rounded views.
        uint256 equityNumerator = r * WAD * price - n * factor;
        uint256 receiverBefore = base.balanceOf(address(1));
        vm.prank(user);
        if (plus) {
            (uint256 output,) = reactor.transmuteProtonToNeutron(input, 0, user);
            uint256 paid = (base.balanceOf(address(1)) - receiverBefore) * WAD / unit;
            assertLe((output * factor + paid * WAD * price) * p, input * equityNumerator);
        } else {
            (uint256 output,) = reactor.transmuteNeutronToProton(input, 0, user);
            uint256 paid = (base.balanceOf(address(1)) - receiverBefore) * WAD / unit;
            assertLe(output * equityNumerator + paid * WAD * price * p, input * factor * p);
        }
    }

    function testFuzzPlusCannotMintMoreValueThanBurned(
        uint96 inputRaw,
        uint8 exponent,
        uint8 multiplier,
        uint8 decimals_
    ) public {
        _deploy(decimals_ % 19, (uint256(multiplier % 30) + 1) * 10 ** uint256(exponent % 41), 0, 0);
        _assertTradeValue(bound(inputRaw, 1, Math.min(WAD, reactor.PROTON_TOKEN().balanceOf(user))), true);
    }

    function testFuzzMinusCannotMintMoreValueThanBurned(
        uint96 inputRaw,
        uint8 exponent,
        uint8 multiplier,
        uint8 decimals_
    ) public {
        _deploy(decimals_ % 19, (uint256(multiplier % 30) + 1) * 10 ** uint256(exponent % 41), 0, 0);
        _assertTradeValue(bound(inputRaw, 1, Math.min(WAD, reactor.NEUTRON_TOKEN().balanceOf(user))), false);
    }

    function testFuzzTransmutationDevFeeIsIncludedInValueConservation(uint96 inputRaw, bool plus) public {
        _deploy(6, 7e17, 1e16, 1e15);
        _assertTradeValue(bound(inputRaw, 1, WAD), plus);
    }

    function testSubWadNeutronPriceCannotOvervalueProtonInput() public {
        _deploy(18, 7e35, 0, 0);
        _assertTradeValue(WAD, true);
    }

    function testFractionalProtonPriceCannotOvermintProtonOutput() public {
        _deploy(18, 555743815175906607, 0, 0);
        _assertTradeValue(671256924127914318, false);
    }

    function testRoundedZeroPricePreservesNoOpsAndMinimumErrors() public {
        _deploy(18, 2e36, 0, 0);
        assertEq(reactor.neutronPriceInBase(), 0);
        uint256 nBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 pBefore = reactor.PROTON_TOKEN().balanceOf(user);
        uint256 r = reactor.reserve();
        vm.startPrank(user);
        (uint256 nOut,) = reactor.transmuteProtonToNeutron(WAD, 0, user);
        (uint256 pOut,) = reactor.transmuteNeutronToProton(WAD, 0, user);
        assertEq(nOut, 0);
        assertEq(pOut, 0);
        vm.expectRevert(StableCoinReactor.ExcessiveSlippage.selector);
        reactor.transmuteProtonToNeutron(WAD, 1, user);
        vm.expectRevert(StableCoinReactor.ExcessiveSlippage.selector);
        reactor.transmuteNeutronToProton(WAD, 1, user);
        vm.stopPrank();
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), nBefore);
        assertEq(reactor.PROTON_TOKEN().balanceOf(user), pBefore);
        assertEq(reactor.reserve(), r);
    }

    function testFuzzValueConservationAfterPegAdjustment(uint96 inputRaw, bool plus) public {
        _deploy(18, 7e17, 1e16, 1e15);
        oracle.setValue(14e17);
        _recover();
        _assertTradeValue(bound(inputRaw, 1, WAD), plus);
    }

    function testEverySupportedDecimalCountSupportsReserveSafeFusion() public {
        for (uint8 decimals_; decimals_ <= 18; ++decimals_) {
            _deploy(decimals_, WAD, 0, 0);
            uint256 nBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
            uint256 pBefore = reactor.PROTON_TOKEN().balanceOf(user);
            vm.prank(user);
            reactor.fusion(1, user);
            assertLt(reactor.NEUTRON_TOKEN().balanceOf(user), nBefore);
            assertLt(reactor.PROTON_TOKEN().balanceOf(user), pBefore);
            assertEq(base.balanceOf(user), 1);
        }
    }

    function testFuzzFissionFusionRoundTripCannotExtractReserve(uint96 amountRaw, uint8 decimals_) public {
        _deploy(decimals_ % 19, 1234567890123456789, 0, 0);
        uint256 amount = bound(amountRaw, 1, 10 * unit);
        address trader = makeAddr("round-trip trader");
        base.mint(trader, amount);
        vm.startPrank(trader);
        base.approve(address(reactor), amount);
        reactor.fission(amount, trader);
        uint256 redeemable = Math.min(
            Math.mulDiv(
                reactor.NEUTRON_TOKEN().balanceOf(trader), reactor.reserve(), reactor.NEUTRON_TOKEN().totalSupply()
            ),
            Math.mulDiv(
                reactor.PROTON_TOKEN().balanceOf(trader), reactor.reserve(), reactor.PROTON_TOKEN().totalSupply()
            )
        );
        assertLe(redeemable, amount);
        if (redeemable != 0) reactor.fusion(redeemable, trader);
        vm.stopPrank();
        assertLe(base.balanceOf(trader), amount);
    }

    function testRepeatedFeeFreeRoundTripsCannotIncreaseTokens() public {
        _deploy(18, 7e17, 0, 0);
        uint256 beforeBalance = reactor.PROTON_TOKEN().balanceOf(user);
        uint256 nBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 reserveBefore = reactor.reserve();
        vm.startPrank(user);
        for (uint256 i; i < 100; ++i) {
            (uint256 nOut,) = reactor.transmuteProtonToNeutron(1e15 + i, 0, user);
            if (nOut != 0) {
                reactor.transmuteNeutronToProton(nOut, 0, user);
            }
        }
        vm.stopPrank();
        assertLe(reactor.PROTON_TOKEN().balanceOf(user), beforeBalance);
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), nBefore);
        assertEq(reactor.reserve(), reserveBefore);
    }

    function testTinyOutputKeepsMinimumProtection() public {
        _deploy(18, WAD, 0, 0);
        oracle.setValue(7e17);
        _recover();
        vm.startPrank(user);
        vm.expectRevert(StableCoinReactor.ExcessiveSlippage.selector);
        reactor.transmuteProtonToNeutron(1, 1, user);
        uint256 pBefore = reactor.PROTON_TOKEN().balanceOf(user);
        (uint256 output,) = reactor.transmuteProtonToNeutron(1, 0, user);
        assertEq(output, 0);
        assertEq(reactor.PROTON_TOKEN().balanceOf(user), pBefore - 1);
        vm.stopPrank();
    }

    function testUnrepresentablySmallProtonPriceRoundsToZeroWithoutOverflow() public {
        _deploy(18, 1e60, 0, 0);
        oracle.setValue(1);
        assertEq(reactor.protonPriceInBase(), 0);
    }

    function testLargePriceRecoveryKeepsProtonPriceReadable() public {
        _deploy(18, 1e60, 0, 0);
        oracle.setValue(1e76);
        _recover();
        assertGt(reactor.protonPriceInBase(), 0);
    }
}
