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

        vm.expectRevert("bad value");
        badReactor.fission(amount, user);

        vm.stopPrank();
    }

    function testReactorRejectsZeroOracle() public {
        vm.expectRevert("Invalid oracle");

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

        vm.expectRevert("Oracle not contract");

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
}
