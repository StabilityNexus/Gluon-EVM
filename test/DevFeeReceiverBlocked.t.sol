// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockOracle} from "./GenericIOracleIntegration.t.sol";

// Reserve token whose issuer can block an address, like the USDC and USDT blacklists.
contract BlockableERC20 is ERC20 {
    error Blocked();

    mapping(address => bool) public blocked;

    constructor() ERC20("Blockable", "BLK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[from] || blocked[to]) revert Blocked();
        super._update(from, to, value);
    }
}

contract DevFeeReceiverBlockedTest is Test {
    address private dev = makeAddr("dev");
    address private user = makeAddr("user");
    BlockableERC20 private base;
    StableCoinReactor private reactor;
    uint256 private devAtStart;

    function setUp() public {
        base = new BlockableERC20();
        GenericMockOracle oracle = new GenericMockOracle(2e18);
        StableCoinFactory factory = new StableCoinFactory(dev, 1e15);
        base.mint(address(this), 100e18);
        base.approve(address(factory), 100e18);
        reactor = StableCoinReactor(
            factory.deployReactor(
                "V",
                "Base",
                "B",
                "Peg",
                "P",
                address(base),
                address(oracle),
                "Proton",
                "PRO",
                3e15,
                3e15,
                12e17,
                15e17,
                100e18,
                1e15,
                0,
                1e18
            )
        );

        base.mint(user, 20e18);
        vm.startPrank(user);
        base.approve(address(reactor), type(uint256).max);
        reactor.fission(10e18, user);
        vm.stopPrank();

        // The issuer blocks the dev fee receiver, which is the dev address by default.
        base.setBlocked(dev, true);
        devAtStart = base.balanceOf(dev);
    }

    function testFusionStillPaysUserWhenReceiverIsBlocked() public {
        uint256 reserveBefore = reactor.reserve();
        uint256 userBefore = base.balanceOf(user);

        vm.recordLogs();
        vm.prank(user);
        reactor.fusion(1e18, user);

        uint256 paid = base.balanceOf(user) - userBefore;
        assertEq(paid, 1e18 * (1e18 - 3e15 - 1e15) / 1e18);
        // The dev fee stays in the reserve with the fusion fee.
        assertEq(reserveBefore - reactor.reserve(), paid);
        assertEq(base.balanceOf(dev), devAtStart);
        assertEq(_lastDevFeeAmount(StableCoinReactor.Fusion.selector), 0);
    }

    function testFissionStillMintsWhenReceiverIsBlocked() public {
        uint256 reserveBefore = reactor.reserve();
        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(user);

        vm.recordLogs();
        vm.prank(user);
        reactor.fission(1e18, user);

        assertGt(reactor.NEUTRON_TOKEN().balanceOf(user), neutronBefore);
        assertEq(reactor.reserve() - reserveBefore, 1e18);
        assertEq(base.balanceOf(dev), devAtStart);
        assertEq(_lastDevFeeAmount(StableCoinReactor.Fission.selector), 0);
    }

    function testTransmutationsStillRunWhenReceiverIsBlocked() public {
        uint256 reserveBefore = reactor.reserve();
        uint256 protons = reactor.PROTON_TOKEN().balanceOf(user);

        vm.recordLogs();
        vm.prank(user);
        (uint256 neutronOut,) = reactor.transmuteProtonToNeutron(protons / 10, 0, user);
        assertGt(neutronOut, 0);
        assertEq(_lastDevFeeAmount(StableCoinReactor.TransmutePlus.selector), 0);

        vm.recordLogs();
        vm.prank(user);
        (uint256 protonOut,) = reactor.transmuteNeutronToProton(neutronOut, 0, user);
        assertGt(protonOut, 0);
        assertEq(_lastDevFeeAmount(StableCoinReactor.TransmuteMinus.selector), 0);

        assertEq(reactor.reserve(), reserveBefore);
        assertEq(base.balanceOf(dev), devAtStart);
    }

    function testDevFeeIsPaidAgainOnceReceiverWorks() public {
        base.setBlocked(dev, false);
        uint256 devBefore = base.balanceOf(dev);

        vm.recordLogs();
        vm.prank(user);
        reactor.fusion(1e18, user);

        assertEq(base.balanceOf(dev) - devBefore, 1e15);
        assertEq(_lastDevFeeAmount(StableCoinReactor.Fusion.selector), 1e15);
    }

    // Same boundary as DevFeeAccounting.t.sol::testBetaPlusRangeCheckIncludesDevPaymentAndRollsBackOnFailure:
    // the trade keeps the ratio at or above critical only if the dev fee stays in the reserve. With the
    // receiver blocked the fee stays, so the trade must succeed.
    function testBlockedFeeStaysForBetaPlusCriticalCheck() public {
        BlockableERC20 token = new BlockableERC20();
        GenericMockOracle oracle = new GenericMockOracle(1e18);
        StableCoinFactory factory = new StableCoinFactory(dev, 1e15);
        token.mint(address(this), 100e18);
        token.approve(address(factory), 100e18);
        StableCoinReactor boundary = StableCoinReactor(
            factory.deployReactor(
                "V",
                "Base",
                "B",
                "Peg",
                "P",
                address(token),
                address(oracle),
                "Proton",
                "PRO",
                0,
                0,
                12e17,
                15e17,
                100e18,
                0,
                0,
                1e18
            )
        );
        token.mint(user, 200e18);
        vm.startPrank(user);
        token.approve(address(boundary), 200e18);
        boundary.fission(200e18, user);
        vm.stopPrank();

        uint256 r = boundary.reserve();
        uint256 n = boundary.NEUTRON_TOKEN().totalSupply();
        uint256 maxOutput = Math.mulDiv(r, 1e18, boundary.CRITICAL_RESERVE_RATIO()) - n - 1000;
        uint256 grossTarget = Math.mulDiv(maxOutput, 1e18, 1e18 - 1e15, Math.Rounding.Ceil);
        uint256 input = Math.mulDiv(grossTarget, 1e18, boundary.protonPriceInBase(), Math.Rounding.Ceil);
        uint256 gross = Math.mulDiv(input, boundary.protonPriceInBase(), 1e18);
        uint256 d = Math.mulDiv(gross, 1e15, 1e18);
        uint256 output = Math.mulDiv(gross - d, 1e18, boundary.neutronPriceInBase());
        assertGe(Math.mulDiv(r, 1e18, n + output), boundary.CRITICAL_RESERVE_RATIO());
        assertLt(Math.mulDiv(r - d, 1e18, n + output), boundary.CRITICAL_RESERVE_RATIO());

        token.setBlocked(dev, true);
        uint256 devBefore = token.balanceOf(dev);
        vm.recordLogs();
        vm.prank(user);
        (uint256 neutronOut,) = boundary.transmuteProtonToNeutron(input, 0, user);

        // The reactor prices minted Neutrons with the rounded-up price, so it can mint 1 wei less.
        assertLe(neutronOut, output);
        assertGe(neutronOut + 1, output);
        assertEq(boundary.reserve(), r);
        assertEq(token.balanceOf(dev), devBefore);
        assertGe(boundary.reserveRatioPeggedAsset(), boundary.CRITICAL_RESERVE_RATIO());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 reported = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(boundary) || logs[i].topics[0] != StableCoinReactor.TransmutePlus.selector) {
                continue;
            }
            bytes memory data = logs[i].data;
            assembly ("memory-safe") {
                reported := mload(add(data, mload(data)))
            }
        }
        assertEq(reported, 0);
    }

    // The dev fee amount is the last field of every operation event.
    function _lastDevFeeAmount(bytes32 topic) private returns (uint256 amount) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(reactor) || logs[i].topics[0] != topic) continue;
            bytes memory data = logs[i].data;
            assembly ("memory-safe") {
                amount := mload(add(data, mload(data)))
            }
            found = true;
        }
        assertTrue(found);
    }
}
