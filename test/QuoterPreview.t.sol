// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockOracle} from "./GenericIOracleIntegration.t.sol";
import {MockDecimalERC20} from "./GluonIntegration.t.sol";

contract QuoterPreviewTest is Test {
    uint256 private constant WAD = 1e18;
    address private user = makeAddr("quote user");
    address private recipient = makeAddr("quote recipient");
    address private dev = makeAddr("dev receiver");

    MockDecimalERC20 private base;
    GenericMockOracle private oracle;
    StableCoinReactor private reactor;

    function setUp() public {
        _deploy(18);
    }

    function _deploy(uint8 decimals) private {
        base = new MockDecimalERC20("Base", "B", decimals);
        oracle = new GenericMockOracle(WAD);
        StableCoinFactory factory = new StableCoinFactory(dev, 1e15); // 0.1% dev fee
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
        (uint256 pNeutron, uint256 pProton, uint256 pFee, uint256 pDev) = reactor.previewFission(deposit);

        assertEq(qNeutron, pNeutron);
        assertEq(qProton, pProton);
        assertEq(qFee, pFee);
        assertEq(qDev, pDev);

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
        (uint256 pNeutronBurn, uint256 pProtonBurn, uint256 pNetOut, uint256 pFee, uint256 pDev) =
            reactor.previewFusion(grossWithdrawal);

        assertEq(qNeutronBurn, pNeutronBurn);
        assertEq(qProtonBurn, pProtonBurn);
        assertEq(qNetOut, pNetOut);
        assertEq(qFee, pFee);
        assertEq(qDev, pDev);

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
        (uint256 pNeutronOut, uint256 pFeeWad, uint256 pProtoFee, uint256 pDevFee) =
            reactor.previewTransmuteProtonToNeutron(protonIn);

        assertEq(qNeutronOut, pNeutronOut);
        assertEq(qFeeWad, pFeeWad);
        assertEq(qProtoFee, pProtoFee);
        assertEq(qDevFee, pDevFee);
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
        (uint256 pProtonOut, uint256 pFeeWad, uint256 pProtoFee, uint256 pDevFee) =
            reactor.previewTransmuteNeutronToProton(neutronIn);

        assertEq(qProtonOut, pProtonOut);
        assertEq(qFeeWad, pFeeWad);
        assertEq(qProtoFee, pProtoFee);
        assertEq(qDevFee, pDevFee);
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
}
