// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {ChainlinkToOracleAdapter} from "../src/oracles/ChainlinkToOracleAdapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockDecimalERC20 is ERC20 {
    uint8 private immutable tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeeERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 10;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
            return;
        }

        super._update(from, to, value);
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
    uint256 internal constant INITIAL_RESERVE = 100e18;

    event PegAdjusted(uint256 previousAlpha, uint256 newAlpha, uint256 reserveRatio);

    event Fission(
        address indexed from,
        address indexed to,
        uint256 baseIn,
        uint256 neutronOut,
        uint256 protonOut,
        uint256 feeToTreasury
    );

    event ReactorDeployed(
        address indexed reactor,
        address indexed base,
        address indexed treasury,
        string vaultName,
        string baseAssetName,
        string baseAssetSymbol,
        string peggedAssetName,
        string peggedAssetSymbol,
        string protonName,
        string protonSymbol,
        address oracleAddress,
        uint256 fissionFee,
        uint256 fusionFee,
        uint256 criticalReserveRatioWad,
        uint256 initialReserve
    );

    function setUp() public {
        baseToken = new MockERC20("USD Coin", "USDC");

        // price = $1.00, 8 decimals like chainlink
        mockFeed = new MockFeed(100000000, 8);
        adapter = new ChainlinkToOracleAdapter(address(mockFeed));

        factory = new StableCoinFactory();

        reactor = _deployReactor(address(adapter));
    }

    function _deployReactor(address oracleAddress) internal returns (StableCoinReactor) {
        _prepareInitialReserve();
        return _deployReactorWithCriticalRatio(oracleAddress, 15e17);
    }

    function _prepareInitialReserve() internal {
        baseToken.mint(address(this), INITIAL_RESERVE);
        baseToken.approve(address(factory), INITIAL_RESERVE);
    }

    function _deployReactorWithCriticalRatio(address oracleAddress, uint256 criticalReserveRatio)
        internal
        returns (StableCoinReactor)
    {
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
            criticalReserveRatio,
            INITIAL_RESERVE
        );

        return StableCoinReactor(reactorAddr);
    }

    function _deployDecimalReactor(uint8 decimals_, uint256 initialReserve)
        internal
        returns (MockDecimalERC20 decimalToken, StableCoinReactor decimalReactor)
    {
        decimalToken = new MockDecimalERC20("USD Coin", "USDC", decimals_);
        StableCoinFactory decimalFactory = new StableCoinFactory();

        decimalToken.mint(address(this), initialReserve);
        decimalToken.approve(address(decimalFactory), initialReserve);

        address reactorAddress = decimalFactory.deployReactor(
            "Decimal Vault",
            "USD Coin",
            "USDC",
            "Gluon USD",
            "GUSD",
            address(decimalToken),
            address(adapter),
            "Gluon Gov",
            "GOV",
            treasury,
            0,
            0,
            15e17,
            initialReserve
        );

        decimalReactor = StableCoinReactor(reactorAddress);
    }

    function _deploySixDecimalReactor()
        internal
        returns (MockDecimalERC20 sixDecimalToken, StableCoinReactor sixDecimalReactor)
    {
        return _deployDecimalReactor(6, 100e6);
    }

    function _fundAndFission(address user, uint256 amount) internal {
        _adjustIntoOperatingRange();

        baseToken.mint(user, amount);

        vm.startPrank(user);
        baseToken.approve(address(reactor), amount);
        reactor.fission(amount, user);
        vm.stopPrank();
    }

    function _adjustIntoOperatingRange() internal {
        _adjustIntoOperatingRange(reactor);
    }

    function _adjustIntoOperatingRange(StableCoinReactor target) internal {
        uint256 iterations;

        while (
            (target.reserveRatioPeggedAsset() < target.CRITICAL_RESERVE_RATIO()
                    || target.reserveRatioPeggedAsset() > target.UPPER_RESERVE_RATIO()) && iterations < 100
        ) {
            target.adjustPeg();
            iterations++;
        }

        uint256 ratio = target.reserveRatioPeggedAsset();
        assertGe(ratio, target.CRITICAL_RESERVE_RATIO(), "failed to reach lower operating bound");
        assertLe(ratio, target.UPPER_RESERVE_RATIO(), "failed to reach upper operating bound");
    }

    function testFissionWithAdapter() public {
        address user = makeAddr("user");

        _fundAndFission(user, 100 * 1e18);

        uint256 neutronBal = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonBal = reactor.PROTON_TOKEN().balanceOf(user);

        assertTrue(neutronBal > 0, "Neutron tokens not minted");
        assertTrue(protonBal > 0, "Proton tokens not minted");
    }

    function testZeroDecimalReserveMatchesEighteenDecimalFissionAndFusion() public {
        (MockDecimalERC20 zeroDecimalToken, StableCoinReactor zeroDecimalReactor) = _deployDecimalReactor(0, 100);

        address user18 = makeAddr("zeroDecimal18User");
        address user0 = makeAddr("zeroDecimalUser");

        assertEq(
            zeroDecimalReactor.NEUTRON_TOKEN().totalSupply(),
            reactor.NEUTRON_TOKEN().totalSupply(),
            "zero-decimal neutron seed should match"
        );
        assertEq(
            zeroDecimalReactor.PROTON_TOKEN().totalSupply(),
            reactor.PROTON_TOKEN().totalSupply(),
            "zero-decimal proton seed should match"
        );
        assertEq(
            zeroDecimalReactor.reserveRatioPeggedAsset(),
            reactor.reserveRatioPeggedAsset(),
            "zero-decimal initial ratio should match"
        );

        baseToken.mint(user18, 25e18);
        zeroDecimalToken.mint(user0, 25);

        vm.startPrank(user18);
        baseToken.approve(address(reactor), 25e18);
        reactor.fission(25e18, user18);
        vm.stopPrank();

        vm.startPrank(user0);
        zeroDecimalToken.approve(address(zeroDecimalReactor), 25);
        zeroDecimalReactor.fission(25, user0);
        vm.stopPrank();

        assertEq(
            zeroDecimalReactor.NEUTRON_TOKEN().balanceOf(user0),
            reactor.NEUTRON_TOKEN().balanceOf(user18),
            "zero-decimal fission neutron output should match"
        );
        assertEq(
            zeroDecimalReactor.PROTON_TOKEN().balanceOf(user0),
            reactor.PROTON_TOKEN().balanceOf(user18),
            "zero-decimal fission proton output should match"
        );

        vm.prank(user18);
        reactor.fusion(10e18, user18);

        vm.prank(user0);
        zeroDecimalReactor.fusion(10, user0);

        assertEq(baseToken.balanceOf(user18), 10e18, "wrong 18-decimal fusion output");
        assertEq(zeroDecimalToken.balanceOf(user0), 10, "wrong zero-decimal fusion output");

        assertEq(
            zeroDecimalReactor.NEUTRON_TOKEN().balanceOf(user0),
            reactor.NEUTRON_TOKEN().balanceOf(user18),
            "zero-decimal post-fusion neutron balance should match"
        );
        assertEq(
            zeroDecimalReactor.PROTON_TOKEN().balanceOf(user0),
            reactor.PROTON_TOKEN().balanceOf(user18),
            "zero-decimal post-fusion proton balance should match"
        );
        assertEq(
            zeroDecimalReactor.reserveRatioPeggedAsset(),
            reactor.reserveRatioPeggedAsset(),
            "zero-decimal post-fusion ratio should match"
        );
    }

    function testSixDecimalDynamicBetaFeeMatchesEighteenDecimal() public {
        (MockDecimalERC20 sixDecimalToken, StableCoinReactor sixDecimalReactor) = _deploySixDecimalReactor();

        address user18 = makeAddr("dynamicBeta18User");
        address user6 = makeAddr("dynamicBeta6User");

        baseToken.mint(user18, 100e18);
        sixDecimalToken.mint(user6, 100e6);

        vm.startPrank(user18);
        baseToken.approve(address(reactor), 100e18);
        reactor.fission(100e18, user18);
        vm.stopPrank();

        vm.startPrank(user6);
        sixDecimalToken.approve(address(sixDecimalReactor), 100e6);
        sixDecimalReactor.fission(100e6, user6);
        vm.stopPrank();

        mockFeed.setPrice(120_000_000);

        vm.prank(treasury);
        reactor.setBetaParams(0, 5e17, 1e18);

        vm.prank(treasury);
        sixDecimalReactor.setBetaParams(0, 5e17, 1e18);

        // First beta+ establishes the same positive volume ledger in both reactors.
        vm.prank(user18);
        (uint256 firstOut18, uint256 firstFee18) = reactor.transmuteProtonToNeutron(1e18, user18);

        vm.prank(user6);
        (uint256 firstOut6, uint256 firstFee6) = sixDecimalReactor.transmuteProtonToNeutron(1e18, user6);

        assertEq(firstFee18, 0, "first beta+ fee should start at zero");
        assertEq(firstFee6, firstFee18, "first beta+ fee should match");
        assertEq(firstOut6, firstOut18, "first beta+ output should match");

        // The second beta+ exercises phi1 * decayedVolumeBase / reserveWad.
        vm.prank(user18);
        (uint256 secondOut18, uint256 secondFee18) = reactor.transmuteProtonToNeutron(1e18, user18);

        vm.prank(user6);
        (uint256 secondOut6, uint256 secondFee6) = sixDecimalReactor.transmuteProtonToNeutron(1e18, user6);

        assertGt(secondFee18, 0, "dynamic beta fee should be nonzero");
        assertEq(secondFee6, secondFee18, "dynamic beta fee should be decimal-independent");
        assertEq(secondOut6, secondOut18, "dynamic beta output should be decimal-independent");
    }

    function testSixDecimalReserveMatchesEighteenDecimalInitialization() public {
        (MockDecimalERC20 sixDecimalToken, StableCoinReactor sixDecimalReactor) = _deploySixDecimalReactor();

        assertEq(sixDecimalReactor.reserve(), 100e6, "wrong native six-decimal reserve");
        assertEq(sixDecimalToken.balanceOf(address(sixDecimalReactor)), 100e6);

        assertEq(
            sixDecimalReactor.NEUTRON_TOKEN().totalSupply(),
            reactor.NEUTRON_TOKEN().totalSupply(),
            "neutron seed should be decimal-independent"
        );

        assertEq(
            sixDecimalReactor.PROTON_TOKEN().totalSupply(),
            reactor.PROTON_TOKEN().totalSupply(),
            "proton seed should be decimal-independent"
        );

        assertEq(
            sixDecimalReactor.reserveRatioPeggedAsset(),
            reactor.reserveRatioPeggedAsset(),
            "reserve ratio should be decimal-independent"
        );

        assertEq(
            sixDecimalReactor.neutronPriceInBase(),
            reactor.neutronPriceInBase(),
            "neutron price should be decimal-independent"
        );

        assertEq(
            sixDecimalReactor.protonPriceInBase(),
            reactor.protonPriceInBase(),
            "proton price should be decimal-independent"
        );
    }

    function testSixDecimalReserveMatchesEighteenDecimalFissionAndFusion() public {
        (MockDecimalERC20 sixDecimalToken, StableCoinReactor sixDecimalReactor) = _deploySixDecimalReactor();

        address user18 = makeAddr("decimal18User");
        address user6 = makeAddr("decimal6User");

        baseToken.mint(user18, 25e18);
        sixDecimalToken.mint(user6, 25e6);

        vm.startPrank(user18);
        baseToken.approve(address(reactor), 25e18);
        reactor.fission(25e18, user18);
        vm.stopPrank();

        vm.startPrank(user6);
        sixDecimalToken.approve(address(sixDecimalReactor), 25e6);
        sixDecimalReactor.fission(25e6, user6);
        vm.stopPrank();

        assertEq(
            sixDecimalReactor.NEUTRON_TOKEN().balanceOf(user6),
            reactor.NEUTRON_TOKEN().balanceOf(user18),
            "fission neutron output should be decimal-independent"
        );

        assertEq(
            sixDecimalReactor.PROTON_TOKEN().balanceOf(user6),
            reactor.PROTON_TOKEN().balanceOf(user18),
            "fission proton output should be decimal-independent"
        );

        assertEq(
            sixDecimalReactor.reserveRatioPeggedAsset(),
            reactor.reserveRatioPeggedAsset(),
            "fission reserve ratio should be decimal-independent"
        );

        vm.prank(user18);
        reactor.fusion(10e18, user18);

        vm.prank(user6);
        sixDecimalReactor.fusion(10e6, user6);

        assertEq(baseToken.balanceOf(user18), 10e18, "wrong 18-decimal fusion output");
        assertEq(sixDecimalToken.balanceOf(user6), 10e6, "wrong six-decimal fusion output");

        assertEq(
            sixDecimalReactor.NEUTRON_TOKEN().balanceOf(user6),
            reactor.NEUTRON_TOKEN().balanceOf(user18),
            "post-fusion neutron balance should be decimal-independent"
        );

        assertEq(
            sixDecimalReactor.PROTON_TOKEN().balanceOf(user6),
            reactor.PROTON_TOKEN().balanceOf(user18),
            "post-fusion proton balance should be decimal-independent"
        );

        assertEq(
            sixDecimalReactor.reserveRatioPeggedAsset(),
            reactor.reserveRatioPeggedAsset(),
            "post-fusion reserve ratio should be decimal-independent"
        );
    }

    function testSixDecimalReserveMatchesEighteenDecimalTransmutations() public {
        (MockDecimalERC20 sixDecimalToken, StableCoinReactor sixDecimalReactor) = _deploySixDecimalReactor();

        address user18 = makeAddr("decimal18TransmuteUser");
        address user6 = makeAddr("decimal6TransmuteUser");

        baseToken.mint(user18, 100e18);
        sixDecimalToken.mint(user6, 100e6);

        vm.startPrank(user18);
        baseToken.approve(address(reactor), 100e18);
        reactor.fission(100e18, user18);
        vm.stopPrank();

        vm.startPrank(user6);
        sixDecimalToken.approve(address(sixDecimalReactor), 100e6);
        sixDecimalReactor.fission(100e6, user6);
        vm.stopPrank();

        mockFeed.setPrice(120_000_000);

        vm.prank(user18);
        (uint256 neutronOut18, uint256 plusFee18) = reactor.transmuteProtonToNeutron(1e18, user18);

        vm.prank(user6);
        (uint256 neutronOut6, uint256 plusFee6) = sixDecimalReactor.transmuteProtonToNeutron(1e18, user6);

        assertEq(neutronOut6, neutronOut18, "beta+ output should be decimal-independent");
        assertEq(plusFee6, plusFee18, "beta+ fee should be decimal-independent");

        vm.prank(user18);
        (uint256 protonOut18, uint256 minusFee18) = reactor.transmuteNeutronToProton(1e18, user18);

        vm.prank(user6);
        (uint256 protonOut6, uint256 minusFee6) = sixDecimalReactor.transmuteNeutronToProton(1e18, user6);

        assertEq(protonOut6, protonOut18, "beta- output should be decimal-independent");
        assertEq(minusFee6, minusFee18, "beta- fee should be decimal-independent");

        assertEq(
            sixDecimalReactor.reserveRatioPeggedAsset(),
            reactor.reserveRatioPeggedAsset(),
            "transmutation reserve ratio should be decimal-independent"
        );
    }

    function testSixDecimalFusionOfSmallestNativeUnitBurnsProtocolTokens() public {
        (MockDecimalERC20 sixDecimalToken, StableCoinReactor sixDecimalReactor) = _deploySixDecimalReactor();

        address user = makeAddr("sixDecimalTinyFusionUser");
        uint256 fissionAmount = 100e6;

        sixDecimalToken.mint(user, fissionAmount);

        vm.startPrank(user);
        sixDecimalToken.approve(address(sixDecimalReactor), fissionAmount);
        sixDecimalReactor.fission(fissionAmount, user);
        vm.stopPrank();

        uint256 neutronBefore = sixDecimalReactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonBefore = sixDecimalReactor.PROTON_TOKEN().balanceOf(user);

        vm.prank(user);
        sixDecimalReactor.fusion(1, user);

        assertEq(sixDecimalToken.balanceOf(user), 1, "wrong smallest-unit fusion output");
        assertLt(sixDecimalReactor.NEUTRON_TOKEN().balanceOf(user), neutronBefore, "fusion should burn Neutron");
        assertLt(sixDecimalReactor.PROTON_TOKEN().balanceOf(user), protonBefore, "fusion should burn Proton");
    }

    function testDeploymentRejectsReserveTokenAboveWadPrecision() public {
        MockDecimalERC20 highDecimalToken = new MockDecimalERC20("High Decimal Token", "HDT", 19);

        StableCoinFactory highDecimalFactory = new StableCoinFactory();

        uint256 initialReserve = 100e19;
        highDecimalToken.mint(address(this), initialReserve);
        highDecimalToken.approve(address(highDecimalFactory), initialReserve);

        vm.expectRevert(abi.encodeWithSelector(StableCoinReactor.InvalidBaseTokenDecimals.selector, uint8(19)));

        highDecimalFactory.deployReactor(
            "High Decimal Vault",
            "High Decimal Token",
            "HDT",
            "Gluon USD",
            "GUSD",
            address(highDecimalToken),
            address(adapter),
            "Gluon Gov",
            "GOV",
            treasury,
            0,
            0,
            15e17,
            initialReserve
        );
    }

    function testFusionRejectsWithdrawalWhenRequiredBurnRoundsToZero() public {
        address user = makeAddr("tinyFusionUser");

        _fundAndFission(user, 100e18);
        _adjustIntoOperatingRange();

        vm.prank(user);
        vm.expectRevert(StableCoinReactor.AmountTooSmall.selector);
        reactor.fusion(1, user);
    }

    function testTransmutationsRejectZeroOutputAtFullBetaFee() public {
        address user = makeAddr("fullBetaFeeUser");

        _fundAndFission(user, 100e18);
        _adjustIntoOperatingRange();

        vm.prank(treasury);
        reactor.setBetaParams(1e18, 0, 1e18);

        vm.startPrank(user);

        vm.expectRevert(StableCoinReactor.AmountTooSmall.selector);
        reactor.transmuteProtonToNeutron(1e18, user);

        vm.expectRevert(StableCoinReactor.AmountTooSmall.selector);
        reactor.transmuteNeutronToProton(1e18, user);

        vm.stopPrank();
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

        mockFeed.setPrice(120_000_000);

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

    function testZeroInitialOraclePriceRevertsWithoutBlockingFactory() public {
        MockFeed zeroFeed = new MockFeed(0, 8);
        ChainlinkToOracleAdapter zeroAdapter = new ChainlinkToOracleAdapter(address(zeroFeed));

        baseToken.mint(address(this), INITIAL_RESERVE);
        baseToken.approve(address(factory), INITIAL_RESERVE);

        uint256 countBefore = factory.getDeployedReactorsCount();

        vm.expectRevert(StableCoinReactor.InvalidInitialReserve.selector);

        factory.deployReactor(
            "Gluon Vault",
            "USD Coin",
            "USDC",
            "Gluon USD",
            "GUSD",
            address(baseToken),
            address(zeroAdapter),
            "Gluon Gov",
            "GOV",
            treasury,
            0,
            0,
            15e17,
            INITIAL_RESERVE
        );

        assertEq(factory.getDeployedReactorsCount(), countBefore, "failed deployment should not be registered");

        StableCoinReactor nextReactor = _deployReactorWithCriticalRatio(address(adapter), 15e17);

        assertEq(factory.getDeployedReactorsCount(), countBefore + 1, "factory should remain usable");
        assertEq(nextReactor.reserve(), INITIAL_RESERVE, "next deployment should initialize normally");
    }

    function testInitialFissionIsFactoryOnlyAndOneTime() public {
        vm.expectRevert(StableCoinReactor.OnlyFactory.selector);
        reactor.initialFission(INITIAL_RESERVE);

        vm.expectRevert(StableCoinReactor.AlreadyInitialized.selector);
        vm.prank(address(factory));
        reactor.initialFission(INITIAL_RESERVE);
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
            15e17,
            INITIAL_RESERVE
        );
    }

    function testReactorRejectsCriticalRatioAtUpperBound() public {
        uint256 upperReserveRatio = reactor.UPPER_RESERVE_RATIO();

        _prepareInitialReserve();

        vm.expectRevert(StableCoinReactor.InvalidCriticalReserveRatio.selector);
        _deployReactorWithCriticalRatio(address(adapter), upperReserveRatio);
    }

    function testReactorRejectsCriticalRatioAboveUpperBound() public {
        uint256 upperReserveRatio = reactor.UPPER_RESERVE_RATIO();

        _prepareInitialReserve();

        vm.expectRevert(StableCoinReactor.InvalidCriticalReserveRatio.selector);
        _deployReactorWithCriticalRatio(address(adapter), upperReserveRatio + 1);
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
            15e17,
            INITIAL_RESERVE
        );
    }

    function testPrefundedInitializationWithFissionFeeAccountsForFullSeed() public {
        uint256 factoryNonce = vm.getNonce(address(factory));
        address predictedReactor = vm.computeCreateAddress(address(factory), factoryNonce);

        uint256 prefundedAmount = 50e18;
        uint256 requestedReserve = 100e18;
        uint256 fissionFee = 1e17;

        uint256 totalSeed = prefundedAmount + requestedReserve;
        uint256 expectedFee = Math.mulDiv(totalSeed, fissionFee, 1e18);
        uint256 expectedReserve = totalSeed - expectedFee;

        uint256 expectedNeutronSeed = Math.mulDiv(expectedReserve, 1e18, 15e17);
        uint256 expectedProtonSeed = expectedReserve - expectedNeutronSeed;

        baseToken.mint(predictedReactor, prefundedAmount);

        baseToken.mint(address(this), requestedReserve);
        baseToken.approve(address(factory), requestedReserve);

        uint256 treasuryBefore = baseToken.balanceOf(treasury);

        StableCoinReactor prefundedFeeReactor = StableCoinReactor(
            factory.deployReactor(
                "Prefunded Fee Vault",
                "USD Coin",
                "USDC",
                "Gluon USD",
                "GUSD",
                address(baseToken),
                address(adapter),
                "Gluon Gov",
                "GOV",
                treasury,
                fissionFee,
                0,
                15e17,
                requestedReserve
            )
        );

        assertEq(address(prefundedFeeReactor), predictedReactor, "unexpected reactor address");

        assertEq(baseToken.balanceOf(treasury), treasuryBefore + expectedFee, "wrong initial fission fee");

        assertEq(prefundedFeeReactor.reserve(), expectedReserve, "wrong reserve after prefunding and fee");

        assertEq(prefundedFeeReactor.NEUTRON_TOKEN().totalSupply(), expectedNeutronSeed, "wrong neutron seed");

        assertEq(prefundedFeeReactor.PROTON_TOKEN().totalSupply(), expectedProtonSeed, "wrong proton seed");

        assertEq(
            prefundedFeeReactor.NEUTRON_TOKEN().balanceOf(address(prefundedFeeReactor)),
            expectedNeutronSeed,
            "neutron seed should remain locked"
        );

        assertEq(
            prefundedFeeReactor.PROTON_TOKEN().balanceOf(address(prefundedFeeReactor)),
            expectedProtonSeed,
            "proton seed should remain locked"
        );

        assertEq(
            prefundedFeeReactor.reserveRatioPeggedAsset(),
            15e17,
            "prefunded fee initialization should preserve target ratio"
        );
    }

    function testDeploymentAccountsForPrefundedReactorAddress() public {
        uint256 factoryNonce = vm.getNonce(address(factory));
        address predictedReactor = vm.computeCreateAddress(address(factory), factoryNonce);

        uint256 prefundedAmount = 50e18;
        baseToken.mint(predictedReactor, prefundedAmount);

        _prepareInitialReserve();

        StableCoinReactor prefundedReactor = _deployReactorWithCriticalRatio(address(adapter), 15e17);

        assertEq(address(prefundedReactor), predictedReactor, "unexpected reactor address");

        assertEq(prefundedReactor.reserve(), INITIAL_RESERVE + prefundedAmount, "prefunded reserve should be included");

        assertEq(
            prefundedReactor.reserveRatioPeggedAsset(), 15e17, "prefunded reserve should be included in seed accounting"
        );
    }

    function testDeploymentInitializesReserveAndLockedSupply() public view {
        uint256 neutronSupply = reactor.NEUTRON_TOKEN().totalSupply();
        uint256 protonSupply = reactor.PROTON_TOKEN().totalSupply();

        assertEq(reactor.reserve(), INITIAL_RESERVE, "wrong initial reserve");
        assertGt(neutronSupply, 0, "neutron seed missing");
        assertGt(protonSupply, 0, "proton seed missing");

        assertEq(
            reactor.NEUTRON_TOKEN().balanceOf(address(reactor)),
            neutronSupply,
            "neutron seed should be locked in reactor"
        );
        assertEq(
            reactor.PROTON_TOKEN().balanceOf(address(reactor)), protonSupply, "proton seed should be locked in reactor"
        );

        assertEq(reactor.reserveRatioPeggedAsset(), 15e17, "wrong initial reserve ratio");
    }

    function testDeploymentStartsInsideOperatingRange() public {
        uint256 ratio = reactor.reserveRatioPeggedAsset();

        assertGe(ratio, reactor.CRITICAL_RESERVE_RATIO());
        assertLe(ratio, reactor.UPPER_RESERVE_RATIO());

        vm.expectRevert(StableCoinReactor.PegAdjustmentNotNeeded.selector);
        reactor.adjustPeg();
    }

    function testDeploymentRejectsInitialRatioBelowCritical() public {
        _prepareInitialReserve();

        vm.expectRevert(StableCoinReactor.InvalidInitialReserve.selector);
        _deployReactorWithCriticalRatio(address(adapter), 16e17);
    }

    function testDeploymentRejectsRoundedInitialRatioAboveUpperBound() public {
        MockFeed roundedFeed = new MockFeed(110_000_000, 8);
        ChainlinkToOracleAdapter roundedAdapter = new ChainlinkToOracleAdapter(address(roundedFeed));

        uint256 tinyReserve = 2;
        baseToken.mint(address(this), tinyReserve);
        baseToken.approve(address(factory), tinyReserve);

        vm.expectRevert(StableCoinReactor.InvalidInitialReserve.selector);

        factory.deployReactor(
            "Gluon Vault",
            "USD Coin",
            "USDC",
            "Gluon USD",
            "GUSD",
            address(baseToken),
            address(roundedAdapter),
            "Gluon Gov",
            "GOV",
            treasury,
            0,
            0,
            15e17,
            tinyReserve
        );
    }

    function testDeploymentSeedsTargetReserveRatioAtNonUnitPrice() public {
        MockFeed pricedFeed = new MockFeed(123_456_789, 8);
        ChainlinkToOracleAdapter pricedAdapter = new ChainlinkToOracleAdapter(address(pricedFeed));

        _prepareInitialReserve();

        StableCoinReactor seededReactor = _deployReactorWithCriticalRatio(address(pricedAdapter), 15e17);

        uint256 basePrice = pricedAdapter.readValue();
        uint256 expectedNeutronSeed = (INITIAL_RESERVE * basePrice) / 15e17;
        uint256 neutronPriceBase = seededReactor.neutronPriceInBase();
        uint256 neutronLiability = (expectedNeutronSeed * neutronPriceBase) / 1e18;
        uint256 expectedProtonSeed = INITIAL_RESERVE - neutronLiability;

        assertEq(seededReactor.NEUTRON_TOKEN().totalSupply(), expectedNeutronSeed, "wrong neutron seed");
        assertEq(seededReactor.PROTON_TOKEN().totalSupply(), expectedProtonSeed, "wrong proton seed");
        assertEq(seededReactor.reserveRatioPeggedAsset(), 15e17, "wrong non-unit-price initial ratio");
        assertEq(seededReactor.protonPriceInBase(), 1e18, "wrong initial proton price");
    }

    function testFactoryReportsActualReceivedInitialReserve() public {
        MockFeeERC20 feeToken = new MockFeeERC20("Fee Token", "FEE");

        uint256 requestedReserve = 100e18;
        uint256 receivedReserve = 81e18;

        feeToken.mint(address(this), requestedReserve);
        feeToken.approve(address(factory), requestedReserve);

        vm.expectEmit(false, false, false, true, address(factory));
        emit ReactorDeployed(
            address(0),
            address(0),
            address(0),
            "Gluon Vault",
            "Fee Token",
            "FEE",
            "Gluon USD",
            "GUSD",
            "Gluon Gov",
            "GOV",
            address(adapter),
            0,
            0,
            15e17,
            receivedReserve
        );

        address reactorAddress = factory.deployReactor(
            "Gluon Vault",
            "Fee Token",
            "FEE",
            "Gluon USD",
            "GUSD",
            address(feeToken),
            address(adapter),
            "Gluon Gov",
            "GOV",
            treasury,
            0,
            0,
            15e17,
            requestedReserve
        );

        assertEq(StableCoinReactor(reactorAddress).reserve(), receivedReserve, "wrong received reserve");
    }

    function testFissionUsesActualReceivedReserve() public {
        MockFeeERC20 feeToken = new MockFeeERC20("Fee Token", "FEE");
        uint256 requestedReserve = 100e18;

        feeToken.mint(address(this), requestedReserve);
        feeToken.approve(address(factory), requestedReserve);

        StableCoinReactor feeReactor = StableCoinReactor(
            factory.deployReactor(
                "Gluon Vault",
                "Fee Token",
                "FEE",
                "Gluon USD",
                "GUSD",
                address(feeToken),
                address(adapter),
                "Gluon Gov",
                "GOV",
                treasury,
                1e17,
                0,
                15e17,
                requestedReserve
            )
        );

        uint256 reserveBefore = feeReactor.reserve();
        uint256 neutronSupplyBefore = feeReactor.NEUTRON_TOKEN().totalSupply();
        uint256 protonSupplyBefore = feeReactor.PROTON_TOKEN().totalSupply();

        address user = makeAddr("feeTokenFissionUser");
        uint256 amountIn = 100e18;
        uint256 received = 90e18;
        uint256 expectedFee = 9e18;
        uint256 net = received - expectedFee;

        uint256 expectedNeutronOut = net * neutronSupplyBefore / reserveBefore;
        uint256 expectedProtonOut = net * protonSupplyBefore / reserveBefore;

        feeToken.mint(user, amountIn);

        vm.startPrank(user);
        feeToken.approve(address(feeReactor), amountIn);

        vm.expectEmit(true, true, false, true, address(feeReactor));
        emit Fission(user, user, received, expectedNeutronOut, expectedProtonOut, expectedFee);

        feeReactor.fission(amountIn, user);
        vm.stopPrank();

        assertEq(feeReactor.reserve(), reserveBefore + net, "wrong reserve increase");
        assertEq(feeReactor.NEUTRON_TOKEN().balanceOf(user), expectedNeutronOut, "wrong neutron output");
        assertEq(feeReactor.PROTON_TOKEN().balanceOf(user), expectedProtonOut, "wrong proton output");
    }

    function testInitialFissionUsesConfiguredFissionFee() public {
        _prepareInitialReserve();

        uint256 treasuryBefore = baseToken.balanceOf(treasury);

        StableCoinReactor feeReactor = StableCoinReactor(
            factory.deployReactor(
                "Fee Seed Vault",
                "USD Coin",
                "USDC",
                "Gluon USD",
                "GUSD",
                address(baseToken),
                address(adapter),
                "Gluon Gov",
                "GOV",
                treasury,
                1e17,
                0,
                15e17,
                INITIAL_RESERVE
            )
        );

        uint256 expectedFee = 10e18;
        uint256 expectedReserve = INITIAL_RESERVE - expectedFee;

        assertEq(baseToken.balanceOf(treasury), treasuryBefore + expectedFee, "wrong initial fission fee");
        assertEq(feeReactor.reserve(), expectedReserve, "wrong reserve after initial fission fee");
        assertEq(feeReactor.reserveRatioPeggedAsset(), 15e17, "initial ratio changed after fee");
    }

    function testFissionAfterAlphaAdjustmentKeepsProportionalAccounting() public {
        address firstUser = makeAddr("alphaSetupUser");
        _fundAndFission(firstUser, 100e18);

        mockFeed.setPrice(2e8);
        _adjustIntoOperatingRange();

        assertGt(reactor.alpha(), 1e18, "precondition: alpha should be above one");

        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();
        uint256 reserveBefore = reactor.reserve();
        uint256 neutronSupplyBefore = reactor.NEUTRON_TOKEN().totalSupply();
        uint256 protonSupplyBefore = reactor.PROTON_TOKEN().totalSupply();

        address user = makeAddr("alphaFissionUser");
        uint256 amountIn = 17e18;

        uint256 expectedNeutronOut = amountIn * neutronSupplyBefore / reserveBefore;
        uint256 expectedProtonOut = amountIn * protonSupplyBefore / reserveBefore;

        baseToken.mint(user, amountIn);

        vm.startPrank(user);
        baseToken.approve(address(reactor), amountIn);
        reactor.fission(amountIn, user);
        vm.stopPrank();

        assertApproxEqAbs(
            reactor.NEUTRON_TOKEN().balanceOf(user),
            expectedNeutronOut,
            100,
            "wrong neutron output after alpha adjustment"
        );

        assertApproxEqAbs(
            reactor.PROTON_TOKEN().balanceOf(user), expectedProtonOut, 100, "wrong proton output after alpha adjustment"
        );

        assertApproxEqAbs(reactor.reserveRatioPeggedAsset(), ratioBefore, 100, "fission should preserve reserve ratio");
    }

    function testFissionAtOneReserveRatioKeepsProtonProportional() public {
        _prepareInitialReserve();

        StableCoinReactor boundaryReactor = _deployReactorWithCriticalRatio(address(adapter), 1e18);

        uint256 neutronSupplyBefore = boundaryReactor.NEUTRON_TOKEN().totalSupply();
        uint256 protonSupplyBefore = boundaryReactor.PROTON_TOKEN().totalSupply();

        uint256 reserveToRemove = boundaryReactor.reserve() - neutronSupplyBefore;

        vm.prank(address(boundaryReactor));
        assertTrue(baseToken.transfer(makeAddr("oneRatioReserveSink"), reserveToRemove), "reserve transfer failed");

        assertEq(boundaryReactor.reserveRatioPeggedAsset(), 1e18, "precondition: reserve ratio should equal one");

        assertEq(boundaryReactor.protonPriceInBase(), 0, "precondition: proton price should be zero");

        uint256 reserveBefore = boundaryReactor.reserve();

        address user = makeAddr("oneRatioFissionUser");
        uint256 amountIn = 10e18;

        uint256 expectedNeutronOut = amountIn * neutronSupplyBefore / reserveBefore;

        uint256 expectedProtonOut = amountIn * protonSupplyBefore / reserveBefore;

        baseToken.mint(user, amountIn);

        vm.startPrank(user);
        baseToken.approve(address(boundaryReactor), amountIn);
        boundaryReactor.fission(amountIn, user);
        vm.stopPrank();

        assertEq(
            boundaryReactor.NEUTRON_TOKEN().balanceOf(user), expectedNeutronOut, "wrong neutron output at 100% ratio"
        );

        assertEq(boundaryReactor.PROTON_TOKEN().balanceOf(user), expectedProtonOut, "wrong proton output at 100% ratio");

        assertEq(boundaryReactor.reserveRatioPeggedAsset(), 1e18, "fission should preserve 100% reserve ratio");
    }

    function testFissionProtonOutputIsProportionalJustAboveCriticalRatio() public {
        _prepareInitialReserve();

        StableCoinReactor boundaryReactor = _deployReactorWithCriticalRatio(address(adapter), 1e18);

        // Move the oracle price so the live reserve ratio is just above 1e18.
        // This is a normal reachable state and keeps protonPriceInBase non-zero.
        mockFeed.setPrice(66_666_667);

        uint256 ratioBefore = boundaryReactor.reserveRatioPeggedAsset();

        assertGt(ratioBefore, 1e18, "ratio should be above critical");
        assertLe(ratioBefore, boundaryReactor.UPPER_RESERVE_RATIO(), "ratio should be inside operating range");
        assertGt(boundaryReactor.protonPriceInBase(), 0, "proton price should be nonzero");

        uint256 reserveBefore = boundaryReactor.reserve();
        uint256 protonSupplyBefore = boundaryReactor.PROTON_TOKEN().totalSupply();

        address user = makeAddr("nearCriticalFissionUser");
        uint256 amountIn = 1_000_000;

        uint256 expectedProtonOut = Math.mulDiv(amountIn, protonSupplyBefore, reserveBefore);

        baseToken.mint(user, amountIn);

        vm.startPrank(user);
        baseToken.approve(address(boundaryReactor), amountIn);
        boundaryReactor.fission(amountIn, user);
        vm.stopPrank();

        assertEq(
            boundaryReactor.PROTON_TOKEN().balanceOf(user),
            expectedProtonOut,
            "proton output should remain proportional just above critical ratio"
        );
    }

    function testInitializationSeedRemainsAfterUserExit() public {
        address user = makeAddr("seedInvariantUser");

        _fundAndFission(user, INITIAL_RESERVE);

        vm.prank(user);
        reactor.fusion(INITIAL_RESERVE, user);

        assertEq(reactor.reserve(), INITIAL_RESERVE, "seed reserve should remain");
        assertEq(
            reactor.NEUTRON_TOKEN().totalSupply(),
            reactor.NEUTRON_TOKEN().balanceOf(address(reactor)),
            "neutron seed should remain"
        );
        assertEq(
            reactor.PROTON_TOKEN().totalSupply(),
            reactor.PROTON_TOKEN().balanceOf(address(reactor)),
            "proton seed should remain"
        );
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
        mockFeed.setPrice(2 * 1e8);

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

    function testTransmutationsAreNoOpWhenOraclePriceIsZero() public {
        address user = makeAddr("zeroOracleTransmutationUser");
        _fundAndFission(user, 100e18);

        mockFeed.setPrice(0);

        uint256 protonBalanceBefore = reactor.PROTON_TOKEN().balanceOf(user);
        uint256 neutronBalanceBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonSupplyBefore = reactor.PROTON_TOKEN().totalSupply();
        uint256 neutronSupplyBefore = reactor.NEUTRON_TOKEN().totalSupply();

        vm.startPrank(user);
        (uint256 neutronOut, uint256 plusFee) = reactor.transmuteProtonToNeutron(1e18, user);
        (uint256 protonOut, uint256 minusFee) = reactor.transmuteNeutronToProton(1e18, user);
        vm.stopPrank();

        assertEq(neutronOut, 0);
        assertEq(protonOut, 0);
        assertEq(plusFee, 0);
        assertEq(minusFee, 0);

        assertEq(reactor.PROTON_TOKEN().balanceOf(user), protonBalanceBefore);
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), neutronBalanceBefore);
        assertEq(reactor.PROTON_TOKEN().totalSupply(), protonSupplyBefore);
        assertEq(reactor.NEUTRON_TOKEN().totalSupply(), neutronSupplyBefore);
    }

    function testTransmutationIsNoOpWhenProtonPriceIsZero() public {
        _prepareInitialReserve();
        StableCoinReactor boundaryReactor = _deployReactorWithCriticalRatio(address(adapter), 1e18);

        uint256 neutronSupply = boundaryReactor.NEUTRON_TOKEN().totalSupply();
        uint256 reserveToRemove = boundaryReactor.reserve() - neutronSupply;

        vm.prank(address(boundaryReactor));
        assertTrue(baseToken.transfer(makeAddr("reserveSink"), reserveToRemove), "reserve transfer failed");

        assertEq(boundaryReactor.reserveRatioPeggedAsset(), 1e18, "expected 100% reserve ratio");
        assertEq(boundaryReactor.protonPriceInBase(), 0, "proton price should be zero");

        address user = makeAddr("zeroProtonPriceUser");

        vm.startPrank(address(boundaryReactor));
        boundaryReactor.PROTON_TOKEN().transfer(user, 1e18);
        boundaryReactor.NEUTRON_TOKEN().transfer(user, 1e18);
        vm.stopPrank();

        uint256 protonBalanceBefore = boundaryReactor.PROTON_TOKEN().balanceOf(user);
        uint256 neutronBalanceBefore = boundaryReactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonSupplyBefore = boundaryReactor.PROTON_TOKEN().totalSupply();
        uint256 neutronSupplyBefore = boundaryReactor.NEUTRON_TOKEN().totalSupply();

        vm.startPrank(user);
        (uint256 neutronOut, uint256 plusFee) = boundaryReactor.transmuteProtonToNeutron(1e18, user);
        (uint256 protonOut, uint256 minusFee) = boundaryReactor.transmuteNeutronToProton(1e18, user);
        vm.stopPrank();

        assertEq(neutronOut, 0);
        assertEq(protonOut, 0);
        assertEq(plusFee, 0);
        assertEq(minusFee, 0);

        assertEq(boundaryReactor.PROTON_TOKEN().balanceOf(user), protonBalanceBefore);
        assertEq(boundaryReactor.NEUTRON_TOKEN().balanceOf(user), neutronBalanceBefore);
        assertEq(boundaryReactor.PROTON_TOKEN().totalSupply(), protonSupplyBefore);
        assertEq(boundaryReactor.NEUTRON_TOKEN().totalSupply(), neutronSupplyBefore);
    }

    function testBetaPlusRevertsIfResultFallsBelowCriticalRatio() public {
        address user = makeAddr("betaPlusLowerBoundUser");

        _fundAndFission(user, 100e18);
        _adjustIntoOperatingRange();

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
        reactor.transmuteNeutronToProton(40e18, user);

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

    function testAdjustPegIncreasesAlphaAboveUpperBound() public {
        address user = makeAddr("highRatioUser");

        _fundAndFission(user, 100e18);
        mockFeed.setPrice(2 * 1e8);

        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();
        assertGt(ratioBefore, reactor.UPPER_RESERVE_RATIO(), "precondition: ratio should be above 200%");

        uint256 alphaBefore = reactor.alpha();
        uint256 expectedAlpha = (alphaBefore * reactor.ALPHA_UP_FACTOR()) / 1e18;

        vm.expectEmit(false, false, false, true, address(reactor));
        emit PegAdjusted(alphaBefore, expectedAlpha, ratioBefore);

        reactor.adjustPeg();

        uint256 ratioAfter = reactor.reserveRatioPeggedAsset();

        assertEq(reactor.alpha(), expectedAlpha, "alpha should increase by 1%");
        assertLt(ratioAfter, ratioBefore, "increasing alpha should decrease reserve ratio");
    }

    function testAdjustPegDoesNotChangeAlphaAtZeroOraclePrice() public {
        mockFeed.setPrice(0);

        uint256 alphaBefore = reactor.alpha();

        reactor.adjustPeg();

        assertEq(reactor.alpha(), alphaBefore, "zero oracle price should not change alpha");
        assertEq(reactor.reserveRatioPeggedAsset(), 0, "zero oracle price should produce zero reserve ratio");
    }

    function testAdjustPegDecreasesAlphaBelowCriticalRatio() public {
        address user = makeAddr("lowRatioUser");

        _fundAndFission(user, 100e18);
        mockFeed.setPrice(40_000_000);

        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();
        assertLt(
            ratioBefore, reactor.CRITICAL_RESERVE_RATIO(), "precondition: ratio should be below critical reserve ratio"
        );

        uint256 alphaBefore = reactor.alpha();
        uint256 expectedAlpha = (alphaBefore * reactor.ALPHA_DOWN_FACTOR()) / 1e18;

        reactor.adjustPeg();

        uint256 ratioAfter = reactor.reserveRatioPeggedAsset();

        assertEq(reactor.alpha(), expectedAlpha, "alpha should decrease by 1%");
        assertGt(ratioAfter, ratioBefore, "decreasing alpha should increase reserve ratio");
    }

    function testRepeatedAdjustPegFromHighRatioReturnsToOperatingRange() public {
        address user = makeAddr("repeatedHighRatioUser");
        _fundAndFission(user, 100e18);
        mockFeed.setPrice(2 * 1e8);

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

        mockFeed.setPrice(110_000_000);

        uint256 ratio = reactor.reserveRatioPeggedAsset();
        assertGe(ratio, reactor.CRITICAL_RESERVE_RATIO(), "precondition: ratio below lower bound");
        assertLe(ratio, reactor.UPPER_RESERVE_RATIO(), "precondition: ratio above upper bound");

        vm.expectRevert(StableCoinReactor.PegAdjustmentNotNeeded.selector);
        reactor.adjustPeg();
    }

    function testQIsDerivedFromReserveRatio() public {
        address user = makeAddr("qFromRatioUser");
        _fundAndFission(user, 100e18);

        uint256 ratio = reactor.reserveRatioPeggedAsset();
        uint256 expectedQ = (1e18 * 1e18) / ratio;

        if (expectedQ > 1e18) expectedQ = 1e18;

        assertEq(reactor.qWad(), expectedQ, "q should be derived from reserve ratio");
    }

    function testProtonPriceEqualsEquityPerProton() public {
        address user = makeAddr("equityPriceUser");
        _fundAndFission(user, 100e18);

        uint256 reserveBalance = reactor.reserve();
        uint256 neutronSupply = reactor.NEUTRON_TOKEN().totalSupply();
        uint256 protonSupply = reactor.PROTON_TOKEN().totalSupply();
        uint256 neutronPrice = reactor.neutronPriceInBase();

        uint256 liabilities = (neutronSupply * neutronPrice) / 1e18;
        uint256 equity = reserveBalance - liabilities;
        uint256 expectedProtonPrice = (equity * 1e18) / protonSupply;

        assertEq(reactor.protonPriceInBase(), expectedProtonPrice, "proton price should equal equity per proton");
    }

    function testAlphaStartsAtWad() public view {
        assertEq(reactor.alpha(), 1e18, "alpha should start at 1");
    }
}
