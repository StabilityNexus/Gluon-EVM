// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockERC20, GenericMockOracle} from "./GenericIOracleIntegration.t.sol";

contract PegFactorRegressionTest is Test {
    StableCoinFactory private factory;
    GenericMockERC20 private base;
    address private user = makeAddr("peg regression user");
    address private dev = makeAddr("peg regression dev");

    function setUp() public {
        factory = new StableCoinFactory();
        base = new GenericMockERC20();
    }

    function _seed(uint256 price, uint256 deposit)
        private
        returns (StableCoinReactor reactor, GenericMockOracle oracle)
    {
        oracle = new GenericMockOracle(price);
        base.mint(address(this), 100e18);
        base.approve(address(factory), 100e18);
        reactor = StableCoinReactor(
            factory.deployReactor(
                "Peg Factor Vault",
                "Reserve",
                "BASE",
                "Pegged",
                "PEG",
                address(base),
                address(oracle),
                "Proton",
                "P",
                dev,
                0,
                0,
                0,
                14e17,
                15e17,
                100e18,
                0,
                0,
                1e18
            )
        );
        assertEq(reactor.pegFactor(), reactor.PEG_FACTOR_SCALE());
        base.mint(user, deposit);
        vm.startPrank(user);
        base.approve(address(reactor), deposit);
        reactor.fission(deposit, user);
        vm.stopPrank();
    }

    function _adjustIntoRange(StableCoinReactor reactor) private {
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

    function _redeem(StableCoinReactor reactor, uint256 amount) private {
        // Mint-down/burn-up can leave a bounded amount of redemption dust.
        uint256 requested = amount;
        uint256 maxDust = Math.max(
            Math.ceilDiv(reactor.reserve(), reactor.NEUTRON_TOKEN().totalSupply()),
            Math.ceilDiv(reactor.reserve(), reactor.PROTON_TOKEN().totalSupply())
        );
        amount = Math.min(
            amount,
            Math.mulDiv(
                reactor.NEUTRON_TOKEN().balanceOf(user), reactor.reserve(), reactor.NEUTRON_TOKEN().totalSupply()
            )
        );
        amount = Math.min(
            amount,
            Math.mulDiv(reactor.PROTON_TOKEN().balanceOf(user), reactor.reserve(), reactor.PROTON_TOKEN().totalSupply())
        );
        assertGt(amount, 0);
        assertLe(requested - amount, maxDust, "redemption lost more than rounding dust");
        uint256 beforeBalance = base.balanceOf(user);
        vm.prank(user);
        reactor.fusion(amount, user);
        assertEq(base.balanceOf(user) - beforeBalance, amount);
    }

    function testPracticalSupplySupportsTinyPositivePriceAndRestoredPrice() public {
        (StableCoinReactor reactor, GenericMockOracle oracle) = _seed(30e18, 100e18);
        oracle.setValue(1);
        _adjustIntoRange(reactor);
        assertGt(reactor.pegFactor(), 100);
        oracle.setValue(30e18);
        _adjustIntoRange(reactor);
        _redeem(reactor, 1e18);
    }

    function testExtremeSupplyPreservesPositiveFactorAndUpwardRecovery() public {
        (StableCoinReactor reactor, GenericMockOracle oracle) = _seed(1e40, 100e18);
        oracle.setValue(1);
        uint256 count;
        while (reactor.pegFactor() > 1 && count < 10000) {
            reactor.adjustPeg();
            ++count;
        }
        assertEq(reactor.pegFactor(), 1);
        reactor.adjustPeg();
        assertEq(reactor.pegFactor(), 1);
        oracle.setValue(1e40);
        reactor.adjustPeg();
        assertEq(reactor.pegFactor(), 2);
        _adjustIntoRange(reactor);
        _redeem(reactor, 1e18);
    }

    function testHigherPrecisionResolvesPreviouslyOscillatingTinyPrice() public {
        (StableCoinReactor reactor, GenericMockOracle oracle) = _seed(7e17, 100e18);
        oracle.setValue(1);
        _adjustIntoRange(reactor);
        assertGt(reactor.pegFactor(), 100);
        _redeem(reactor, 1e18);
        oracle.setValue(7e17);
        _adjustIntoRange(reactor);
        _redeem(reactor, 1e18);
    }

    function testFissionAndFusionRemainProportionalAcrossPegChanges() public {
        (StableCoinReactor reactor, GenericMockOracle oracle) = _seed(30e18, 100e18);
        oracle.setValue(60e18);
        _adjustIntoRange(reactor);
        base.mint(user, 125e16);
        vm.startPrank(user);
        base.approve(address(reactor), 125e16);
        reactor.fission(125e16, user);
        vm.stopPrank();
        oracle.setValue(30e18);
        _adjustIntoRange(reactor);
        _redeem(reactor, 125e16);
        assertEq(reactor.reserve(), 200e18);
    }

    function testFuzzTinyPriceRecovery(uint8 multiplier, uint96 depositRaw) public {
        uint256 price = bound(uint256(multiplier), 1, 30) * 1e18;
        uint256 deposit = bound(uint256(depositRaw), 1e18, 1000e18);
        (StableCoinReactor reactor, GenericMockOracle oracle) = _seed(price, deposit);
        oracle.setValue(1);
        _adjustIntoRange(reactor);
        assertGt(reactor.pegFactor(), 100);
        oracle.setValue(price);
        _adjustIntoRange(reactor);
        _redeem(reactor, 1e18);
    }
}
