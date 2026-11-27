// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockERC20} from "./GenericIOracleIntegration.t.sol";

/// Oracle whose readValue() succeeds but returns only the first `returnLength` bytes of the value.
contract ShortReturnOracle {
    uint256 public value;
    uint256 public returnLength = 32;

    constructor(uint256 value_) {
        value = value_;
    }

    function set(uint256 value_, uint256 returnLength_) external {
        value = value_;
        returnLength = returnLength_;
    }

    function readValue() external view returns (uint256) {
        uint256 v = value;
        uint256 len = returnLength;
        assembly {
            mstore(0, v)
            return(0, len)
        }
    }
}

/// A successful oracle call with empty or short return data is treated like a reverting oracle:
/// the reactor keeps using its cached price instead of reverting the whole operation.
contract OracleShortReturnTest is Test {
    uint256 private constant PRICE = 2000e18;

    ShortReturnOracle private oracle;
    StableCoinReactor private reactor;
    GenericMockERC20 private base;
    address private user = makeAddr("user");

    function setUp() public {
        StableCoinFactory factory = new StableCoinFactory(makeAddr("dev"), 1e15);
        base = new GenericMockERC20();
        oracle = new ShortReturnOracle(PRICE);
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
                12e17,
                15e17,
                100e18,
                3e15,
                1e17,
                99999e13
            )
        );
        base.mint(user, 1000e18);
        vm.startPrank(user);
        base.approve(address(reactor), type(uint256).max);
        reactor.fission(100e18, user);
        vm.stopPrank();
        assertEq(reactor.lastSuccessfulBasePrice(), PRICE);
    }

    function _assertUsesCachedPrice() private {
        assertEq(reactor.getBasePriceInPeggedAsset(), PRICE, "view should fall back to the cached price");

        vm.startPrank(user);
        reactor.fission(10e18, user);
        reactor.transmuteProtonToNeutron(reactor.PROTON_TOKEN().balanceOf(user) / 10, 0, user);
        reactor.transmuteNeutronToProton(reactor.NEUTRON_TOKEN().balanceOf(user) / 10, 0, user);
        reactor.fusion(1e18, user);
        vm.stopPrank();

        assertEq(reactor.lastSuccessfulBasePrice(), PRICE);
    }

    function testEmptyReturnDataUsesCachedPrice() public {
        oracle.set(2100e18, 0);
        _assertUsesCachedPrice();
    }

    function testShortReturnDataUsesCachedPrice() public {
        oracle.set(2100e18, 31);
        _assertUsesCachedPrice();
    }

    /// A normal 32-byte answer is still read and cached.
    function testFullReturnDataIsStillReadAndCached() public {
        oracle.set(2100e18, 32);
        assertEq(reactor.getBasePriceInPeggedAsset(), 2100e18);
        vm.prank(user);
        reactor.fission(10e18, user);
        assertEq(reactor.lastSuccessfulBasePrice(), 2100e18);
    }
}
