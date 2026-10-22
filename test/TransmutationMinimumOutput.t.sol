// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockOracle} from "./GenericIOracleIntegration.t.sol";
import {MockDecimalERC20} from "./GluonIntegration.t.sol";

contract TransmutationMinimumOutputTest is Test {
    uint256 private constant WAD = 1e18;
    address private user = makeAddr("minimum output user");
    address private other = makeAddr("other trader");
    address private recipient = makeAddr("output recipient");
    address private dev = makeAddr("dev");
    MockDecimalERC20 private base;
    GenericMockOracle private oracle;
    StableCoinReactor private reactor;

    function setUp() public {
        _deploy(18);
    }

    function _deploy(uint8 decimals) private {
        base = new MockDecimalERC20("Base", "B", decimals);
        oracle = new GenericMockOracle(WAD);
        StableCoinFactory factory = new StableCoinFactory();
        uint256 deposit = 100 * 10 ** uint256(decimals);
        base.mint(address(this), deposit);
        base.approve(address(factory), deposit);
        reactor = StableCoinReactor(
            factory.deployReactor(
                "Minimum",
                "Base",
                "B",
                "Neutron",
                "N",
                address(base),
                address(oracle),
                "Proton",
                "P",
                dev,
                1e15,
                0,
                0,
                101e16,
                15e17,
                deposit,
                0,
                WAD,
                WAD
            )
        );
        _fund(user, deposit);
        _fund(other, deposit);
    }

    function _fund(address account, uint256 amount) private {
        base.mint(account, amount);
        vm.startPrank(account);
        base.approve(address(reactor), amount);
        reactor.fission(amount, account);
        vm.stopPrank();
    }

    function _trade(bool plus, uint256 amount, uint256 minimum, address account)
        private
        returns (uint256 output, uint256 fee)
    {
        vm.prank(account);
        return plus
            ? reactor.transmuteProtonToNeutron(amount, minimum, recipient)
            : reactor.transmuteNeutronToProton(amount, minimum, recipient);
    }

    function _quote(bool plus, uint256 amount) private returns (uint256 output) {
        uint256 snapshot = vm.snapshotState();
        (output,) = _trade(plus, amount, 0, user);
        assertTrue(vm.revertToState(snapshot));
    }

    function _balances() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                reactor.reserve(),
                base.balanceOf(dev),
                reactor.NEUTRON_TOKEN().balanceOf(user),
                reactor.PROTON_TOKEN().balanceOf(user),
                reactor.NEUTRON_TOKEN().balanceOf(recipient),
                reactor.PROTON_TOKEN().balanceOf(recipient),
                reactor.NEUTRON_TOKEN().totalSupply(),
                reactor.PROTON_TOKEN().totalSupply(),
                reactor.lastSuccessfulBasePrice()
            )
        );
    }

    function testFuzzMinimumBoundary(bool plus, uint96 amountRaw, bool sixDecimals) public {
        if (sixDecimals) _deploy(6);
        uint256 amount = bound(uint256(amountRaw), 1e12, 2e18);
        uint256 quoted = _quote(plus, amount);
        bytes32 beforeBalances = _balances();
        vm.expectRevert(StableCoinReactor.ExcessiveSlippage.selector);
        _trade(plus, amount, quoted + 1, user);
        assertEq(_balances(), beforeBalances);
        (uint256 output,) = _trade(plus, amount, quoted, user);
        assertEq(output, quoted);
        assertEq(
            plus ? reactor.NEUTRON_TOKEN().balanceOf(recipient) : reactor.PROTON_TOKEN().balanceOf(recipient), quoted
        );
    }

    function testProtonToNeutronRejectsWorseExecutionAfterAnotherTrade() public {
        _assertInterveningTrade(true);
    }

    function testNeutronToProtonRejectsWorseExecutionAfterAnotherTrade() public {
        _assertInterveningTrade(false);
    }

    function _assertInterveningTrade(bool plus) private {
        uint256 quoted = _quote(plus, WAD);
        _trade(plus, 20e18, 0, other);
        uint256 lowerQuote = _quote(plus, WAD);
        assertLt(lowerQuote, quoted);
        bytes32 beforeBalances = _balances();
        uint256 snapshot = vm.snapshotState();
        vm.expectRevert(StableCoinReactor.ExcessiveSlippage.selector);
        _trade(plus, WAD, quoted, user);
        assertEq(_balances(), beforeBalances);
        (uint256 output, uint256 fee) = _trade(plus, WAD, lowerQuote, user);
        assertEq(output, lowerQuote);
        assertTrue(vm.revertToState(snapshot));
        // A rejected trade must not change the fee ledger for the next trade.
        (uint256 cleanOutput, uint256 cleanFee) = _trade(plus, WAD, lowerQuote, user);
        assertEq(cleanOutput, output);
        assertEq(cleanFee, fee);
    }

    function testPositiveMinimumRejectsZeroOracleAndZeroMinimumPreservesNoOp() public {
        oracle.setValue(0);
        bytes32 beforeBalances = _balances();
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(StableCoinReactor.ExcessiveSlippage.selector);
            _trade(i == 0, WAD, 1, user);
            (uint256 output, uint256 fee) = _trade(i == 0, WAD, 0, user);
            assertEq(output, 0);
            assertEq(fee, 0);
            assertEq(_balances(), beforeBalances);
        }
    }

    function testPositiveMinimumRejectsZeroTranchePriceAndZeroMinimumPreservesNoOp() public {
        // Keep the ratio in range while Proton's price rounds to zero.
        vm.mockCall(
            address(reactor.PROTON_TOKEN()), abi.encodeWithSignature("totalSupply()"), abi.encode(type(uint256).max)
        );
        assertGt(reactor.reserveRatioPeggedAsset(), reactor.CRITICAL_RESERVE_RATIO());
        assertEq(reactor.protonPriceInBase(), 0);
        bytes32 beforeBalances = _balances();
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(StableCoinReactor.ExcessiveSlippage.selector);
            _trade(i == 0, WAD, 1, user);
            (uint256 output, uint256 fee) = _trade(i == 0, WAD, 0, user);
            assertEq(output, 0);
            assertEq(fee, 0);
            assertEq(_balances(), beforeBalances);
        }
    }
}
