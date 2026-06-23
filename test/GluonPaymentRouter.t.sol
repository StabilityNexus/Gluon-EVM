// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/GluonPaymentRouter.sol";

// Mock ERC20
contract MockToken is IERC20 {
    mapping(address => uint256) public balances;

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }
}

// Mock Gluon Reactor
contract MockGluon is IGluon {
    address public neutron;
    address public proton;

    constructor(address _neutron, address _proton) {
        neutron = _neutron;
        proton = _proton;
    }

    function NEUTRON_TOKEN() external view override returns (address) {
        return neutron;
    }

    function PROTON_TOKEN() external view override returns (address) {
        return proton;
    }

    function fission(uint256 amountIn, address to, bytes[] calldata) external payable override {
        // Mock behavior: Mint 50 Neutrons and 50 Protons to 'to'
        // In real life, amounts depend on math, but for Router testing,
        // we just care that Router receives tokens and forwards them.
        MockToken(neutron).mint(to, 50 ether);
        MockToken(proton).mint(to, 50 ether);
    }
}

contract GluonPaymentRouterTest is Test {
    GluonPaymentRouter router;
    MockGluon gluon;
    MockToken neutron;
    MockToken proton;

    address user = address(0x123);
    address merchant = address(0x456);

    function setUp() public {
        neutron = new MockToken();
        proton = new MockToken();
        gluon = new MockGluon(address(neutron), address(proton));
        router = new GluonPaymentRouter(address(gluon));
        
        // Fund user
        vm.deal(user, 10 ether);
    }

    function testPayWithFissionMovesTokensCorrectly() public {
        // 1. Arrange
        uint256 payAmount = 1 ether;
        bytes[] memory data = new bytes[](0);

        // 2. Act
        vm.prank(user);
        router.payWithFission{value: payAmount}(merchant, data);

        // 3. Assert
        
        // Merchant should receive Neutrons
        assertEq(neutron.balanceOf(merchant), 50 ether, "Merchant should get Neutrons");
        assertEq(neutron.balanceOf(user), 0, "User should NOT get Neutrons");
        assertEq(neutron.balanceOf(address(router)), 0, "Router should typically be empty");

        // User should receive Protons (Refunded)
        assertEq(proton.balanceOf(user), 50 ether, "User should get Protons");
        assertEq(proton.balanceOf(merchant), 0, "Merchant should NOT get Protons");
        assertEq(proton.balanceOf(address(router)), 0, "Router should typically be empty");
    }
}
