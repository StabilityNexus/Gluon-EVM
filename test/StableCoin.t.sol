// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {IPyth, Price} from "../src/interfaces/IPyth.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";


// Mocks


/// @dev Minimal Pyth mock.  getUpdateFee always returns ORACLE_FEE (0.001 ether).
contract MockPyth is IPyth {
    uint256 public constant ORACLE_FEE = 0.001 ether;

    // price = 1e8 with expo -8  =>  _pythPriceToWad returns 1e18 (price == 1 USD)
    int64 public mockPrice = 1e8;
    int32 public mockExpo = -8;

    function setPrice(int64 p, int32 e) external {
        mockPrice = p;
        mockExpo = e;
    }

    function getValidTimePeriod() external pure returns (uint) {
        return 60;
    }

    function _p() internal view returns (Price memory) {
        return Price(mockPrice, 0, mockExpo, block.timestamp);
    }

    function getPrice(bytes32) external view returns (Price memory) {
        return _p();
    }
    function getEmaPrice(bytes32) external view returns (Price memory) {
        return _p();
    }
    function getPriceUnsafe(bytes32) external view returns (Price memory) {
        return _p();
    }
    function getPriceNoOlderThan(
        bytes32,
        uint
    ) external view returns (Price memory) {
        return _p();
    }

    function updatePriceFeeds(bytes[] calldata) external payable {}

    function updatePriceFeedsIfNecessary(
        bytes[] calldata,
        bytes32[] calldata,
        uint64[] calldata
    ) external payable {}

    function getUpdateFee(bytes[] calldata) external pure returns (uint) {
        return ORACLE_FEE;
    }
}

/// @dev Standard ERC-20 with a public mint.
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @dev Fee-on-transfer ERC-20: burns `feeBps` basis-points of every non-mint/burn transfer.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public feeBps; // 100 = 1 %

    constructor(string memory n, string memory s, uint256 feeBps_) ERC20(n, s) {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, address(0), fee); // burn fee
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}


// Helpers


