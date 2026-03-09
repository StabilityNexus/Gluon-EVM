// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {Tokeon} from "../src/tokens/Tokeon.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title StableCoinReactor – property & invariant tests
/// @notice Tests economic properties of the reactor, not implementation details.
contract StableCoinReactorTest is Test {
    uint256 constant WAD = 1e18;

    StableCoinReactor reactor;
    MockERC20 base;
    MockPyth pyth;
    Tokeon neutron;
    Tokeon proton;

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    bytes32 constant PRICE_ID = bytes32(uint256(1));

    uint256 constant FISSION_FEE = 0.01e18;  // 1%
    uint256 constant FUSION_FEE = 0.01e18;   // 1%
    uint256 constant CRITICAL_RATIO = 1.5e18; // 150%

    function setUp() public {
        base = new MockERC20("Wrapped ETH", "WETH", 18);
        pyth = new MockPyth(0);

        // Base price = $2000 (expo = -8 → price = 200_000_000_000)
        pyth.setPrice(PRICE_ID, 200_000_000_000, -8, 0);

        reactor = new StableCoinReactor(
            "ETH Vault",
            "Wrapped ETH",
            "WETH",
            "Neutron USD",
            "nUSD",
            address(base),
            address(pyth),
            PRICE_ID,
            "Proton ETH",
            "pETH",
            treasury,
            FISSION_FEE,
            FUSION_FEE,
            CRITICAL_RATIO
        );

        neutron = reactor.NEUTRON_TOKEN();
        proton = reactor.PROTON_TOKEN();
    }

    function _fundAndApprove(address user, uint256 amount) internal {
        base.mint(user, amount);
        vm.prank(user);
        base.approve(address(reactor), amount);
    }

    function _fission(address user, uint256 amount) internal {
        _fundAndApprove(user, amount);
        bytes[] memory empty = new bytes[](0);
        vm.prank(user);
        reactor.fission(amount, user, empty);
    }

    function test_roundTrip_fissionThenFusion() public {
        uint256 deposit = 10 ether;
        _fission(alice, deposit);

        uint256 reserveBefore = reactor.reserve();
        uint256 aliceBaseBefore = base.balanceOf(alice);

        vm.prank(alice);
        reactor.fusion(reserveBefore, alice);

        uint256 recovered = base.balanceOf(alice) - aliceBaseBefore;

        assertTrue(recovered < deposit, "round-trip should cost fees");
        assertTrue(recovered > 0, "round-trip should return something");
        assertEq(neutron.totalSupply(), 0, "neutron supply not zero after full fusion");
        assertEq(proton.totalSupply(), 0, "proton supply not zero after full fusion");
        assertEq(
            recovered + base.balanceOf(treasury),
            deposit,
            "user recovery + treasury != deposit"
        );
    }

    /// @dev Fuzzes oracle price $0.01–$100K to check q·R + (1-q)·R = R under WAD rounding.
    function testFuzz_valueIdentity_acrossPrices(uint256 priceRaw) public {
        priceRaw = bound(priceRaw, 1_000_000, 10_000_000_000_000); // $0.01 – $100K (expo=-8)

        pyth.setPrice(PRICE_ID, int64(uint64(priceRaw)), -8, 0);

        _fission(alice, 10 ether);

        uint256 nValue = Math.mulDiv(reactor.neutronPriceInBase(), neutron.totalSupply(), WAD);
        uint256 pValue = Math.mulDiv(reactor.protonPriceInBase(), proton.totalSupply(), WAD);
        uint256 reserveBalance = reactor.reserve();

        uint256 tolerance = reserveBalance / 1e9 + 1; // ≤1 ppb rounding tolerance
        assertApproxEqAbs(
            nValue + pValue,
            reserveBalance,
            tolerance,
            "neutron_value + proton_value should equal reserve"
        );
    }

    function test_bootstrap_thenProportionalMinting() public {
        _fission(alice, 10 ether);

        assertTrue(reactor.reserve() > 0, "bootstrap: reserve = 0");
        assertTrue(neutron.totalSupply() > 0, "bootstrap: neutron supply = 0");
        assertTrue(proton.totalSupply() > 0, "bootstrap: proton supply = 0");

        _fission(bob, 10 ether); // takes proportional path

        assertEq(
            neutron.balanceOf(bob), neutron.balanceOf(alice),
            "equal deposits should yield equal neutrons"
        );
        assertEq(
            proton.balanceOf(bob), proton.balanceOf(alice),
            "equal deposits should yield equal protons"
        );
    }

    function testFuzz_roundTrip_neverProfitable(uint256 deposit) public {
        deposit = bound(deposit, 1000, 100_000_000 ether);

        _fission(alice, deposit);

        uint256 aliceBaseBefore = base.balanceOf(alice);
        uint256 reserveAmount = reactor.reserve();

        vm.prank(alice);
        reactor.fusion(reserveAmount, alice);

        assertTrue(
            base.balanceOf(alice) - aliceBaseBefore <= deposit,
            "round-trip must never be profitable"
        );
    }

    function test_transmuteRoundTrip_protonToNeutronToProton() public {
        _fission(alice, 10 ether);

        vm.prank(treasury);
        reactor.setBetaParams(0.01e18, 0, WAD); // phi0=1%, no decay

        uint256 protonStart = proton.balanceOf(alice);
        uint256 reserveBefore = reactor.reserve();
        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();
        bytes[] memory empty = new bytes[](0);

        vm.prank(alice);
        (uint256 neutronMid,) = reactor.transmuteProtonToNeutron(protonStart, alice, empty);
        assertTrue(neutronMid > 0, "transmute should produce neutrons");

        vm.prank(alice);
        (uint256 protonEnd,) = reactor.transmuteNeutronToProton(neutronMid, alice, empty);

        assertTrue(protonEnd <= protonStart, "transmute round-trip must not create proton value");
        assertEq(reactor.reserve(), reserveBefore, "raw reserve should not change during transmutation");
        assertTrue(reactor.reserveRatioPeggedAsset() >= ratioBefore, "reserve ratio should increase after fee-bearing transmutation");
    }

    function test_transmuteRoundTrip_neutronToProtonToNeutron() public {
        _fission(alice, 10 ether);

        vm.prank(treasury);
        reactor.setBetaParams(0.01e18, 0, WAD); // phi0=1%, no decay

        uint256 neutronStart = neutron.balanceOf(alice);
        uint256 reserveBefore = reactor.reserve();
        uint256 ratioBefore = reactor.reserveRatioPeggedAsset();
        bytes[] memory empty = new bytes[](0);

        vm.prank(alice);
        (uint256 protonMid,) = reactor.transmuteNeutronToProton(neutronStart, alice, empty);
        assertTrue(protonMid > 0, "transmute should produce protons");

        vm.prank(alice);
        (uint256 neutronEnd,) = reactor.transmuteProtonToNeutron(protonMid, alice, empty);

        assertTrue(neutronEnd <= neutronStart, "transmute round-trip must not create neutron value");
        assertEq(reactor.reserve(), reserveBefore, "raw reserve should not change during transmutation");
        assertTrue(reactor.reserveRatioPeggedAsset() >= ratioBefore, "reserve ratio should increase after fee-bearing transmutation");
    }
}