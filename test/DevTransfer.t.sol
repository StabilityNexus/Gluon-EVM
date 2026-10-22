// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockERC20, GenericMockOracle} from "./GenericIOracleIntegration.t.sol";

contract DevReceiver {
    function accept(StableCoinReactor reactor) external {
        reactor.acceptDev();
    }

    function propose(StableCoinReactor reactor, address nextDev) external {
        reactor.proposeDev(nextDev);
    }
}

contract DevTransferTest is Test {
    address private constant INITIAL_DEV = 0x86B8f920835015c0F1b697dBe0B8b150a986eCE5;
    uint256 private constant WAD = 1e18;
    uint256 private constant FISSION_FEE = 2e16;
    uint256 private constant FUSION_FEE = 3e16;
    StableCoinFactory private factory;
    StableCoinReactor private reactor;
    GenericMockERC20 private base;
    GenericMockOracle private oracle;
    address private nextDev = makeAddr("next dev");
    address private user = makeAddr("user");

    event DevTransferProposed(address indexed previousDev, address indexed proposedDev);
    event DevTransferred(address indexed previousDev, address indexed newDev);
    event DevFeeReceiverChanged(address indexed previousReceiver, address indexed newReceiver);

    function setUp() public {
        factory = new StableCoinFactory();
        base = new GenericMockERC20();
        oracle = new GenericMockOracle(WAD);
        reactor = _deploy(INITIAL_DEV);
    }

    function _deploy(address initialDev) private returns (StableCoinReactor) {
        base.mint(address(this), 100e18);
        base.approve(address(factory), 100e18);
        return _create(initialDev);
    }

    function _create(address initialDev) private returns (StableCoinReactor) {
        return StableCoinReactor(
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
                initialDev,
                1e15,
                FISSION_FEE,
                FUSION_FEE,
                101e16,
                15e17,
                100e18,
                1e16,
                5e17,
                999e15
            )
        );
    }

    function _propose() private {
        vm.prank(INITIAL_DEV);
        reactor.proposeDev(nextDev);
    }

    function _transfer() private {
        _propose();
        vm.prank(nextDev);
        reactor.acceptDev();
    }

    function testConstructorSetsDevAndFixedFeeRates() public view {
        assertEq(reactor.dev(), INITIAL_DEV);
        assertEq(reactor.pendingDev(), address(0));
        assertEq(reactor.FISSION_FEE(), FISSION_FEE);
        assertEq(reactor.FUSION_FEE(), FUSION_FEE);
        assertEq(base.balanceOf(INITIAL_DEV), 1e17, "only the separate dev fee is transferred");
    }

    function testFactoryRejectsZeroDev() public {
        vm.expectRevert(StableCoinFactory.InvalidDev.selector);
        _create(address(0));
        assertEq(factory.getDeployedReactorsCount(), 1);
    }

    function testConstructorRejectsZeroDev() public {
        vm.expectRevert(StableCoinReactor.InvalidDev.selector);
        new StableCoinReactor(
            "Vault",
            "Base",
            "B",
            "Neutron",
            "N",
            address(base),
            address(oracle),
            "Proton",
            "P",
            address(0),
            1e15,
            FISSION_FEE,
            FUSION_FEE,
            101e16,
            0,
            0,
            WAD
        );
    }

    function testProposalEmitsEventAndKeepsCurrentDev() public {
        vm.expectEmit(true, true, false, true, address(reactor));
        emit DevTransferProposed(INITIAL_DEV, nextDev);
        _propose();
        assertEq(reactor.dev(), INITIAL_DEV);
        assertEq(reactor.pendingDev(), nextDev);
    }

    function testFuzzOnlyCurrentDevCanPropose(address caller) public {
        vm.assume(caller != INITIAL_DEV);
        vm.prank(caller);
        vm.expectRevert(StableCoinReactor.OnlyDev.selector);
        reactor.proposeDev(nextDev);
        assertEq(reactor.dev(), INITIAL_DEV);
        assertEq(reactor.pendingDev(), address(0));
    }

    function testZeroProposalRevertsWithoutClearingExistingProposal() public {
        _propose();
        vm.prank(INITIAL_DEV);
        vm.expectRevert(StableCoinReactor.InvalidDev.selector);
        reactor.proposeDev(address(0));
        assertEq(reactor.pendingDev(), nextDev);
        assertEq(reactor.dev(), INITIAL_DEV);
    }

    function testCannotAcceptWithoutAProposal() public {
        vm.prank(nextDev);
        vm.expectRevert(StableCoinReactor.OnlyPendingDev.selector);
        reactor.acceptDev();
        assertEq(reactor.dev(), INITIAL_DEV);
    }

    function testPendingDevCannotProposeBeforeAccepting() public {
        _propose();
        vm.prank(nextDev);
        vm.expectRevert(StableCoinReactor.OnlyDev.selector);
        reactor.proposeDev(user);
        assertEq(reactor.pendingDev(), nextDev);
    }

    function testCurrentDevCannotAcceptOnBehalfOfNominee() public {
        _propose();
        vm.prank(INITIAL_DEV);
        vm.expectRevert(StableCoinReactor.OnlyPendingDev.selector);
        reactor.acceptDev();
        assertEq(reactor.dev(), INITIAL_DEV);
    }

    function testFuzzOnlyPendingDevCanAccept(address caller) public {
        vm.assume(caller != nextDev);
        _propose();
        vm.prank(caller);
        vm.expectRevert(StableCoinReactor.OnlyPendingDev.selector);
        reactor.acceptDev();
        assertEq(reactor.dev(), INITIAL_DEV);
        assertEq(reactor.pendingDev(), nextDev);
    }

    function testAcceptanceEmitsEventAndClearsProposal() public {
        _propose();
        vm.expectEmit(true, true, false, true, address(reactor));
        emit DevTransferred(INITIAL_DEV, nextDev);
        vm.prank(nextDev);
        reactor.acceptDev();
        assertEq(reactor.dev(), nextDev);
        assertEq(reactor.pendingDev(), address(0));
    }

    function testFuzzTransferCompletesOnlyAfterAcceptance(address proposedDev) public {
        vm.assume(proposedDev != address(0));
        vm.prank(INITIAL_DEV);
        reactor.proposeDev(proposedDev);
        assertEq(reactor.dev(), INITIAL_DEV);
        assertEq(reactor.pendingDev(), proposedDev);
        vm.prank(proposedDev);
        reactor.acceptDev();
        assertEq(reactor.dev(), proposedDev);
        assertEq(reactor.pendingDev(), address(0));
    }

    function testReplacingProposalInvalidatesPreviousNominee() public {
        _propose();
        vm.prank(INITIAL_DEV);
        reactor.proposeDev(user);
        vm.prank(nextDev);
        vm.expectRevert(StableCoinReactor.OnlyPendingDev.selector);
        reactor.acceptDev();
        vm.prank(user);
        reactor.acceptDev();
        assertEq(reactor.dev(), user);
        assertEq(reactor.pendingDev(), address(0));
    }

    function testAcceptedProposalCannotBeReused() public {
        _transfer();
        vm.prank(nextDev);
        vm.expectRevert(StableCoinReactor.OnlyPendingDev.selector);
        reactor.acceptDev();
        assertEq(reactor.dev(), nextDev);
    }

    function testOnlyNewDevCanProposeAfterTransfer() public {
        _transfer();
        vm.prank(INITIAL_DEV);
        vm.expectRevert(StableCoinReactor.OnlyDev.selector);
        reactor.proposeDev(user);
        vm.prank(nextDev);
        reactor.proposeDev(user);
        assertEq(reactor.pendingDev(), user);
    }

    function _exerciseFees(address recipient) private {
        uint256 recipientBefore = base.balanceOf(recipient);
        uint256 userBefore = base.balanceOf(user);
        base.mint(user, 20e18);
        vm.startPrank(user);
        base.approve(address(reactor), 20e18);
        reactor.fission(20e18, user);
        assertEq(base.balanceOf(recipient), recipientBefore + 2e16, "wrong fission fee recipient");
        reactor.fusion(10e18, user);
        vm.stopPrank();
        assertEq(base.balanceOf(recipient), recipientBefore + 3e16, "wrong fusion fee recipient");
        assertEq(base.balanceOf(user), userBefore + 969e16, "fusion output changed");
    }

    function testFeesContinueToCurrentDevWhileProposalIsPending() public {
        _propose();
        _exerciseFees(INITIAL_DEV);
        assertEq(base.balanceOf(nextDev), 0);
        assertEq(reactor.pendingDev(), nextDev);
    }

    function testNewDevCanChangeReceiverAfterAcceptance() public {
        _propose();
        _exerciseFees(INITIAL_DEV);
        uint256 oldDevBalance = base.balanceOf(INITIAL_DEV);
        vm.prank(nextDev);
        reactor.acceptDev();
        assertEq(reactor.devFeeReceiver(), INITIAL_DEV, "authority transfer must not change the recipient");
        _exerciseFees(INITIAL_DEV);
        vm.prank(nextDev);
        reactor.setDevFeeReceiver(nextDev);
        oldDevBalance = base.balanceOf(INITIAL_DEV);
        _exerciseFees(nextDev);
        assertEq(base.balanceOf(INITIAL_DEV), oldDevBalance, "old recipient must stop receiving fees");
    }

    function testTransferPreservesReserveSupplyAndImmutableParameters() public {
        uint256 reserveBefore = reactor.reserve();
        uint256 neutronSupply = reactor.NEUTRON_TOKEN().totalSupply();
        uint256 protonSupply = reactor.PROTON_TOKEN().totalSupply();
        _transfer();
        assertEq(reactor.reserve(), reserveBefore);
        assertEq(reactor.NEUTRON_TOKEN().totalSupply(), neutronSupply);
        assertEq(reactor.PROTON_TOKEN().totalSupply(), protonSupply);
        assertEq(reactor.FISSION_FEE(), FISSION_FEE);
        assertEq(reactor.FUSION_FEE(), FUSION_FEE);
        assertEq(reactor.betaPhi0(), 1e16);
        assertEq(reactor.betaPhi1(), 5e17);
        assertEq(reactor.decayPerSecondWad(), 999e15);
        assertEq(reactor.devFeeReceiver(), INITIAL_DEV);
        assertEq(reactor.devFee(), 1e15);
        assertEq(reactor.FACTORY(), address(factory));
        assertEq(address(reactor.ORACLE()), address(oracle));
    }

    function testOnlyCurrentDevCanUpdateReceiver() public {
        _propose();
        vm.prank(nextDev);
        vm.expectRevert(StableCoinReactor.OnlyDev.selector);
        reactor.setDevFeeReceiver(user);
        vm.expectEmit(true, true, false, true, address(reactor));
        emit DevFeeReceiverChanged(INITIAL_DEV, user);
        vm.prank(INITIAL_DEV);
        reactor.setDevFeeReceiver(user);
        assertEq(reactor.devFeeReceiver(), user);
        assertEq(reactor.dev(), INITIAL_DEV);
        assertEq(reactor.pendingDev(), nextDev);
        vm.prank(nextDev);
        reactor.acceptDev();
        vm.prank(INITIAL_DEV);
        vm.expectRevert(StableCoinReactor.OnlyDev.selector);
        reactor.setDevFeeReceiver(INITIAL_DEV);
    }

    function testReceiverCannotBeZero() public {
        vm.prank(INITIAL_DEV);
        vm.expectRevert(StableCoinReactor.InvalidDevFeeReceiver.selector);
        reactor.setDevFeeReceiver(address(0));
        assertEq(reactor.devFeeReceiver(), INITIAL_DEV);
    }

    function testContractAddressCanAcceptAndPropose() public {
        DevReceiver receiver = new DevReceiver();
        vm.prank(INITIAL_DEV);
        reactor.proposeDev(address(receiver));
        receiver.accept(reactor);
        assertEq(reactor.dev(), address(receiver));
        receiver.propose(reactor, nextDev);
        vm.prank(nextDev);
        reactor.acceptDev();
        assertEq(reactor.dev(), nextDev);
    }
}
