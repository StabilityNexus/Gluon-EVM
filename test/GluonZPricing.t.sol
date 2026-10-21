// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockOracle} from "./GenericIOracleIntegration.t.sol";
import {MockDecimalERC20} from "./GluonIntegration.t.sol";

contract GluonZPricingHarness is StableCoinReactor {
    constructor(address base, address oracle, uint256 devRate)
        StableCoinReactor(
            "Gluon Z",
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
            0,
            0,
            1e18 + 1,
            0,
            0,
            1e18
        )
    {}

    function setPegFactor(uint256 factor) external {
        pegFactor = factor;
    }

    function allocations(uint256 r, uint256 n, uint256 price, Math.Rounding rounding)
        external
        view
        returns (uint256, uint256)
    {
        return (_liabilities(r, n, price, rounding), _equity(r, n, price, rounding));
    }

    function prices(uint256 r, uint256 n, uint256 p, uint256 price, Math.Rounding rounding)
        external
        view
        returns (uint256, uint256)
    {
        return (_neutronPriceInBase(r, n, price, rounding), _protonPriceInBase(r, p, n, price, rounding));
    }
}

contract GluonZPricingTest is Test {
    uint256 private constant WAD = 1e18;
    GluonZPricingHarness private reactor;

    function setUp() public {
        MockDecimalERC20 base = new MockDecimalERC20("Base", "B", 18);
        GenericMockOracle oracle = new GenericMockOracle(WAD);
        reactor = new GluonZPricingHarness(address(base), address(oracle), 0);
    }

    function testPricesRemainAtTargetBeforeNormalization() public view {
        (uint256 nPrice, uint256 pPrice) = reactor.prices(100 * WAD, 80 * WAD, 20 * WAD, WAD, Math.Rounding.Floor);
        assertEq(nPrice, WAD);
        assertEq(pPrice, WAD);
    }

    function testEqualTargetLiabilitiesLeavePositiveEquity() public view {
        (uint256 liabilities, uint256 equity) = reactor.allocations(100 * WAD, 100 * WAD, WAD, Math.Rounding.Floor);
        assertLt(liabilities, 100 * WAD);
        assertGt(equity, 0);
        assertLe(liabilities, 10000 * WAD / 101);
        assertLe(equity, 100 * WAD / 101);
        (uint256 nPrice, uint256 pPrice) = reactor.prices(100 * WAD, 100 * WAD, WAD, WAD, Math.Rounding.Floor);
        assertGt(nPrice, 0);
        assertGt(pPrice, 0);
    }

    function testTargetLiabilitiesAboveReserveLeavePositiveEquity() public view {
        (uint256 liabilities, uint256 equity) = reactor.allocations(100 * WAD, 200 * WAD, WAD, Math.Rounding.Floor);
        assertGt(liabilities, 99 * WAD);
        assertLt(liabilities, 100 * WAD);
        assertGt(equity, 0);
        assertLe(equity, 100 * WAD / 201);
    }

    function testNormalizationIsNotAFixedNinetyNinePercentCap() public view {
        (uint256 liabilities,) = reactor.allocations(100 * WAD, 1000 * WAD, WAD, Math.Rounding.Floor);
        assertGt(liabilities, 99 * WAD);
        assertLt(liabilities, 100 * WAD);
    }

    function testFullWidthReserveAndSupplyDoNotRoundEquityToZeroPrematurely() public view {
        (, uint256 equity) = reactor.allocations(type(uint256).max, type(uint256).max, 1, Math.Rounding.Floor);
        assertGt(equity, 0);
    }

    function testTargetCeilingAtUint256LimitDoesNotOverflow() public {
        uint256 denominator = type(uint256).max / WAD * WAD;
        reactor.setPegFactor(denominator + 1);
        (, uint256 equity) =
            reactor.allocations(type(uint256).max, type(uint256).max - 1, denominator / WAD, Math.Rounding.Floor);
        assertGt(equity, 0);
    }

    function testFuzzFullWidthAllocationBoundsDoNotOverflow(uint256 r, uint256 n, uint256 price, uint256 factor)
        public
    {
        reactor.setPegFactor(bound(factor, 1, type(uint256).max));
        (uint256 lLow, uint256 eLow) = reactor.allocations(r, n, price, Math.Rounding.Floor);
        (uint256 lHigh, uint256 eHigh) = reactor.allocations(r, n, price, Math.Rounding.Ceil);
        assertLe(lLow, lHigh);
        assertLe(eLow, eHigh);
        assertLe(lHigh, r);
        assertEq(lLow + eHigh, r);
        assertEq(lHigh + eLow, r);
    }

    function testEmptyNeutronSupplyHasNoLiabilities() public view {
        (uint256 liabilities, uint256 equity) = reactor.allocations(100 * WAD, 0, WAD, Math.Rounding.Floor);
        assertEq(liabilities, 0);
        assertEq(equity, 100 * WAD);
    }

    function testZeroOraclePricePreservesReserveBackedNeutronPricing() public view {
        (uint256 nPrice, uint256 pPrice) = reactor.prices(100 * WAD, 50 * WAD, 50 * WAD, 0, Math.Rounding.Floor);
        assertEq(nPrice, 2 * WAD);
        assertEq(pPrice, 0);
    }

    function testNormalizationThresholdAndAdjacentAmounts() public view {
        for (uint256 n = 99 * WAD - 1; n <= 99 * WAD + 1; ++n) {
            _assertBounds(100 * WAD, n, WAD, WAD);
        }
    }

    function testFuzzAllocationsAndPricesBoundExactGluonZEquation(
        uint64 rRaw,
        uint64 nRaw,
        uint96 priceRaw,
        uint64 pRaw
    ) public view {
        _assertBounds(bound(rRaw, 1, 1e12), bound(nRaw, 1, 1e12), bound(priceRaw, 1, 1e24), bound(pRaw, 1, 1e12));
    }

    function _assertBounds(uint256 r, uint256 n, uint256 price, uint256 p) private view {
        // Independent rational reference, with products bounded to fit uint256.
        (uint256 numerator, uint256 denominator) = _reference(r, n, price);
        (uint256 lLow, uint256 eLow) = reactor.allocations(r, n, price, Math.Rounding.Floor);
        (uint256 lHigh, uint256 eHigh) = reactor.allocations(r, n, price, Math.Rounding.Ceil);
        assertLe(lLow * denominator, numerator);
        assertGe(lHigh * denominator, numerator);
        assertLe(eLow * denominator, r * denominator - numerator);
        assertGe(eHigh * denominator, r * denominator - numerator);
        assertEq(lLow + eHigh, r);
        assertEq(lHigh + eLow, r);
        assertLe(lHigh, r);
        (uint256 nLow, uint256 pLow) = reactor.prices(r, n, p, price, Math.Rounding.Floor);
        (uint256 nHigh, uint256 pHigh) = reactor.prices(r, n, p, price, Math.Rounding.Ceil);
        assertLe(nLow, Math.mulDiv(numerator, WAD, denominator * n));
        assertGe(nHigh, Math.mulDiv(numerator, WAD, denominator * n, Math.Rounding.Ceil));
        assertLe(pLow, Math.mulDiv(r * denominator - numerator, WAD, denominator * p));
        assertGe(pHigh, Math.mulDiv(r * denominator - numerator, WAD, denominator * p, Math.Rounding.Ceil));
    }

    function testFuzzNormalizedTradesConserveValueIncludingDevFee(
        uint32 inputRaw,
        bool plus,
        uint8 decimalsRaw,
        bool withDevFee
    ) public {
        uint8 decimals = decimalsRaw % 19;
        uint256 unit = 10 ** uint256(decimals);
        MockDecimalERC20 base = new MockDecimalERC20("Base", "B", decimals);
        GenericMockOracle oracle = new GenericMockOracle(WAD);
        reactor = new GluonZPricingHarness(address(base), address(oracle), withDevFee ? 1e15 : 0);
        base.mint(address(this), 2000 * unit);
        base.approve(address(reactor), 2000 * unit);
        reactor.initialFission(1000 * unit, 15e17);
        reactor.fission(1000 * unit, address(this));
        oracle.setValue(67e16);

        uint256 r = reactor.reserve() * WAD / unit;
        uint256 n = reactor.NEUTRON_TOKEN().totalSupply();
        uint256 p = reactor.PROTON_TOKEN().totalSupply();
        (uint256 numerator, uint256 denominator) = _reference(r, n, 67e16);
        uint256 equityNumerator = r * denominator - numerator;
        uint256 input = bound(inputRaw, 1, 1e9);
        uint256 receiverBefore = base.balanceOf(address(1));
        assertGe(reactor.reserveRatioPeggedAsset(), reactor.CRITICAL_RESERVE_RATIO());
        assertLt(Math.mulDiv(n, 1e36, 67e16 * WAD), r);
        assertGt(Math.mulDiv(n, 1e36, 67e16 * WAD), Math.mulDiv(r, 99, 100));
        if (plus) {
            (uint256 output,) = reactor.transmuteProtonToNeutron(input, 0, address(this));
            uint256 paid = (base.balanceOf(address(1)) - receiverBefore) * WAD / unit;
            assertLe((output * numerator + paid * denominator * n) * p, input * equityNumerator * n);
        } else {
            (uint256 output,) = reactor.transmuteNeutronToProton(input, 0, address(this));
            uint256 paid = (base.balanceOf(address(1)) - receiverBefore) * WAD / unit;
            assertLe((output * equityNumerator + paid * denominator * p) * n, input * numerator * p);
        }
    }

    function _reference(uint256 r, uint256 n, uint256 price)
        private
        view
        returns (uint256 numerator, uint256 denominator)
    {
        uint256 common = _gcd(reactor.pegFactor(), price);
        uint256 targetNumerator = n * (reactor.pegFactor() / common);
        uint256 targetDenominator = price / common * WAD;
        if (100 * targetNumerator <= 99 * r * targetDenominator) {
            numerator = targetNumerator;
            denominator = targetDenominator;
        } else {
            numerator = 100 * r * targetNumerator;
            denominator = 100 * targetNumerator + r * targetDenominator;
        }
        common = _gcd(numerator, denominator);
        numerator /= common;
        denominator /= common;
    }

    function _gcd(uint256 a, uint256 b) private pure returns (uint256) {
        while (b != 0) (a, b) = (b, a % b);
        return a;
    }
}
