// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockERC20, GenericMockOracle} from "./GenericIOracleIntegration.t.sol";

/// The beta fee counts the volume of the trade it charges, like the Coq model (Functions.v
/// net_volume) and the Ergo contract (Gluon.es OUT_VOLUME_PLUS / OUT_VOLUME_MINUS):
/// fee = phi0 + phi1 * max(0, own side volume including this trade - other side volume) / reserve.
contract BetaFeeCurrentTradeTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant PHI0 = 3e15; // 0.3%
    uint256 private constant PHI1 = 1e17; // 10% of the volume to reserve ratio
    uint256 private constant DECAY = 99999e13;

    StableCoinReactor private reactor;
    address private user = makeAddr("user");

    function setUp() public {
        StableCoinFactory factory = new StableCoinFactory(makeAddr("dev"), 1e15); // 0.1% dev fee
        GenericMockERC20 base = new GenericMockERC20();
        GenericMockOracle oracle = new GenericMockOracle(2000e18);
        base.mint(address(this), 100e18);
        base.approve(address(factory), 100e18);
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
                0,
                0,
                12e17, // critical ratio 120%
                15e17, // initial ratio 150%
                100e18,
                PHI0,
                PHI1,
                DECAY
            )
        );
        base.mint(user, 1000e18);
        vm.startPrank(user);
        base.approve(address(reactor), type(uint256).max);
        reactor.fission(1000e18, user);
        vm.stopPrank();
    }

    /// Reference fee from views read before the trade. The reserve token has 18 decimals, so
    /// reserve() is already the normalized reserve.
    function _expectedFee(uint256 volume) private view returns (uint256) {
        return Math.min(PHI0 + Math.mulDiv(PHI1, volume, reactor.reserve(), Math.Rounding.Ceil), WAD);
    }

    function _protonValue(uint256 protonIn) private view returns (uint256) {
        return Math.mulDiv(protonIn, reactor.protonPriceInBase(), WAD);
    }

    function _neutronValue(uint256 neutronIn) private view returns (uint256) {
        return Math.mulDiv(neutronIn, reactor.neutronPriceInBase(), WAD);
    }

    /// A beta-plus worth about 10% of the reserve on a quiet ledger pays for its own volume.
    function testBetaPlusFeeCountsItsOwnTrade() public {
        uint256 protonIn = reactor.PROTON_TOKEN().balanceOf(user) / 4;
        uint256 expected = _expectedFee(_protonValue(protonIn));

        vm.prank(user);
        (, uint256 feeWad) = reactor.transmuteProtonToNeutron(protonIn, 0, user);

        assertGt(expected, PHI0 + 1, "trade too small to show the volume part");
        assertEq(feeWad, expected, "beta-plus fee ignores its own volume");
    }

    /// The same for a beta-minus.
    function testBetaMinusFeeCountsItsOwnTrade() public {
        uint256 neutronIn = reactor.NEUTRON_TOKEN().balanceOf(user) / 4;
        uint256 expected = _expectedFee(_neutronValue(neutronIn));

        vm.prank(user);
        (, uint256 feeWad) = reactor.transmuteNeutronToProton(neutronIn, 0, user);

        assertGt(expected, PHI0 + 1, "trade too small to show the volume part");
        assertEq(feeWad, expected, "beta-minus fee ignores its own volume");
    }

    /// Volume on the other side still offsets the trade's own volume: a beta-plus right after a
    /// larger beta-minus nets to zero and pays only phi0.
    function testOppositeVolumeStillOffsetsOwnTrade() public {
        uint256 neutronIn = reactor.NEUTRON_TOKEN().balanceOf(user) / 4;
        uint256 minusVolume = _neutronValue(neutronIn);
        vm.prank(user);
        reactor.transmuteNeutronToProton(neutronIn, 0, user);

        uint256 protonIn = reactor.PROTON_TOKEN().balanceOf(user) / 8;
        uint256 plusVolume = _protonValue(protonIn);
        assertLt(plusVolume, minusVolume, "setup: beta-plus must be smaller than the beta-minus");

        vm.prank(user);
        (, uint256 feeWad) = reactor.transmuteProtonToNeutron(protonIn, 0, user);
        assertEq(feeWad, PHI0, "netted volume should leave only the base fee");
    }

    /// Once the beta-plus is larger than the earlier beta-minus, only the difference counts.
    function testOwnTradeAboveOppositeVolumePaysForTheDifference() public {
        uint256 neutronIn = reactor.NEUTRON_TOKEN().balanceOf(user) / 20;
        uint256 minusVolume = _neutronValue(neutronIn);
        vm.prank(user);
        reactor.transmuteNeutronToProton(neutronIn, 0, user);

        uint256 protonIn = reactor.PROTON_TOKEN().balanceOf(user) / 3;
        uint256 plusVolume = _protonValue(protonIn);
        assertGt(plusVolume, minusVolume, "setup: beta-plus must be larger than the beta-minus");
        uint256 expected = _expectedFee(plusVolume - minusVolume);

        vm.prank(user);
        (, uint256 feeWad) = reactor.transmuteProtonToNeutron(protonIn, 0, user);
        assertEq(feeWad, expected, "fee should count the trade minus the opposite volume");
    }
}
