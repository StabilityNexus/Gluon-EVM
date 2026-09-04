// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {ChainlinkToOracleAdapter} from "../src/oracles/ChainlinkToOracleAdapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// mock chainlink style feed
contract MockFeed {
    int256 public price;
    uint8 public decimalsVal;
    uint256 public updatedAtVal;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimalsVal = _decimals;
        updatedAtVal = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, 0, updatedAtVal, 0);
    }

    function decimals() external view returns (uint8) {
        return decimalsVal;
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }

    function setPrice(int256 _price) external {
        price = _price;
        updatedAtVal = block.timestamp;
    }
}

contract GluonIntegrationTest is Test {
    StableCoinFactory factory;
    StableCoinReactor reactor;
    ChainlinkToOracleAdapter adapter;
    MockFeed mockFeed;
    MockERC20 baseToken;
    address treasury = makeAddr("treasury");

    function setUp() public {
        baseToken = new MockERC20("USD Coin", "USDC");

        // price = $1.00, 8 decimals like chainlink
        mockFeed = new MockFeed(100000000, 8);
        adapter = new ChainlinkToOracleAdapter(address(mockFeed));

        factory = new StableCoinFactory();

        reactor = _deployReactor(address(adapter));
    }

    function _deployReactor(address oracleAddress) internal returns (StableCoinReactor) {
        address reactorAddr = factory.deployReactor(
            "Gluon Vault",
            "USD Coin",
            "USDC",
            "Gluon USD",
            "GUSD",
            address(baseToken),
            oracleAddress,
            "Gluon Gov",
            "GOV",
            treasury,
            0,
            0,
            15e17 // 150% critical reserve ratio
        );

        return StableCoinReactor(reactorAddr);
    }

    function _fundAndFission(address user, uint256 amount) internal {
        baseToken.mint(user, amount);

        vm.startPrank(user);
        baseToken.approve(address(reactor), amount);
        reactor.fission(amount, user);
        vm.stopPrank();
    }

    function _adjustIntoOperatingRange() internal {
        uint256 iterations;

        while (
            (reactor.reserveRatioPeggedAsset() < reactor.CRITICAL_RESERVE_RATIO()
                    || reactor.reserveRatioPeggedAsset() > reactor.UPPER_RESERVE_RATIO()) && iterations < 100
        ) {
            reactor.adjustPeg();
            iterations++;
        }

        uint256 ratio = reactor.reserveRatioPeggedAsset();
        assertGe(ratio, reactor.CRITICAL_RESERVE_RATIO(), "failed to reach lower operating bound");
        assertLe(ratio, reactor.UPPER_RESERVE_RATIO(), "failed to reach upper operating bound");
    }

    function testFissionWithAdapter() public {
        address user = makeAddr("user");

        _fundAndFission(user, 100 * 1e18);

        uint256 neutronBal = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonBal = reactor.PROTON_TOKEN().balanceOf(user);

        assertTrue(neutronBal > 0, "Neutron tokens not minted");
        assertTrue(protonBal > 0, "Proton tokens not minted");
    }

    function testFusionAfterFissionWithAdapter() public {
        address user = makeAddr("fusionUser");
        uint256 fissionAmount = 100 * 1e18;
        uint256 fusionAmount = 30 * 1e18;

        _fundAndFission(user, fissionAmount);
        _adjustIntoOperatingRange();

        uint256 reserveBefore = reactor.reserve();
        uint256 userBaseBefore = baseToken.balanceOf(user);
        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonBefore = reactor.PROTON_TOKEN().balanceOf(user);

        vm.prank(user);
        reactor.fusion(fusionAmount, user);

        assertEq(baseToken.balanceOf(user), userBaseBefore + fusionAmount, "base not returned");
        assertEq(reactor.reserve(), reserveBefore - fusionAmount, "reserve not reduced");
        assertLt(reactor.NEUTRON_TOKEN().balanceOf(user), neutronBefore, "neutron not burned");
        assertLt(reactor.PROTON_TOKEN().balanceOf(user), protonBefore, "proton not burned");
    }

    function testTransmuteProtonToNeutronWithAdapter() public {
        address user = makeAddr("protonUser");
        uint256 fissionAmount = 100 * 1e18;
        uint256 protonIn = 10 * 1e18;

        _fundAndFission(user, fissionAmount);
        _adjustIntoOperatingRange();

        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonBefore = reactor.PROTON_TOKEN().balanceOf(user);

        vm.prank(user);
        (uint256 neutronOut, uint256 feeWad) = reactor.transmuteProtonToNeutron(protonIn, user);

        assertEq(feeWad, 0, "unexpected fee");
        assertGt(neutronOut, 0, "no neutron minted");
        assertEq(protonBefore - reactor.PROTON_TOKEN().balanceOf(user), protonIn, "proton not burned");
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), neutronBefore + neutronOut, "neutron not minted");
    }

    function testTransmuteNeutronToProtonWithAdapter() public {
        address user = makeAddr("neutronUser");
        uint256 fissionAmount = 100 * 1e18;
        uint256 neutronIn = 10 * 1e18;

        _fundAndFission(user, fissionAmount);
        _adjustIntoOperatingRange();

        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonBefore = reactor.PROTON_TOKEN().balanceOf(user);

        vm.prank(user);
        (uint256 protonOut, uint256 feeWad) = reactor.transmuteNeutronToProton(neutronIn, user);

        assertEq(feeWad, 0, "unexpected fee");
        assertGt(protonOut, 0, "no proton minted");
        assertEq(neutronBefore - reactor.NEUTRON_TOKEN().balanceOf(user), neutronIn, "neutron not burned");
        assertEq(reactor.PROTON_TOKEN().balanceOf(user), protonBefore + protonOut, "proton not minted");
    }

    function testReserveRatioUsesAdapterPrice() public {
        address user = makeAddr("ratioUser");

        _fundAndFission(user, 100 * 1e18);

        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();

        mockFeed.setPrice(2 * 1e8);

        uint256 ratioAfter = reactor.reserveRatioPeggedAsset();

        assertEq(reactor.getBasePriceInPeggedAsset(), 2 * 1e18, "adapter price not updated");
        assertGt(ratioBefore, 0, "ratio should be positive");
        assertGt(ratioAfter, ratioBefore, "ratio did not use updated price");
    }

    function testPriceViewFunctionsUseAdapter() public {
        address user = makeAddr("priceUser");

        _fundAndFission(user, 100 * 1e18);

        uint256 neutronBaseBefore = reactor.neutronPriceInBase();
        uint256 protonBaseBefore = reactor.protonPriceInBase();
        uint256 neutronPeggedBefore = reactor.neutronPriceInPeggedAsset();
        uint256 protonPeggedBefore = reactor.protonPriceInPeggedAsset();

        assertEq(reactor.getBasePriceInPeggedAsset(), 1e18, "wrong initial price");
        assertGt(neutronBaseBefore, 0, "bad neutron base price");
        assertGt(protonBaseBefore, 0, "bad proton base price");
        assertGt(neutronPeggedBefore, 0, "bad neutron pegged price");
        assertGt(protonPeggedBefore, 0, "bad proton pegged price");

        mockFeed.setPrice(2 * 1e8);

        assertEq(reactor.getBasePriceInPeggedAsset(), 2 * 1e18, "adapter price not updated");
        assertNotEq(reactor.neutronPriceInBase(), neutronBaseBefore, "neutron base price unchanged");
        assertNotEq(reactor.protonPriceInBase(), protonBaseBefore, "proton base price unchanged");
        assertGt(reactor.neutronPriceInPeggedAsset(), 0, "bad updated neutron pegged price");
        assertGt(reactor.protonPriceInPeggedAsset(), 0, "bad updated proton pegged price");
    }

    function testFissionRevertsWhenOracleReturnsBadPrice() public {
        MockFeed badFeed = new MockFeed(0, 8);
        ChainlinkToOracleAdapter badAdapter = new ChainlinkToOracleAdapter(address(badFeed));
        StableCoinReactor badReactor = _deployReactor(address(badAdapter));

        address user = makeAddr("badOracleUser");
        uint256 amount = 100 * 1e18;

        baseToken.mint(user, amount);

        vm.startPrank(user);
        baseToken.approve(address(badReactor), amount);

        vm.expectRevert(ChainlinkToOracleAdapter.BadValue.selector);
        badReactor.fission(amount, user);

        vm.stopPrank();
    }

    function testFactoryRejectsZeroOracle() public {
        vm.expectRevert(StableCoinFactory.InvalidOracle.selector);

        factory.deployReactor(
            "Gluon Vault",
            "USD Coin",
            "USDC",
            "Gluon USD",
            "GUSD",
            address(baseToken),
            address(0),
            "Gluon Gov",
            "GOV",
            treasury,
            0,
            0,
            15e17
        );
    }

    function testReactorRejectsEOAOracle() public {
        address eoaOracle = makeAddr("eoaOracle");

        vm.expectRevert(StableCoinReactor.OracleNotContract.selector);

        factory.deployReactor(
            "Gluon Vault",
            "USD Coin",
            "USDC",
            "Gluon USD",
            "GUSD",
            address(baseToken),
            eoaOracle,
            "Gluon Gov",
            "GOV",
            treasury,
            0,
            0,
            15e17
        );
    }

    function testBootstrapFissionIsExemptFromOperatingRange() public {
        address user = makeAddr("bootstrapExemptionUser");

        assertEq(reactor.reserveRatioPeggedAsset(), 0, "precondition: empty reactor ratio should be zero");

        _fundAndFission(user, 100e18);

        assertGt(reactor.NEUTRON_TOKEN().balanceOf(user), 0, "bootstrap should mint neutrons");
        assertGt(reactor.PROTON_TOKEN().balanceOf(user), 0, "bootstrap should mint protons");
    }

    function testNormalFissionWorksInsideOperatingRange() public {
        address user = makeAddr("normalFissionUser");

        _fundAndFission(user, 100e18);
        _adjustIntoOperatingRange();

        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();

        baseToken.mint(user, 10e18);

        vm.startPrank(user);
        baseToken.approve(address(reactor), 10e18);
        reactor.fission(10e18, user);
        vm.stopPrank();

        uint256 ratioAfter = reactor.reserveRatioPeggedAsset();

        assertApproxEqAbs(ratioAfter, ratioBefore, 1, "normal fission should preserve reserve ratio");
    }

    function testAllOperationsRevertAboveUpperReserveRatio() public {
        address user = makeAddr("highGuardUser");

        _fundAndFission(user, 100e18);

        uint256 ratio = reactor.reserveRatioPeggedAsset();

        assertGt(ratio, reactor.UPPER_RESERVE_RATIO(), "precondition: ratio should be above upper bound");

        bytes memory expectedError = abi.encodeWithSelector(StableCoinReactor.ReserveRatioOutOfRange.selector, ratio);

        vm.startPrank(user);

        vm.expectRevert(expectedError);
        reactor.fission(1e18, user);

        vm.expectRevert(expectedError);
        reactor.fusion(1e18, user);

        vm.expectRevert(expectedError);
        reactor.transmuteProtonToNeutron(1e18, user);

        vm.expectRevert(expectedError);
        reactor.transmuteNeutronToProton(1e18, user);

        vm.stopPrank();
    }

    function testAllOperationsRevertBelowCriticalReserveRatio() public {
        address user = makeAddr("lowGuardUser");

        _fundAndFission(user, 100e18);
        mockFeed.setPrice(40_000_000);

        uint256 ratio = reactor.reserveRatioPeggedAsset();

        assertLt(ratio, reactor.CRITICAL_RESERVE_RATIO(), "precondition: ratio should be below critical reserve ratio");

        bytes memory expectedError = abi.encodeWithSelector(StableCoinReactor.ReserveRatioOutOfRange.selector, ratio);

        vm.startPrank(user);

        vm.expectRevert(expectedError);
        reactor.fission(1e18, user);

        vm.expectRevert(expectedError);
        reactor.fusion(1e18, user);

        vm.expectRevert(expectedError);
        reactor.transmuteProtonToNeutron(1e18, user);

        vm.expectRevert(expectedError);
        reactor.transmuteNeutronToProton(1e18, user);

        vm.stopPrank();
    }

    function testBetaPlusRevertsIfResultFallsBelowCriticalRatio() public {
        address user = makeAddr("betaPlusLowerBoundUser");

        _fundAndFission(user, 100e18);
        _adjustIntoOperatingRange();

        // Move the valid pre-state closer to r* without crossing it.
        mockFeed.setPrice(80_000_000);

        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();
        assertGe(ratioBefore, reactor.CRITICAL_RESERVE_RATIO(), "precondition: beta+ must start inside operating range");
        assertLe(ratioBefore, reactor.UPPER_RESERVE_RATIO(), "precondition: beta+ must start inside operating range");

        uint256 protonBalanceBefore = reactor.PROTON_TOKEN().balanceOf(user);
        uint256 neutronBalanceBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonSupplyBefore = reactor.PROTON_TOKEN().totalSupply();
        uint256 neutronSupplyBefore = reactor.NEUTRON_TOKEN().totalSupply();

        vm.prank(user);
        vm.expectRevert(StableCoinReactor.ResultingReserveRatioBelowCritical.selector);
        reactor.transmuteProtonToNeutron(20e18, user);

        assertEq(
            reactor.PROTON_TOKEN().balanceOf(user), protonBalanceBefore, "reverted beta+ must restore proton balance"
        );
        assertEq(
            reactor.NEUTRON_TOKEN().balanceOf(user), neutronBalanceBefore, "reverted beta+ must restore neutron balance"
        );
        assertEq(reactor.PROTON_TOKEN().totalSupply(), protonSupplyBefore, "reverted beta+ must restore proton supply");
        assertEq(
            reactor.NEUTRON_TOKEN().totalSupply(), neutronSupplyBefore, "reverted beta+ must restore neutron supply"
        );
        assertEq(reactor.reserveRatioPeggedAsset(), ratioBefore, "reverted beta+ must leave reserve ratio unchanged");
    }

    function testBetaMinusMayCrossAboveUpperReserveRatio() public {
        address user = makeAddr("betaMinusUpperCrossUser");

        _fundAndFission(user, 100e18);
        _adjustIntoOperatingRange();

        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();
        assertGe(ratioBefore, reactor.CRITICAL_RESERVE_RATIO(), "precondition: beta- must start inside operating range");
        assertLe(ratioBefore, reactor.UPPER_RESERVE_RATIO(), "precondition: beta- must start inside operating range");

        vm.prank(user);
        reactor.transmuteNeutronToProton(1e18, user);

        uint256 ratioAfter = reactor.reserveRatioPeggedAsset();

        assertGt(
            ratioAfter, reactor.UPPER_RESERVE_RATIO(), "beta- should be allowed to move resulting ratio above 200%"
        );

        // Once outside the range, later normal operations are disabled.
        bytes memory expectedError =
            abi.encodeWithSelector(StableCoinReactor.ReserveRatioOutOfRange.selector, ratioAfter);

        vm.prank(user);
        vm.expectRevert(expectedError);
        reactor.fusion(1e18, user);
    }

    function testAdjustPegRevertsBeforeInitialization() public {
        vm.expectRevert(StableCoinReactor.ReactorNotInitialized.selector);
        reactor.adjustPeg();
    }

    function testAdjustPegIncreasesAlphaAboveUpperBound() public {
        address user = makeAddr("highRatioUser");
        _fundAndFission(user, 100e18);

        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();
        assertGt(ratioBefore, reactor.UPPER_RESERVE_RATIO(), "precondition: ratio should be above 200%");

        reactor.adjustPeg();

        uint256 ratioAfter = reactor.reserveRatioPeggedAsset();

        assertEq(reactor.alpha(), 101e16, "alpha should increase by 1%");
        assertLt(ratioAfter, ratioBefore, "increasing alpha should decrease reserve ratio");
    }

    function testAdjustPegDecreasesAlphaBelowCriticalRatio() public {
        address user = makeAddr("lowRatioUser");
        _fundAndFission(user, 100e18);

        mockFeed.setPrice(40_000_000);

        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();
        assertLt(
            ratioBefore, reactor.CRITICAL_RESERVE_RATIO(), "precondition: ratio should be below critical reserve ratio"
        );

        reactor.adjustPeg();

        uint256 ratioAfter = reactor.reserveRatioPeggedAsset();

        assertEq(reactor.alpha(), 99e16, "alpha should decrease by 1%");
        assertGt(ratioAfter, ratioBefore, "decreasing alpha should increase reserve ratio");
    }

    function testRepeatedAdjustPegFromHighRatioReturnsToOperatingRange() public {
        address user = makeAddr("repeatedHighRatioUser");
        _fundAndFission(user, 100e18);

        assertGt(
            reactor.reserveRatioPeggedAsset(),
            reactor.UPPER_RESERVE_RATIO(),
            "precondition: ratio should start above upper bound"
        );

        uint256 iterations;
        while (reactor.reserveRatioPeggedAsset() > reactor.UPPER_RESERVE_RATIO() && iterations < 100) {
            reactor.adjustPeg();
            iterations++;
        }

        uint256 finalRatio = reactor.reserveRatioPeggedAsset();

        assertGt(iterations, 0, "expected at least one adjustment");
        assertLe(finalRatio, reactor.UPPER_RESERVE_RATIO(), "ratio should return below upper bound");
        assertGe(finalRatio, reactor.CRITICAL_RESERVE_RATIO(), "ratio should remain above critical ratio");
        assertGt(reactor.alpha(), 1e18, "alpha should increase from one");

        vm.expectRevert(StableCoinReactor.PegAdjustmentNotNeeded.selector);
        reactor.adjustPeg();
    }

    function testRepeatedAdjustPegFromLowRatioReturnsToOperatingRange() public {
        address user = makeAddr("repeatedLowRatioUser");
        _fundAndFission(user, 100e18);

        mockFeed.setPrice(40_000_000);

        assertLt(
            reactor.reserveRatioPeggedAsset(),
            reactor.CRITICAL_RESERVE_RATIO(),
            "precondition: ratio should start below critical ratio"
        );

        uint256 iterations;
        while (reactor.reserveRatioPeggedAsset() < reactor.CRITICAL_RESERVE_RATIO() && iterations < 100) {
            reactor.adjustPeg();
            iterations++;
        }

        uint256 finalRatio = reactor.reserveRatioPeggedAsset();

        assertGt(iterations, 0, "expected at least one adjustment");
        assertGe(finalRatio, reactor.CRITICAL_RESERVE_RATIO(), "ratio should return above critical ratio");
        assertLe(finalRatio, reactor.UPPER_RESERVE_RATIO(), "ratio should remain below upper bound");
        assertLt(reactor.alpha(), 1e18, "alpha should decrease from one");

        vm.expectRevert(StableCoinReactor.PegAdjustmentNotNeeded.selector);
        reactor.adjustPeg();
    }

    function testAdjustPegRevertsInsideOperatingRange() public {
        address user = makeAddr("validRatioUser");
        _fundAndFission(user, 100e18);

        mockFeed.setPrice(60_000_000);

        uint256 ratio = reactor.reserveRatioPeggedAsset();
        assertGe(ratio, reactor.CRITICAL_RESERVE_RATIO(), "precondition: ratio below lower bound");
        assertLe(ratio, reactor.UPPER_RESERVE_RATIO(), "precondition: ratio above upper bound");

        vm.expectRevert(StableCoinReactor.PegAdjustmentNotNeeded.selector);
        reactor.adjustPeg();
    }

    function testEmptyReserveRatioDoesNotReadOracle() public {
        MockFeed badFeed = new MockFeed(0, 8);
        ChainlinkToOracleAdapter badAdapter = new ChainlinkToOracleAdapter(address(badFeed));
        StableCoinReactor emptyReactor = _deployReactor(address(badAdapter));

        assertEq(emptyReactor.reserveRatioPeggedAsset(), 0, "empty reactor ratio should not depend on oracle");
    }

    function testAlphaOnePreservesBootstrapReserveRatio() public {
        address user = makeAddr("alphaRatioUser");
        _fundAndFission(user, 100e18);

        assertEq(reactor.reserveRatioPeggedAsset(), 3e18, "alpha=1 should preserve bootstrap reserve ratio");
    }

    function testAlphaStartsAtWad() public view {
        assertEq(reactor.alpha(), 1e18, "alpha should start at 1");
    }
}
