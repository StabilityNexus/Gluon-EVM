// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {NativeAssetHelper} from "../src/NativeAssetHelper.sol";
import {IWrappedNative} from "../src/interfaces/IWrappedNative.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";

contract MockWrappedNative is ERC20, IWrappedNative {
    constructor() ERC20("Wrapped Native", "WNATIVE") {}

    function deposit() external payable override {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "native transfer failed");
    }
}

contract MockOtherERC20 is ERC20 {
    constructor() ERC20("Other", "OTHER") {}
}

contract MockNativeOracle is IOracle {
    function readValue() external pure returns (uint256 value) {
        return 1e18;
    }

    function readValueInterval() external pure returns (uint256 minValue, uint256 maxValue) {
        return (1e18, 1e18);
    }

    function lastUpdated() external view returns (uint256 timestamp) {
        return block.timestamp;
    }

    function description() external pure returns (string memory) {
        return "WNATIVE / USD";
    }
}

contract WrongBaseReactor {
    IERC20 public immutable BASE_TOKEN;

    constructor(IERC20 baseToken) {
        BASE_TOKEN = baseToken;
    }
}

contract RevertingNativeReceiver {
    receive() external payable {
        revert("native rejected");
    }
}

contract NativeAssetHelperTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant INITIAL_RESERVE = 100 ether;

    MockWrappedNative internal wrapped;
    MockNativeOracle internal oracle;
    StableCoinFactory internal factory;
    StableCoinReactor internal reactor;
    NativeAssetHelper internal helper;

    address internal treasury = makeAddr("treasury");
    address internal user = makeAddr("user");

    function setUp() public {
        wrapped = new MockWrappedNative();
        oracle = new MockNativeOracle();
        factory = new StableCoinFactory();
        helper = new NativeAssetHelper(address(wrapped));

        vm.deal(address(this), 200 ether);

        wrapped.deposit{value: INITIAL_RESERVE}();
        wrapped.approve(address(factory), INITIAL_RESERVE);

        address reactorAddress = factory.deployReactor(
            "Native Gluon Vault",
            "Wrapped Native",
            "WNATIVE",
            "Gluon USD",
            "GUSD",
            address(wrapped),
            address(oracle),
            "Gluon Proton",
            "GPRO",
            treasury,
            0,
            1e16,
            WAD,
            INITIAL_RESERVE
        );

        reactor = StableCoinReactor(reactorAddress);

        vm.deal(user, 10 ether);
    }

    function _fissionOneNative() internal {
        vm.prank(user);
        helper.fissionNative{value: 1 ether}(address(reactor), user, 0, 0);
    }

    function testFissionNativeMintsDirectlyToUser() public {
        uint256 reserveBefore = reactor.reserve();

        vm.prank(user);
        (uint256 neutronOut, uint256 protonOut) = helper.fissionNative{value: 1 ether}(address(reactor), user, 0, 0);

        assertGt(neutronOut, 0);
        assertGt(protonOut, 0);

        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), neutronOut);

        assertEq(reactor.PROTON_TOKEN().balanceOf(user), protonOut);

        assertEq(reactor.reserve(), reserveBefore + 1 ether);

        assertEq(wrapped.balanceOf(address(helper)), 0);
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(address(helper)), 0);
        assertEq(reactor.PROTON_TOKEN().balanceOf(address(helper)), 0);
    }

    function testFissionNativeHonorsMinimumOutputs() public {
        vm.expectRevert(NativeAssetHelper.FissionOutputBelowMinimum.selector);

        vm.prank(user);
        helper.fissionNative{value: 1 ether}(address(reactor), user, type(uint256).max, 0);
    }

    function testFusionBurnAmountsMatchesActualFusion() public {
        _fissionOneNative();

        uint256 baseAmount = 0.25 ether;

        (uint256 quotedNeutron, uint256 quotedProton) = reactor.fusionBurnAmounts(baseAmount);

        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(user);

        uint256 protonBefore = reactor.PROTON_TOKEN().balanceOf(user);

        vm.prank(user);
        reactor.fusion(baseAmount, user);

        assertEq(neutronBefore - reactor.NEUTRON_TOKEN().balanceOf(user), quotedNeutron);

        assertEq(protonBefore - reactor.PROTON_TOKEN().balanceOf(user), quotedProton);
    }

    function testFusionBurnAmountsRejectsZero() public {
        vm.expectRevert(StableCoinReactor.AmountZero.selector);
        reactor.fusionBurnAmounts(0);
    }

    function testFusionNativeReturnsNativeToUser() public {
        _fissionOneNative();

        uint256 baseAmount = 0.25 ether;

        (uint256 neutronRequired, uint256 protonRequired) = reactor.fusionBurnAmounts(baseAmount);

        vm.startPrank(user);

        reactor.NEUTRON_TOKEN().approve(address(helper), neutronRequired);

        reactor.PROTON_TOKEN().approve(address(helper), protonRequired);

        uint256 nativeBefore = user.balance;

        (uint256 nativeOut, uint256 neutronIn, uint256 protonIn) =
            helper.fusionNative(address(reactor), baseAmount, user, neutronRequired, protonRequired, 0);

        vm.stopPrank();

        uint256 expectedFee = (baseAmount * reactor.FUSION_FEE()) / WAD;

        assertEq(nativeOut, baseAmount - expectedFee);

        assertEq(user.balance, nativeBefore + nativeOut);

        assertEq(neutronIn, neutronRequired);
        assertEq(protonIn, protonRequired);

        assertEq(wrapped.balanceOf(address(helper)), 0);
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(address(helper)), 0);
        assertEq(reactor.PROTON_TOKEN().balanceOf(address(helper)), 0);
    }

    function testFusionNativeWithoutAllowanceReverts() public {
        _fissionOneNative();

        uint256 baseAmount = 0.25 ether;

        (uint256 neutronRequired, uint256 protonRequired) = reactor.fusionBurnAmounts(baseAmount);

        vm.expectRevert();

        vm.prank(user);
        helper.fusionNative(address(reactor), baseAmount, user, neutronRequired, protonRequired, 0);
    }

    function testFusionNativeHonorsMaximumInputs() public {
        _fissionOneNative();

        uint256 baseAmount = 0.25 ether;

        (uint256 neutronRequired, uint256 protonRequired) = reactor.fusionBurnAmounts(baseAmount);

        vm.expectRevert(NativeAssetHelper.FusionInputAboveMaximum.selector);

        vm.prank(user);
        helper.fusionNative(address(reactor), baseAmount, user, neutronRequired - 1, protonRequired, 0);
    }

    function testFusionNativeHonorsMinimumNativeOutput() public {
        _fissionOneNative();

        uint256 baseAmount = 0.25 ether;

        (uint256 neutronRequired, uint256 protonRequired) = reactor.fusionBurnAmounts(baseAmount);

        vm.startPrank(user);

        reactor.NEUTRON_TOKEN().approve(address(helper), neutronRequired);

        reactor.PROTON_TOKEN().approve(address(helper), protonRequired);

        vm.expectRevert(NativeAssetHelper.NativeOutputBelowMinimum.selector);

        helper.fusionNative(address(reactor), baseAmount, user, neutronRequired, protonRequired, baseAmount);

        vm.stopPrank();
    }

    function testRejectsReactorWithDifferentBaseToken() public {
        MockOtherERC20 otherToken = new MockOtherERC20();
        WrongBaseReactor wrongReactor = new WrongBaseReactor(otherToken);

        vm.expectRevert(NativeAssetHelper.BaseTokenMismatch.selector);

        vm.prank(user);
        helper.fissionNative{value: 1 ether}(address(wrongReactor), user, 0, 0);
    }

    function testDirectNativeTransferIsRejected() public {
        vm.prank(user);

        (bool success,) = address(helper).call{value: 1 ether}("");

        assertFalse(success);
    }

    function testRejectsZeroRecipient() public {
        vm.expectRevert(NativeAssetHelper.InvalidRecipient.selector);

        vm.prank(user);
        helper.fissionNative{value: 1 ether}(address(reactor), address(0), 0, 0);
    }

    function testFissionClearsWrappedAllowance() public {
        _fissionOneNative();

        assertEq(
            wrapped.allowance(address(helper), address(reactor)), 0, "helper must not leave wrapped-token approval"
        );
    }

    function testFusionNativeWithPartialAllowanceReverts() public {
        _fissionOneNative();

        uint256 baseAmount = 0.25 ether;

        (uint256 neutronRequired, uint256 protonRequired) = reactor.fusionBurnAmounts(baseAmount);

        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(user);

        uint256 protonBefore = reactor.PROTON_TOKEN().balanceOf(user);

        vm.startPrank(user);

        reactor.NEUTRON_TOKEN().approve(address(helper), neutronRequired - 1);

        reactor.PROTON_TOKEN().approve(address(helper), protonRequired);

        vm.expectRevert();

        helper.fusionNative(address(reactor), baseAmount, user, neutronRequired, protonRequired, 0);

        vm.stopPrank();

        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), neutronBefore, "failed fusion must not consume neutron");

        assertEq(reactor.PROTON_TOKEN().balanceOf(user), protonBefore, "failed fusion must not consume proton");
    }

    function testFusionRevertsAtomicallyWhenRecipientRejectsNative() public {
        _fissionOneNative();

        RevertingNativeReceiver receiver = new RevertingNativeReceiver();

        uint256 baseAmount = 0.25 ether;

        (uint256 neutronRequired, uint256 protonRequired) = reactor.fusionBurnAmounts(baseAmount);

        uint256 neutronBefore = reactor.NEUTRON_TOKEN().balanceOf(user);

        uint256 protonBefore = reactor.PROTON_TOKEN().balanceOf(user);

        uint256 reserveBefore = reactor.reserve();

        vm.startPrank(user);

        reactor.NEUTRON_TOKEN().approve(address(helper), neutronRequired);

        reactor.PROTON_TOKEN().approve(address(helper), protonRequired);

        vm.expectRevert(NativeAssetHelper.NativeTransferFailed.selector);

        helper.fusionNative(address(reactor), baseAmount, address(receiver), neutronRequired, protonRequired, 0);

        vm.stopPrank();

        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), neutronBefore, "failed native payout must roll neutron back");

        assertEq(reactor.PROTON_TOKEN().balanceOf(user), protonBefore, "failed native payout must roll proton back");

        assertEq(reactor.reserve(), reserveBefore, "failed native payout must roll reserve back");

        assertEq(wrapped.balanceOf(address(helper)), 0, "helper must not retain wrapped asset");
    }
}
