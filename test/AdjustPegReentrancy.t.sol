// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockOracle} from "./GenericIOracleIntegration.t.sol";

interface IReceiveHook {
    function tokensReceived(address from, uint256 amount) external;
}

/// Base token that calls a registered recipient after each transfer, like an ERC-777 receive hook.
contract HookERC20 is ERC20 {
    mapping(address => bool) public hooked;

    constructor() ERC20("Hook Base", "HB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function registerHook() external {
        hooked[msg.sender] = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hooked[to]) IReceiveHook(to).tokensReceived(from, value);
    }
}

/// Calls adjustPeg() from inside the receive hook for as long as it succeeds and records why
/// the call that stopped it reverted.
contract PegPoker is IReceiveHook {
    StableCoinReactor public reactor;
    bool public armed;
    uint256 public pokes;
    bytes public stopReason;

    function init(StableCoinReactor reactor_, HookERC20 token) external {
        reactor = reactor_;
        token.registerHook();
    }

    function arm() external {
        armed = true;
    }

    function tokensReceived(address, uint256) external {
        if (!armed) return;
        for (uint256 i; i < 100; ++i) {
            try reactor.adjustPeg() {
                ++pokes;
            } catch (bytes memory reason) {
                stopReason = reason;
                break;
            }
        }
    }
}

contract AdjustPegReentrancyTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant PEG_FACTOR_SCALE = 1e36;

    address private dev = makeAddr("dev");
    address private user = makeAddr("user");

    HookERC20 private base;
    GenericMockOracle private oracle;
    StableCoinReactor private reactor;
    PegPoker private poker;

    function setUp() public {
        base = new HookERC20();
        oracle = new GenericMockOracle(WAD);
        StableCoinFactory factory = new StableCoinFactory(dev, 1e15); // 0.1% dev fee
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
                12e17, // critical ratio 120%
                15e17, // initial ratio 150%
                100e18,
                1e16,
                0,
                WAD
            )
        );
        poker = new PegPoker();
        poker.init(reactor, base);

        base.mint(user, 1000e18);
        vm.prank(user);
        base.approve(address(reactor), type(uint256).max);
    }

    /// Fission pays the dev fee after the deposit arrives and before it mints anything. A fee
    /// receiver hook used to see the new reserve against the old Neutron supply, a ratio above
    /// 200%, and could raise the peg again and again inside one ordinary fission.
    function testAdjustPegCannotRunInsideFissionDevFee() public {
        vm.prank(dev);
        reactor.setDevFeeReceiver(address(poker));
        poker.arm();

        vm.prank(user);
        reactor.fission(100e18, user);

        assertEq(poker.pokes(), 0, "adjustPeg ran inside the dev fee transfer");
        assertEq(
            poker.stopReason(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "the hook's adjustPeg call should be stopped by the reentrancy guard"
        );
        assertEq(reactor.pegFactor(), PEG_FACTOR_SCALE);
    }

    /// Outside an operation adjustPeg() still works for anyone.
    function testAdjustPegStillWorksOutsideOperations() public {
        oracle.setValue(14e17); // ratio 150% -> 210%
        vm.prank(user);
        reactor.adjustPeg();
        assertEq(reactor.pegFactor(), PEG_FACTOR_SCALE * 101 / 100);
    }
}
