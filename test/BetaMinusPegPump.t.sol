// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {Tokeon} from "../src/tokens/Tokeon.sol";
import {GenericMockOracle} from "./GenericIOracleIntegration.t.sol";
import {MockDecimalERC20} from "./GluonIntegration.t.sol";

/// A Neutron holder must not be able to push the reserve ratio above 200%, with beta-minus or a
/// small reserve donation, call adjustPeg() and take Proton holders' equity at a constant price.
contract BetaMinusPegPumpTest is Test {
    uint256 private constant WAD = 1e18;
    address private dev = makeAddr("dev");
    address private holder = makeAddr("holder");
    address private whale = makeAddr("whale");

    MockDecimalERC20 private base;
    StableCoinReactor private reactor;
    GenericMockOracle private oracle;
    Tokeon private neutron;
    Tokeon private proton;

    function setUp() public {
        base = new MockDecimalERC20("Base", "B", 18);
        StableCoinFactory factory = new StableCoinFactory(dev, 1e15);
        oracle = new GenericMockOracle(2000e18);
        base.mint(address(this), 1e18);
        base.approve(address(factory), 1e18);
        reactor = StableCoinReactor(
            factory.deployReactor(
                "V",
                "B",
                "B",
                "N",
                "N",
                address(base),
                address(oracle),
                "P",
                "P",
                0,
                0,
                12e17,
                15e17,
                1e18,
                3e15,
                1e17,
                99999e13
            )
        );
        neutron = reactor.NEUTRON_TOKEN();
        proton = reactor.PROTON_TOKEN();

        base.mint(holder, 1000e18);
        vm.startPrank(holder);
        base.approve(address(reactor), type(uint256).max);
        reactor.fission(1000e18, holder);
        vm.stopPrank();

        // The base asset rises about 27%: the ratio goes from 150% to about 190%, still in range.
        oracle.setValue(2533e18);
    }

    /// Beta-minus as large as the reactor accepts, halving the amount after each refusal.
    function _betaMinusUpTo(uint256 amount) private {
        while (amount > 1e9) {
            try reactor.transmuteNeutronToProton(amount, 0, whale) {
                return;
            } catch {
                amount /= 2;
            }
        }
    }

    function testWhaleCannotPumpPegWithBetaMinus() public {
        uint256 bought = neutron.balanceOf(holder) / 2;
        uint256 cost = bought * reactor.neutronPriceInBase() / WAD;
        vm.prank(holder);
        assertTrue(neutron.transfer(whale, bought), "transfer to whale failed");

        vm.startPrank(whale);
        for (uint256 i; i < 60; ++i) {
            uint256 m = Math.min(
                Math.mulDiv(neutron.balanceOf(whale), reactor.reserve(), neutron.totalSupply()),
                Math.mulDiv(proton.balanceOf(whale), reactor.reserve(), proton.totalSupply())
            );
            if (m > 2) try reactor.fusion(m - 2, whale) {} catch {}
            uint256 left = neutron.balanceOf(whale);
            if (left < 1e9) break;
            _betaMinusUpTo(left / 3 + 1);
            while (true) {
                try reactor.adjustPeg() {}
                catch {
                    break;
                }
            }
        }
        vm.stopPrank();

        assertEq(reactor.pegFactor(), reactor.PEG_FACTOR_SCALE(), "a holder's own beta-minus moved the peg");
        assertLe(base.balanceOf(whale), cost, "whale withdrew more base than its Neutrons were worth");
    }

    /// Largest beta-minus that keeps the ratio at or below 200%, from an upper bound on the ratio.
    function _maxBetaMinus() private view returns (uint256) {
        uint256 supply = neutron.totalSupply();
        uint256 keep = Math.mulDiv(reactor.reserveRatioPeggedAsset() + 1, supply, 2e18, Math.Rounding.Ceil);
        return keep >= supply ? 0 : supply - keep;
    }

    /// Beta-minus right up to 200%, then donate just enough base to cross it before adjustPeg().
    function testDonationCrossingCannotPumpPeg() public {
        uint256 bought = neutron.balanceOf(holder) / 2;
        uint256 cost = bought * reactor.neutronPriceInBase() / WAD;
        vm.prank(holder);
        assertTrue(neutron.transfer(whale, bought), "transfer to whale failed");
        base.mint(whale, 10e18);

        vm.startPrank(whale);
        for (uint256 i; i < 60; ++i) {
            uint256 m = Math.min(
                Math.mulDiv(neutron.balanceOf(whale), reactor.reserve(), neutron.totalSupply()),
                Math.mulDiv(proton.balanceOf(whale), reactor.reserve(), proton.totalSupply())
            );
            if (m > 2) try reactor.fusion(m - 2, whale) {} catch {}
            uint256 amount = Math.min(neutron.balanceOf(whale), _maxBetaMinus());
            if (amount < 1e9) break;
            reactor.transmuteNeutronToProton(amount, 0, whale);

            uint256 reserveNow = reactor.reserve();
            uint256 donation = Math.mulDiv(reserveNow, 2e18 + 2, reactor.reserveRatioPeggedAsset(), Math.Rounding.Ceil)
                - reserveNow + 1;
            assertTrue(base.transfer(address(reactor), donation), "donation failed");
            while (true) {
                try reactor.adjustPeg() {}
                catch {
                    break;
                }
            }
        }
        vm.stopPrank();

        uint256 leftValue = neutron.balanceOf(whale) * reactor.neutronPriceInBase() / WAD + proton.balanceOf(whale)
            * reactor.protonPriceInBase() / WAD;
        assertLe(base.balanceOf(whale) + leftValue, cost + 10e18, "whale gained from donation crossings");
    }

    function testBetaMinusCannotEndAboveUpperRatio() public {
        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();
        assertLe(ratioBefore, reactor.UPPER_RESERVE_RATIO(), "precondition: inside the operating range");

        uint256 amount = neutron.balanceOf(holder) / 3;
        vm.prank(holder);
        vm.expectRevert(StableCoinReactor.ResultingReserveRatioAboveUpper.selector);
        reactor.transmuteNeutronToProton(amount, 0, holder);

        assertEq(reactor.reserveRatioPeggedAsset(), ratioBefore, "reverted beta-minus must not move the ratio");
    }

    function testBetaMinusThatStaysInRangeStillWorks() public {
        uint256 amount = neutron.balanceOf(holder) / 100;
        vm.prank(holder);
        (uint256 protonOut,) = reactor.transmuteNeutronToProton(amount, 0, holder);

        assertGt(protonOut, 0, "a small beta-minus should still convert");
        assertLe(reactor.reserveRatioPeggedAsset(), reactor.UPPER_RESERVE_RATIO(), "ratio must stay in range");
    }
}

