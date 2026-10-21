// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockERC20, GenericMockOracle} from "./GenericIOracleIntegration.t.sol";

contract BetaFeeHarness is StableCoinReactor {
    constructor(address base, address oracle, uint256 phi0, uint256 phi1)
        StableCoinReactor(
            "Fee", "Base", "B", "Peg", "N", base, oracle, "Proton", "P", address(1), 0, 0, 0, 101e16, phi0, phi1, 1e18
        )
    {}

    function fee(uint256 reserveWad, uint256 volume) external view returns (uint256) {
        return _betaFeeWad(reserveWad, volume);
    }
}

contract UnsignedVolumeLedgerTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant FIRST_TRADE = 38 * 1e75;
    bytes32 private constant PLUS =
        keccak256("TransmutePlus(address,address,uint256,uint256,uint256,uint256,uint256,uint256)");
    bytes32 private constant MINUS =
        keccak256("TransmuteMinus(address,address,uint256,uint256,uint256,uint256,uint256,uint256)");
    StableCoinFactory private factory;
    GenericMockERC20 private base;
    GenericMockOracle private oracle;
    StableCoinReactor private reactor;
    address private user = makeAddr("volume user");

    function setUp() public {
        factory = new StableCoinFactory(address(1), 0);
        base = new GenericMockERC20();
        oracle = new GenericMockOracle(WAD);
        reactor = _deploy(1, WAD, WAD, 100e18);
    }

    function _deploy(uint256 phi0, uint256 phi1, uint256 decay, uint256 deposit)
        private
        returns (StableCoinReactor target)
    {
        base.mint(address(this), 100e18);
        base.approve(address(factory), 100e18);
        target = StableCoinReactor(
            factory.deployReactor(
                "Volume",
                "Base",
                "B",
                "Peg",
                "N",
                address(base),
                address(oracle),
                "Proton",
                "P",
                0,
                0,
                101e16,
                15e17,
                100e18,
                phi0,
                phi1,
                decay
            )
        );
        base.mint(user, deposit);
        vm.startPrank(user);
        base.approve(address(target), deposit);
        target.fission(deposit, user);
        vm.stopPrank();
    }

    function _lastVolumes(Vm.Log[] memory entries, bytes32 signature)
        private
        view
        returns (uint256 plus, uint256 minus)
    {
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (
                entries[i].emitter == address(reactor) && entries[i].topics.length > 0
                    && entries[i].topics[0] == signature
            ) {
                (,,, plus, minus,) = abi.decode(entries[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
                found = true;
            }
        }
        assertTrue(found, "missing volume event");
    }

    function _assertVolumes(bytes32 signature, uint256 expectedPlus, uint256 expectedMinus) private {
        (uint256 plus, uint256 minus) = _lastVolumes(vm.getRecordedLogs(), signature);
        assertEq(plus, expectedPlus);
        assertEq(minus, expectedMinus);
    }

    function testOppositeTradesKeepSeparateCountersAndCancelForFees() public {
        vm.startPrank(user);
        reactor.transmuteProtonToNeutron(WAD, 0, user);
        vm.recordLogs();
        (, uint256 minusFee) = reactor.transmuteNeutronToProton(WAD, 0, user);
        vm.stopPrank();
        assertEq(minusFee, 1, "opposite direction should pay only the base fee");
        _assertVolumes(MINUS, WAD, WAD);
        vm.prank(user);
        (, uint256 plusFee) = reactor.transmuteProtonToNeutron(WAD, 0, user);
        assertEq(plusFee, 1, "equal directional volumes must cancel for fees");
    }

    function testFeeUsesOnlyPositiveDifferenceInItsOwnDirection() public {
        vm.startPrank(user);
        reactor.transmuteProtonToNeutron(WAD, 0, user);
        reactor.transmuteNeutronToProton(2 * WAD, 0, user);
        (, uint256 minusFee) = reactor.transmuteNeutronToProton(WAD, 0, user);
        (, uint256 plusFee) = reactor.transmuteProtonToNeutron(WAD, 0, user);
        vm.stopPrank();
        assertEq(minusFee, 1 + WAD / 200);
        assertEq(plusFee, 1);
    }

    function testBothCountersDecayBeforeFeeCalculation() public {
        reactor = _deploy(1, WAD, WAD / 2, 100e18);
        vm.startPrank(user);
        reactor.transmuteProtonToNeutron(4 * WAD, 0, user);
        reactor.transmuteNeutronToProton(2 * WAD, 0, user);
        vm.warp(block.timestamp + 1);
        uint256 gross = Math.mulDiv(WAD, reactor.protonPriceInBase(), WAD);
        vm.recordLogs();
        (, uint256 fee) = reactor.transmuteProtonToNeutron(WAD, 0, user);
        vm.stopPrank();
        assertEq(fee, 1 + WAD / 200);
        _assertVolumes(PLUS, 2 * WAD + gross, WAD);
    }

    function testDecayRoundsEachCounterSeparately() public {
        reactor = _deploy(1, WAD, WAD / 2, 100e18);
        vm.startPrank(user);
        reactor.transmuteProtonToNeutron(6, 0, user);
        reactor.transmuteNeutronToProton(3, 0, user);
        vm.warp(block.timestamp + 1);
        vm.recordLogs();
        reactor.transmuteProtonToNeutron(6, 0, user);
        vm.stopPrank();
        // floor(6/2) and floor(3/2) are retained independently, then the new 6 is added.
        _assertVolumes(PLUS, 9, 1);
    }

    function testZeroRetentionClearsBothCountersAfterTimeElapses() public {
        reactor = _deploy(1, WAD, 0, 100e18);
        vm.startPrank(user);
        reactor.transmuteProtonToNeutron(4 * WAD, 0, user);
        reactor.transmuteNeutronToProton(2 * WAD, 0, user);
        vm.warp(block.timestamp + 1);
        uint256 gross = Math.mulDiv(WAD, reactor.protonPriceInBase(), WAD);
        vm.recordLogs();
        (, uint256 fee) = reactor.transmuteProtonToNeutron(WAD, 0, user);
        vm.stopPrank();
        assertEq(fee, 1);
        _assertVolumes(PLUS, gross, 0);
    }

    function testZeroRetentionDoesNotDecayWithinSameTimestamp() public {
        reactor = _deploy(1, WAD, 0, 100e18);
        vm.startPrank(user);
        reactor.transmuteProtonToNeutron(WAD, 0, user);
        vm.recordLogs();
        reactor.transmuteNeutronToProton(WAD, 0, user);
        vm.stopPrank();
        _assertVolumes(MINUS, WAD, WAD);
    }

    function testFullRetentionKeepsBothCountersAcrossTime() public {
        vm.startPrank(user);
        reactor.transmuteProtonToNeutron(WAD, 0, user);
        reactor.transmuteNeutronToProton(WAD, 0, user);
        vm.warp(block.timestamp + 365 days);
        uint256 gross = Math.mulDiv(WAD, reactor.protonPriceInBase(), WAD);
        vm.recordLogs();
        reactor.transmuteProtonToNeutron(WAD, 0, user);
        vm.stopPrank();
        _assertVolumes(PLUS, WAD + gross, WAD);
    }

    function _prepareSignedBoundary() private {
        reactor = _deploy(1, WAD, WAD / 2, 1e77);
        vm.prank(user);
        reactor.transmuteNeutronToProton(FIRST_TRADE, 0, user);
        oracle.setValue(WAD / 2);
        assertEq(reactor.neutronPriceInBase(), 2 * WAD);
    }

    function testFormerSignedMinimumSupportsFurtherFeesDecayAndFusion() public {
        _prepareSignedBoundary();
        uint256 secondTrade = ((uint256(1) << 255) - FIRST_TRADE) / 2;
        vm.recordLogs();
        vm.prank(user);
        reactor.transmuteNeutronToProton(secondTrade, 0, user);
        _assertVolumes(MINUS, 0, uint256(1) << 255);

        oracle.setValue(3e17);
        vm.warp(block.timestamp + 1);
        uint256 gross = Math.mulDiv(WAD, reactor.neutronPriceInBase(), WAD);
        vm.recordLogs();
        vm.prank(user);
        (uint256 output, uint256 fee) = reactor.transmuteNeutronToProton(WAD, 0, user);
        assertGt(output, 0);
        assertGt(fee, 0);
        _assertVolumes(MINUS, 0, (uint256(1) << 254) + gross);

        uint256 beforeBalance = base.balanceOf(user);
        vm.prank(user);
        reactor.fusion(WAD, user);
        assertEq(base.balanceOf(user) - beforeBalance, WAD);
    }

    function testVolumeCanCrossFormerSignedBoundary() public {
        _prepareSignedBoundary();
        uint256 secondTrade = ((uint256(1) << 255) - FIRST_TRADE) / 2 + 1;
        vm.recordLogs();
        vm.prank(user);
        reactor.transmuteNeutronToProton(secondTrade, 0, user);
        _assertVolumes(MINUS, 0, (uint256(1) << 255) + 2);
    }

    function testUnsignedCounterOverflowStillRollsBackTrade() public {
        reactor = _deploy(1, 1, WAD, 1e77);
        vm.startPrank(user);
        for (uint256 i; i < 3; ++i) {
            (uint256 neutronOut,) = reactor.transmuteProtonToNeutron(3e76, 0, user);
            reactor.transmuteNeutronToProton(neutronOut, 0, user);
        }
        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonBefore = reactor.PROTON_TOKEN().balanceOf(user);
        uint256 neutronSupply = reactor.NEUTRON_TOKEN().totalSupply();
        uint256 protonSupply = reactor.PROTON_TOKEN().totalSupply();
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        reactor.transmuteProtonToNeutron(3e76, 0, user);
        vm.stopPrank();
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), neutronBefore);
        assertEq(reactor.PROTON_TOKEN().balanceOf(user), protonBefore);
        assertEq(reactor.NEUTRON_TOKEN().totalSupply(), neutronSupply);
        assertEq(reactor.PROTON_TOKEN().totalSupply(), protonSupply);
        // Ordinary later operations remain available after the rejected addition.
        vm.prank(user);
        reactor.transmuteProtonToNeutron(WAD, 0, user);
    }

    function testZeroVolumeCoefficientPreservesConfiguredBaseFee() public {
        BetaFeeHarness target = new BetaFeeHarness(address(base), address(oracle), 1e16, 0);
        assertEq(target.fee(1, type(uint256).max), 1e16);
        assertEq(target.fee(type(uint256).max, 0), 1e16);
        assertEq(target.fee(0, type(uint256).max), 1e16);
    }

    function testZeroReserveReturnsBaseFeeWithNonzeroVolumeCoefficient() public {
        BetaFeeHarness target = new BetaFeeHarness(address(base), address(oracle), 1e16, WAD);
        assertEq(target.fee(0, 0), 1e16);
        assertEq(target.fee(0, type(uint256).max), 1e16);
    }

    function testZeroBetaSettingsStillRecordSeparateVolumes() public {
        BetaFeeHarness target = new BetaFeeHarness(address(base), address(oracle), 0, 0);
        assertEq(target.fee(1, type(uint256).max), 0);
        assertEq(target.fee(0, type(uint256).max), 0);
        reactor = _deploy(0, 0, WAD, 100e18);
        vm.startPrank(user);
        (, uint256 plusFee) = reactor.transmuteProtonToNeutron(WAD, 0, user);
        vm.recordLogs();
        (, uint256 minusFee) = reactor.transmuteNeutronToProton(WAD, 0, user);
        vm.stopPrank();
        assertEq(plusFee, 0);
        assertEq(minusFee, 0);
        _assertVolumes(MINUS, WAD, WAD);
    }

    function testFeeCapsWithoutOverflowAtFullUnsignedVolume() public {
        BetaFeeHarness target = new BetaFeeHarness(address(base), address(oracle), 1, WAD);
        assertEq(target.fee(0, type(uint256).max), 1);
        assertEq(target.fee(1, type(uint256).max), WAD);
        assertEq(target.fee(type(uint256).max, type(uint256).max), WAD);
        assertEq(target.fee(type(uint256).max, 0), 1);
        BetaFeeHarness minimum = new BetaFeeHarness(address(base), address(oracle), 1, 1);
        assertEq(minimum.fee(1, type(uint256).max), WAD);
        assertEq(minimum.fee(1, WAD - 2), WAD - 1);
        assertEq(minimum.fee(1, WAD - 1), WAD);
    }

    function testFeeAtEqualVolumeAndReserveUsesBothCoefficients() public {
        BetaFeeHarness target = new BetaFeeHarness(address(base), address(oracle), 1e16, 2e16);
        assertEq(target.fee(7 * WAD, 7 * WAD), 3e16);
    }

    function testFeeAtWadVolumeRatioIsCapped() public {
        BetaFeeHarness target = new BetaFeeHarness(address(base), address(oracle), 0, 1);
        assertEq(target.fee(7, 7 * WAD - 1), WAD - 1);
        assertEq(target.fee(7, 7 * WAD), WAD);
        assertEq(target.fee(7, 7 * WAD + 1), WAD);
        assertEq(target.fee(7, type(uint256).max), WAD);
    }

    function testLargeReservePreservesUncappedFee() public {
        BetaFeeHarness target = new BetaFeeHarness(address(base), address(oracle), 1e16, 2e16);
        assertEq(target.fee(type(uint256).max, type(uint256).max), 3e16);
    }

    function testFuzzFeeMatchesFullWidthReference(uint256 volume, uint256 reserveWad, uint64 phi0Raw, uint64 phi1Raw)
        public
    {
        uint256 phi0 = bound(phi0Raw, 0, WAD);
        uint256 phi1 = bound(phi1Raw, 0, WAD);
        BetaFeeHarness target = new BetaFeeHarness(address(base), address(oracle), phi0, phi1);
        uint256 expected = phi0;
        if (reserveWad != 0) {
            // Compare full-width products to detect the fee cap before division.
            (uint256 feeHigh, uint256 feeLow) = Math.mul512(phi1, volume);
            (uint256 capHigh, uint256 capLow) = Math.mul512(WAD - phi0, reserveWad);
            bool capped = feeHigh > capHigh || (feeHigh == capHigh && feeLow >= capLow);
            expected = capped ? WAD : phi0 + Math.mulDiv(phi1, volume, reserveWad);
        }
        assertEq(target.fee(reserveWad, volume), expected);
    }

    function testFuzzFeeMatchesBoundedReference(uint128 volume, uint128 reserveRaw, uint64 phi0Raw, uint64 phi1Raw)
        public
    {
        uint256 reserveWad = bound(reserveRaw, 1, type(uint128).max);
        uint256 phi0 = bound(phi0Raw, 0, WAD);
        uint256 phi1 = bound(phi1Raw, 0, WAD);
        BetaFeeHarness target = new BetaFeeHarness(address(base), address(oracle), phi0, phi1);
        // These bounded products fit in uint256, giving an independent direct-arithmetic reference.
        uint256 expected = phi0 + phi1 * uint256(volume) / reserveWad;
        if (expected > WAD) expected = WAD;
        assertEq(target.fee(reserveWad, volume), expected);
    }
}
