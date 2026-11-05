// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockOracle} from "./GenericIOracleIntegration.t.sol";
import {MockDecimalERC20, MockFeeERC20} from "./GluonIntegration.t.sol";

contract QuoterPreviewTest is Test {
    uint256 private constant WAD = 1e18;
    address private user = makeAddr("quote user");
    address private recipient = makeAddr("quote recipient");
    address private dev = makeAddr("dev receiver");

    MockDecimalERC20 private base;
    GenericMockOracle private oracle;
    StableCoinFactory private factory;
    StableCoinReactor private reactor;

    function setUp() public {
        _deploy(18);
    }

    function _deploy(uint8 decimals) private {
        base = new MockDecimalERC20("Base", "B", decimals);
        oracle = new GenericMockOracle(WAD);
        factory = new StableCoinFactory(dev, 1e15); // 0.1% dev fee
        uint256 initialDeposit = 100 * 10 ** uint256(decimals);
        base.mint(address(this), initialDeposit);
        base.approve(address(factory), initialDeposit);

        reactor = StableCoinReactor(
            factory.deployReactor(
                "QuoterVault",
                "BaseAsset",
                "BA",
                "NeutronToken",
                "NT",
                address(base),
                address(oracle),
                "ProtonToken",
                "PT",
                1e16, // 1% fission fee
                1e16, // 1% fusion fee
                101e16, // critical reserve ratio: 1.01
                15e17, // initial reserve ratio: 1.5
                initialDeposit,
                5e15, // betaPhi0: 0.5%
                1e16, // betaPhi1: 1%
                99e16 // decayPerSecond: 99%
            )
        );

        // Fund user with base tokens
        uint256 userDeposit = 100 * 10 ** uint256(decimals);
        base.mint(user, userDeposit);
        vm.startPrank(user);
        base.approve(address(reactor), userDeposit);
        reactor.fission(userDeposit, user);
        vm.stopPrank();
    }

    function testQuoteFissionMatchesActualExecution() public {
        uint256 deposit = 10e18;
        base.mint(user, deposit);

        (uint256 qNeutron, uint256 qProton, uint256 qFee, uint256 qDev) = reactor.quoteFission(deposit);

        uint256 userNeutronBefore = reactor.NEUTRON_TOKEN().balanceOf(recipient);
        uint256 userProtonBefore = reactor.PROTON_TOKEN().balanceOf(recipient);
        uint256 devBalanceBefore = base.balanceOf(dev);

        vm.startPrank(user);
        base.approve(address(reactor), deposit);
        reactor.fission(deposit, recipient);
        vm.stopPrank();

        uint256 actualNeutron = reactor.NEUTRON_TOKEN().balanceOf(recipient) - userNeutronBefore;
        uint256 actualProton = reactor.PROTON_TOKEN().balanceOf(recipient) - userProtonBefore;
        uint256 actualDevFee = base.balanceOf(dev) - devBalanceBefore;

        assertEq(actualNeutron, qNeutron, "Fission neutron output mismatch");
        assertEq(actualProton, qProton, "Fission proton output mismatch");
        assertEq(actualDevFee, qDev, "Fission dev fee mismatch");
    }

    function testQuoteFusionMatchesActualExecution() public {
        uint256 grossWithdrawal = 5e18;

        (uint256 qNeutronBurn, uint256 qProtonBurn, uint256 qNetOut, uint256 qFee, uint256 qDev) =
            reactor.quoteFusion(grossWithdrawal);

        uint256 userBaseBefore = base.balanceOf(recipient);
        uint256 userNeutronBefore = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 userProtonBefore = reactor.PROTON_TOKEN().balanceOf(user);
        uint256 devBalanceBefore = base.balanceOf(dev);

        vm.prank(user);
        reactor.fusion(grossWithdrawal, recipient);

        uint256 actualNeutronBurn = userNeutronBefore - reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 actualProtonBurn = userProtonBefore - reactor.PROTON_TOKEN().balanceOf(user);
        uint256 actualNetOut = base.balanceOf(recipient) - userBaseBefore;
        uint256 actualDevFee = base.balanceOf(dev) - devBalanceBefore;

        assertEq(actualNeutronBurn, qNeutronBurn, "Fusion neutron burn mismatch");
        assertEq(actualProtonBurn, qProtonBurn, "Fusion proton burn mismatch");
        assertEq(actualNetOut, qNetOut, "Fusion net base out mismatch");
        assertEq(actualDevFee, qDev, "Fusion dev fee mismatch");
    }

    function testQuoteTransmuteProtonToNeutronMatchesActualExecution() public {
        uint256 protonIn = 2e18;

        (uint256 qNeutronOut, uint256 qFeeWad, uint256 qProtoFee, uint256 qDevFee) =
            reactor.quoteTransmuteProtonToNeutron(protonIn);

        assertGt(qNeutronOut, 0);

        uint256 recipientNeutronBefore = reactor.NEUTRON_TOKEN().balanceOf(recipient);
        uint256 devBalanceBefore = base.balanceOf(dev);

        // Prove that passing exact quoted output as minNeutronOut succeeds with 0 discrepancy
        vm.prank(user);
        (uint256 actualNeutronOut, uint256 actualFeeWad) =
            reactor.transmuteProtonToNeutron(protonIn, qNeutronOut, recipient);

        assertEq(actualNeutronOut, qNeutronOut, "Transmute+ output mismatch");
        assertEq(actualFeeWad, qFeeWad, "Transmute+ feeWad mismatch");
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(recipient) - recipientNeutronBefore, qNeutronOut);
        assertEq(base.balanceOf(dev) - devBalanceBefore, qDevFee);
    }

    function testQuoteTransmuteNeutronToProtonMatchesActualExecution() public {
        uint256 neutronIn = 2e18;

        (uint256 qProtonOut, uint256 qFeeWad, uint256 qProtoFee, uint256 qDevFee) =
            reactor.quoteTransmuteNeutronToProton(neutronIn);

        assertGt(qProtonOut, 0);

        uint256 recipientProtonBefore = reactor.PROTON_TOKEN().balanceOf(recipient);
        uint256 devBalanceBefore = base.balanceOf(dev);

        // Prove that passing exact quoted output as minProtonOut succeeds with 0 discrepancy
        vm.prank(user);
        (uint256 actualProtonOut, uint256 actualFeeWad) =
            reactor.transmuteNeutronToProton(neutronIn, qProtonOut, recipient);

        assertEq(actualProtonOut, qProtonOut, "Transmute- output mismatch");
        assertEq(actualFeeWad, qFeeWad, "Transmute- feeWad mismatch");
        assertEq(reactor.PROTON_TOKEN().balanceOf(recipient) - recipientProtonBefore, qProtonOut);
        assertEq(base.balanceOf(dev) - devBalanceBefore, qDevFee);
    }

    function testDynamicBetaDecayQuotingMatchesExecutionAcrossTime() public {
        // Perform an initial trade to build up volume in the ledger
        vm.prank(user);
        reactor.transmuteProtonToNeutron(5e18, 0, user);

        // Warp time forward by 100 seconds to let the ledger decay
        vm.warp(block.timestamp + 100);

        uint256 testTradeAmount = 2e18;
        // View quote computes decay dynamically as of the new timestamp
        (uint256 quotedNeutron, uint256 quotedFeeWad,,) = reactor.quoteTransmuteProtonToNeutron(testTradeAmount);

        // Execute trade in transaction
        vm.prank(user);
        (uint256 actualNeutron, uint256 actualFeeWad) =
            reactor.transmuteProtonToNeutron(testTradeAmount, quotedNeutron, recipient);

        assertEq(actualNeutron, quotedNeutron, "Decayed quote mismatch");
        assertEq(actualFeeWad, quotedFeeWad, "Decayed feeWad mismatch");
    }

    function testQuotingWithOneAboveRevertsOnSlippage() public {
        uint256 protonIn = 1e18;
        (uint256 quotedNeutron,,,) = reactor.quoteTransmuteProtonToNeutron(protonIn);

        vm.prank(user);
        vm.expectRevert(StableCoinReactor.ExcessiveSlippage.selector);
        reactor.transmuteProtonToNeutron(protonIn, quotedNeutron + 1, recipient);

        uint256 neutronIn = 1e18;
        (uint256 quotedProton,,,) = reactor.quoteTransmuteNeutronToProton(neutronIn);

        vm.prank(user);
        vm.expectRevert(StableCoinReactor.ExcessiveSlippage.selector);
        reactor.transmuteNeutronToProton(neutronIn, quotedProton + 1, recipient);
    }

    function testQuoteRevertsOnZeroAmount() public {
        vm.expectRevert(StableCoinReactor.AmountZero.selector);
        reactor.quoteFission(0);

        vm.expectRevert(StableCoinReactor.AmountZero.selector);
        reactor.quoteFusion(0);

        vm.expectRevert(StableCoinReactor.AmountZero.selector);
        reactor.quoteTransmuteProtonToNeutron(0);

        vm.expectRevert(StableCoinReactor.AmountZero.selector);
        reactor.quoteTransmuteNeutronToProton(0);
    }

    function testQuoteTransmuteRevertsWhenResultingReserveRatioBelowCritical() public {
        // Huge protonIn would mint too many neutrons and breach critical ratio
        uint256 hugeProton = 500e18;
        vm.expectRevert(StableCoinReactor.ResultingReserveRatioBelowCritical.selector);
        reactor.quoteTransmuteProtonToNeutron(hugeProton);
    }

    function testDecayedVolumesViewFunction() public {
        (uint256 plusBefore, uint256 minusBefore) = reactor.decayedVolumes();
        assertEq(plusBefore, 0);
        assertEq(minusBefore, 0);

        vm.prank(user);
        reactor.transmuteProtonToNeutron(3e18, 0, user);

        (uint256 plusAfter, uint256 minusAfter) = reactor.decayedVolumes();
        assertGt(plusAfter, 0);
        assertEq(minusAfter, 0);

        // Warping time decays volumes in view without sending transactions
        vm.warp(block.timestamp + 50);
        (uint256 decayedPlus, uint256 decayedMinus) = reactor.decayedVolumes();
        assertLt(decayedPlus, plusAfter);
        assertEq(decayedMinus, 0);
    }

    function testFissionQuoteWhenReceivedAmountDiffersFromInput() public {
        MockFeeERC20 feeToken = new MockFeeERC20("Fee Base", "FB");
        uint256 requestedInitial = 100e18;
        feeToken.mint(address(this), requestedInitial);
        feeToken.approve(address(factory), requestedInitial);

        StableCoinReactor feeReactor = StableCoinReactor(
            factory.deployReactor(
                "FeeVault",
                "Fee Base",
                "FB",
                "Fee Neutron",
                "FNT",
                address(feeToken),
                address(oracle),
                "Fee Proton",
                "FPT",
                1e16, // 1% fission fee
                1e16, // 1% fusion fee
                101e16,
                15e17,
                requestedInitial,
                5e15,
                1e16,
                99e16
            )
        );

        address testUser = makeAddr("feeUser");
        uint256 inputAmount = 50e18;
        feeToken.mint(testUser, inputAmount);

        // MockFeeERC20 charges a 10% transfer tax on transfers between non-zero addresses.
        // Therefore, when depositing 50e18, the reactor receives exactly 45e18.
        uint256 receivedAmount = 45e18;

        // Quoting with the actual received amount accurately predicts the execution results
        (uint256 qNeutron, uint256 qProton, uint256 qFee, uint256 qDev) = feeReactor.quoteFission(receivedAmount);

        // Quoting with the raw inputAmount would overestimate outputs because the token has a transfer tax
        (uint256 naiveNeutron, uint256 naiveProton,,) = feeReactor.quoteFission(inputAmount);
        assertGt(naiveNeutron, qNeutron);
        assertGt(naiveProton, qProton);

        // Execute fission with inputAmount
        uint256 devBalBefore = feeToken.balanceOf(dev);
        vm.startPrank(testUser);
        feeToken.approve(address(feeReactor), inputAmount);
        feeReactor.fission(inputAmount, recipient);
        vm.stopPrank();

        // Execution output matches quoteFission(receivedAmount) with 0 discrepancy
        assertEq(feeReactor.NEUTRON_TOKEN().balanceOf(recipient), qNeutron, "Fee token fission neutron mismatch");
        assertEq(feeReactor.PROTON_TOKEN().balanceOf(recipient), qProton, "Fee token fission proton mismatch");
        // qDev is the fee amount transferred by the reactor; MockFeeERC20 burns 10% on transfer
        assertEq(feeToken.balanceOf(dev) - devBalBefore, qDev - (qDev / 10), "Fee token dev fee mismatch");
    }

    function testBetaPlusCalculationsAccountForDevFeeTransfer() public {
        address devReceiver = makeAddr("highDevReceiver");
        StableCoinFactory highDevFactory = new StableCoinFactory(devReceiver, 1e17); // 10% dev fee
        MockDecimalERC20 testBase = new MockDecimalERC20("TBase", "TB", 18);
        uint256 initDeposit = 100e18;
        testBase.mint(address(this), initDeposit);
        testBase.approve(address(highDevFactory), initDeposit);

        StableCoinReactor highDevReactor = StableCoinReactor(
            highDevFactory.deployReactor(
                "HighDevVault",
                "TBase",
                "TB",
                "TNeutron",
                "TN",
                address(testBase),
                address(oracle),
                "TProton",
                "TP",
                0,
                0,
                121e16, // critical reserve ratio: 1.21
                150e16, // initial reserve ratio: 1.50
                initDeposit,
                0,
                0,
                WAD
            )
        );

        address trader = makeAddr("trader");
        uint256 traderDeposit = 100e18;
        testBase.mint(trader, traderDeposit);
        vm.startPrank(trader);
        testBase.approve(address(highDevReactor), traderDeposit);
        highDevReactor.fission(traderDeposit, trader);
        vm.stopPrank();

        uint256 protonBalance = highDevReactor.PROTON_TOKEN().balanceOf(trader);

        // Verify that quoting matches execution when dev fee is transferred out
        uint256 tradeAmount = 10e18;
        (uint256 quotedNeutron, uint256 quotedFeeWad, uint256 quotedProtoFee, uint256 quotedDevFee) =
            highDevReactor.quoteTransmuteProtonToNeutron(tradeAmount);

        assertGt(quotedDevFee, 0, "dev fee should be positive");

        uint256 devBalBefore = testBase.balanceOf(devReceiver);
        vm.prank(trader);
        (uint256 actualNeutron, uint256 actualFeeWad) =
            highDevReactor.transmuteProtonToNeutron(tradeAmount, quotedNeutron, recipient);

        assertEq(actualNeutron, quotedNeutron, "Neutron output mismatch with dev fee");
        assertEq(actualFeeWad, quotedFeeWad, "FeeWad mismatch with dev fee");
        assertEq(testBase.balanceOf(devReceiver) - devBalBefore, quotedDevFee, "Dev fee transferred mismatch");

        // Verify that both quote and execution properly revert when dev fee transfer pushes reserve below critical
        uint256 excessiveProton = protonBalance;
        vm.expectRevert(StableCoinReactor.ResultingReserveRatioBelowCritical.selector);
        highDevReactor.quoteTransmuteProtonToNeutron(excessiveProton);

        vm.prank(trader);
        vm.expectRevert(StableCoinReactor.ResultingReserveRatioBelowCritical.selector);
        highDevReactor.transmuteProtonToNeutron(excessiveProton, 0, recipient);
    }
}