/// At a tiny peg factor one unit is a large share of the peg. A donation must never buy an upward
/// step that raises Neutron liabilities by more than the donation, on either upward branch.
contract SmallPegFactorPumpTest is Test {
    uint256 private constant WAD = 1e18;

    MockDecimalERC20 private base;
    StableCoinReactor private reactor;
    GenericMockOracle private oracle;
    Tokeon private neutron;

    function setUp() public {
        base = new MockDecimalERC20("Base", "B", 18);
        StableCoinFactory factory = new StableCoinFactory(makeAddr("dev"), 1e15);
        oracle = new GenericMockOracle(1e35);
        base.mint(address(this), 1e18);
        base.approve(address(factory), 1e18);
        reactor = StableCoinReactor(
            factory.deployReactor(
                "V",
                "B",
                "B",
                "N",
                "N",
                address(base),
                address(oracle),
                "P",
                "P",
                0,
                0,
                12e17,
                15e17,
                1e18,
                3e15,
                1e17,
                99999e13
            )
        );
        neutron = reactor.NEUTRON_TOKEN();

        base.mint(address(this), 1000e18);
        base.approve(address(reactor), type(uint256).max);
        reactor.fission(1000e18, address(this));

        // A huge price fall drives the peg factor down to a few units, then a partial recovery.
        oracle.setValue(1);
        _recover();
        oracle.setValue(2);
        _recover();
        assertLt(reactor.pegFactor(), 100, "precondition: tiny peg factor");
        assertEq(reactor.reserveRatioPeggedAsset(), 2e18, "precondition: ratio exactly at the bound");
    }

    function _recover() private {
        for (uint256 i; i < 20_000; ++i) {
            try reactor.adjustPeg() {}
            catch {
                return;
            }
        }
    }

    /// Target liabilities in base WAD, computed outside the reactor: supply * peg / (price * WAD).
    function _liabilities() private view returns (uint256) {
        return Math.mulDiv(neutron.totalSupply(), reactor.pegFactor(), oracle.readValue() * WAD);
    }

    /// Donates enough base to lift the ratio to targetRatio, then makes one upward adjustment.
    function _assertDonationPaysForStep(uint256 targetRatio) private {
        uint256 reserveNow = reactor.reserve();
        uint256 donation =
            Math.mulDiv(reserveNow, targetRatio, reactor.reserveRatioPeggedAsset(), Math.Rounding.Ceil) - reserveNow;
        uint256 liabilitiesBefore = _liabilities();
        base.mint(address(this), donation);
        assertTrue(base.transfer(address(reactor), donation), "donation failed");
        // The ratio is now above 200%, so the adjustment must run; a revert fails the test.
        reactor.adjustPeg();
        uint256 liabilitiesAfter = _liabilities();
        assertLe(liabilitiesAfter - liabilitiesBefore, donation, "peg step was not paid for by the donation");
    }

    function testTinyCrossingBelowFullStepRatio() public {
        _assertDonationPaysForStep(2e18 + 2);
    }

    function testCrossingAtFullStepRatio() public {
        _assertDonationPaysForStep(202e16);
    }

    function testCrossingAboveFullStepRatio() public {
        _assertDonationPaysForStep(21e17);
    }

    function testCrossingAboveCapThreshold() public {
        _assertDonationPaysForStep(5e18);
    }
}