contract StableCoinTest is Test {
    uint256 internal constant WAD = 1e18;

    MockPyth internal pyth;
    MockERC20 internal base;
    StableCoinReactor internal reactor;

    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    bytes32 internal constant PRICE_ID = bytes32(uint256(1));

    //  helpers 

    function _deployReactor(
        address baseToken
    ) internal returns (StableCoinReactor r) {
        r = new StableCoinReactor(
            "TestVault",
            "Base",
            "BASE",
            "Neutron",
            "NTR",
            baseToken,
            address(pyth),
            PRICE_ID,
            "Proton",
            "PTR",
            treasury,
            0, 
            0, 
            WAD 
        );
    }

    function _bootstrapFission(
        StableCoinReactor r,
        MockERC20 tok,
        uint256 amt
    ) internal {
        tok.mint(alice, amt);
        vm.startPrank(alice);
        tok.approve(address(r), amt);
        r.fission{value: 0}(amt, alice, new bytes[](0), 0, 0);
        vm.stopPrank();
    }

    
    // setUp
    

    function setUp() public {
        pyth = new MockPyth();
        base = new MockERC20("Base", "BASE");
        reactor = _deployReactor(address(base));
    }

    
    // Tests – fee-on-transfer (Issue 1)
    

    /// @dev With a standard ERC-20 and zero fission fee the reserve must equal
    ///      the contract's actual token balance after bootstrap fission.
    function test_fission_standard_token_reserve_matches_balance() public {
        uint256 amountIn = 3e18;
        base.mint(alice, amountIn);

        vm.startPrank(alice);
        base.approve(address(reactor), amountIn);
        reactor.fission{value: 0}(amountIn, alice, new bytes[](0), 0, 0);
        vm.stopPrank();

        assertEq(reactor.reserve(), base.balanceOf(address(reactor)));
    }

    /// @dev With a fee-on-transfer token the reactor must use actualReceived
    ///      (not amountIn) when computing the fee split and internalReserve,
    ///      so reserve() == BASE_TOKEN.balanceOf(reactor) after fission.
    function test_fission_feeOnTransfer_reserve_matches_actual_balance()
        public
    {
        // 1 % token fee; reactor has zero fission fee so all actualReceived goes to reserve
        FeeOnTransferERC20 fotToken = new FeeOnTransferERC20("FOT", "FOT", 100);
        StableCoinReactor fotReactor = _deployReactor(address(fotToken));

        uint256 amountIn = 3e18;
        // expected: token will burn 1 % on the transferFrom  => 2.97e18 arrives in contract
        uint256 expectedReceived = amountIn - (amountIn * 100) / 10_000;

        fotToken.mint(alice, amountIn);
        vm.startPrank(alice);
        fotToken.approve(address(fotReactor), amountIn);
        fotReactor.fission{value: 0}(amountIn, alice, new bytes[](0), 0, 0);
        vm.stopPrank();

        uint256 actualBalance = fotToken.balanceOf(address(fotReactor));
        assertEq(actualBalance, expectedReceived, "token balance mismatch");
        // Key invariant: internalReserve must equal what the contract actually holds
        assertEq(
            fotReactor.reserve(),
            actualBalance,
            "reserve desync with actual balance"
        );
    }

    /// @dev With a non-zero fission fee on a fee-on-transfer token, both the fee
    ///      sent to treasury and internalReserve must be derived from actualReceived.
    function test_fission_feeOnTransfer_with_fissionFee() public {
        // 1 % token fee, 2 % reactor fission fee
        FeeOnTransferERC20 fotToken = new FeeOnTransferERC20("FOT", "FOT", 100);

        uint256 fissionFeeBps = 200; // 2 %  expressed as WAD fraction
        uint256 fissionFeeWad = (fissionFeeBps * WAD) / 10_000; // 0.02e18

        StableCoinReactor fotReactor = new StableCoinReactor(
            "TestVault",
            "Base",
            "BASE",
            "Neutron",
            "NTR",
            address(fotToken),
            address(pyth),
            PRICE_ID,
            "Proton",
            "PTR",
            treasury,
            fissionFeeWad,
            0,
            WAD
        );

        uint256 amountIn = 3e18;
        // token burns 1 % on transferFrom
        uint256 actualReceived = amountIn - (amountIn * 100) / 10_000; // 2.97e18
        uint256 feeAmount = Math.mulDiv(actualReceived, fissionFeeWad, WAD);
        uint256 expectedNet = actualReceived - feeAmount;

        fotToken.mint(alice, amountIn);
        vm.startPrank(alice);
        fotToken.approve(address(fotReactor), amountIn);
        fotReactor.fission{value: 0}(amountIn, alice, new bytes[](0), 0, 0);
        vm.stopPrank();

        assertEq(fotReactor.reserve(), expectedNet, "reserve != expectedNet");
        // treasury received feeAmount from the reactor's transferTo call;
        // treasury itself may also be subject to the token fee on that transfer,
        // so we just assert the reactor's reserve is correct (the main invariant)
        assertEq(
            fotToken.balanceOf(address(fotReactor)),
            expectedNet,
            "balance != reserve"
        );
    }

    
    // Tests – _refundExcess helper (Issue 2)
    

    /// @dev Calling updatePriceFeeds with exactly the required fee leaves no refund.
    function test_refund_updatePriceFeeds_exact_fee_no_refund() public {
        uint256 fee = pyth.ORACLE_FEE();
        vm.deal(alice, fee);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        reactor.updatePriceFeeds{value: fee}(new bytes[](0));
        uint256 balAfter = alice.balance;

        assertEq(
            balBefore - balAfter,
            fee,
            "alice should have paid exactly the fee"
        );
    }

    /// @dev Calling updatePriceFeeds with excess ETH refunds the surplus to caller.
    function test_refund_updatePriceFeeds_excess_is_refunded() public {
        uint256 fee = pyth.ORACLE_FEE();
        uint256 excess = 0.05 ether;
        vm.deal(alice, fee + excess);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        reactor.updatePriceFeeds{value: fee + excess}(new bytes[](0));
        uint256 balAfter = alice.balance;

        assertEq(
            balBefore - balAfter,
            fee,
            "only the oracle fee should be spent"
        );
    }

    /// @dev fission: excess ETH above oracle fee is refunded to caller.
    function test_refund_fission_excess_eth_refunded() public {
        uint256 amountIn = 3e18;
        base.mint(alice, amountIn);

        uint256 oracleFee = pyth.ORACLE_FEE();
        uint256 excess = 0.05 ether;
        vm.deal(alice, oracleFee + excess);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00";

        vm.startPrank(alice);
        base.approve(address(reactor), amountIn);
        uint256 ethBefore = alice.balance;
        reactor.fission{value: oracleFee + excess}(
            amountIn,
            alice,
            updateData,
            0,
            0
        );
        uint256 ethAfter = alice.balance;
        vm.stopPrank();

        assertEq(
            ethBefore - ethAfter,
            oracleFee,
            "only oracle fee should be consumed"
        );
    }

    /// @dev transmuteProtonToNeutron: excess ETH above oracle fee is refunded.
    function test_refund_transmutePlus_excess_eth_refunded() public {
        uint256 amountIn = 3e18;
        // Bootstrap the reactor first
        _bootstrapFission(reactor, base, amountIn);

        uint256 oracleFee = pyth.ORACLE_FEE();
        uint256 excess = 0.05 ether;
        vm.deal(alice, oracleFee + excess);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00";

        uint256 protonBal = reactor.PROTON_TOKEN().balanceOf(alice);
        require(protonBal > 0, "no proton balance");

        vm.startPrank(alice);
        uint256 ethBefore = alice.balance;
        reactor.transmuteProtonToNeutron{value: oracleFee + excess}(
            protonBal / 2,
            alice,
            updateData,
            0
        );
        uint256 ethAfter = alice.balance;
        vm.stopPrank();

        assertEq(
            ethBefore - ethAfter,
            oracleFee,
            "only oracle fee should be consumed"
        );
    }

    /// @dev transmuteNeutronToProton: excess ETH above oracle fee is refunded.
    function test_refund_transmuteMinus_excess_eth_refunded() public {
        uint256 amountIn = 3e18;
        _bootstrapFission(reactor, base, amountIn);

        uint256 oracleFee = pyth.ORACLE_FEE();
        uint256 excess = 0.05 ether;
        vm.deal(alice, oracleFee + excess);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00";

        uint256 neutronBal = reactor.NEUTRON_TOKEN().balanceOf(alice);
        require(neutronBal > 0, "no neutron balance");

        vm.startPrank(alice);
        uint256 ethBefore = alice.balance;
        reactor.transmuteNeutronToProton{value: oracleFee + excess}(
            neutronBal / 2,
            alice,
            updateData,
            0
        );
        uint256 ethAfter = alice.balance;
        vm.stopPrank();

        assertEq(
            ethBefore - ethAfter,
            oracleFee,
            "only oracle fee should be consumed"
        );
    }

    
    // Regression: standard fission still works correctly end-to-end
    

    function test_fission_bootstrap_mints_correct_tokens() public {
        // amountIn = 3e18, price = 1 USD (1e18 WAD), fissionFee = 0
        // bootstrap: neutronOut = 1e18,  protonOut = 2e18
        uint256 amountIn = 3e18;
        base.mint(alice, amountIn);

        vm.startPrank(alice);
        base.approve(address(reactor), amountIn);
        reactor.fission{value: 0}(amountIn, alice, new bytes[](0), 0, 0);
        vm.stopPrank();

        assertEq(
            reactor.NEUTRON_TOKEN().balanceOf(alice),
            1e18,
            "neutron mismatch"
        );
        assertEq(
            reactor.PROTON_TOKEN().balanceOf(alice),
            2e18,
            "proton mismatch"
        );
        assertEq(reactor.reserve(), 3e18, "reserve mismatch");
    }

    function test_fission_emits_actualReceived_in_event() public {
        FeeOnTransferERC20 fotToken = new FeeOnTransferERC20("FOT", "FOT", 100);
        StableCoinReactor fotReactor = _deployReactor(address(fotToken));

        uint256 amountIn = 3e18;
        // token charges 1 % on transferFrom  =>  reactor receives 2.97e18
        uint256 actualReceived = amountIn - (amountIn * 100) / 10_000; // 2.97e18

        // Bootstrap outputs (fissionFee=0, basePriceWad=1e18):
        //   depositValueWad = actualReceived
        //   neutronValueWad = actualReceived / 3
        //   protonBaseWad   = actualReceived - neutronValueWad
        uint256 neutronExpected = actualReceived / 3; // 9.9e17
        uint256 protonExpected = actualReceived - neutronExpected; // 1.98e18

        fotToken.mint(alice, amountIn);
        vm.startPrank(alice);
        fotToken.approve(address(fotReactor), amountIn);

        // The key assertion: baseIn in the emitted event must equal actualReceived (2.97e18),
        // NOT amountIn (3e18).
        vm.expectEmit(true, true, false, true, address(fotReactor));
        emit StableCoinReactor.Fission(
            alice,
            alice,
            actualReceived,
            neutronExpected,
            protonExpected,
            0
        );
        fotReactor.fission{value: 0}(amountIn, alice, new bytes[](0), 0, 0);
        vm.stopPrank();
    }
}
