// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IOracle} from "../src/interfaces/IOracle.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";

contract GenericMockERC20 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract GenericMockOracle is IOracle {
    uint256 private value;
    uint256 private maxValue;
    uint256 private minValue;
    uint256 private updatedAt;

    constructor(uint256 valueParam) {
        value = valueParam;
        maxValue = valueParam;
        minValue = valueParam;
        updatedAt = block.timestamp;
    }

    function setValue(uint256 valueParam) external {
        value = valueParam;
        maxValue = valueParam;
        minValue = valueParam;
        updatedAt = block.timestamp;
    }

    function readValue() external view returns (uint256) {
        return value;
    }

    function readMaxValue() external view returns (uint256) {
        return maxValue;
    }

    function readMinValue() external view returns (uint256) {
        return minValue;
    }

    function lastUpdated() external view returns (uint256) {
        return updatedAt;
    }

    function description() external pure returns (string memory) {
        return "Generic Mock Oracle";
    }
}

contract GenericIOracleIntegrationTest is Test {
    StableCoinFactory internal factory;
    GenericMockERC20 internal baseToken;

    address internal treasury = makeAddr("treasury");

    function setUp() public {
        factory = new StableCoinFactory();
        baseToken = new GenericMockERC20();
    }

    function testFactoryDeploysReactorWithGenericIOracle() public {
        GenericMockOracle oracle = new GenericMockOracle(1e18);

        uint256 countBefore = factory.getDeployedReactorsCount();

        StableCoinReactor reactor = _deployReactor(address(oracle));

        assertEq(address(reactor.ORACLE()), address(oracle));
        assertEq(factory.getDeployedReactorsCount(), countBefore + 1);
    }

    function testFissionWorksWithGenericIOracle() public {
        GenericMockOracle oracle = new GenericMockOracle(1e18);
        StableCoinReactor reactor = _deployReactor(address(oracle));

        address user = makeAddr("user");

        _fundAndFission(reactor, user, 100e18);

        assertGt(reactor.NEUTRON_TOKEN().balanceOf(user), 0);
        assertGt(reactor.PROTON_TOKEN().balanceOf(user), 0);
    }

    function testBasePriceViewUsesGenericIOracle() public {
        GenericMockOracle oracle = new GenericMockOracle(1e18);
        StableCoinReactor reactor = _deployReactor(address(oracle));

        assertEq(reactor.getBasePriceInPeggedAsset(), 1e18);

        oracle.setValue(2e18);

        assertEq(reactor.getBasePriceInPeggedAsset(), 2e18);
    }

    function testReserveRatioUsesGenericIOracleValue() public {
        GenericMockOracle oracle = new GenericMockOracle(1e18);
        StableCoinReactor reactor = _deployReactor(address(oracle));

        address user = makeAddr("reserveUser");

        _fundAndFission(reactor, user, 100e18);

        uint256 ratioAtOne = reactor.reserveRatioPeggedAsset();

        oracle.setValue(2e18);

        uint256 ratioAtTwo = reactor.reserveRatioPeggedAsset();

        assertGt(ratioAtTwo, ratioAtOne);
    }

    function testFusionWorksWithGenericIOracle() public {
        GenericMockOracle oracle = new GenericMockOracle(1e18);
        StableCoinReactor reactor = _deployReactor(address(oracle));

        address user = makeAddr("fusionUser");

        _fundAndFission(reactor, user, 100e18);

        uint256 balanceBefore = baseToken.balanceOf(user);

        vm.prank(user);
        reactor.fusion(10e18, user);

        uint256 balanceAfter = baseToken.balanceOf(user);

        assertGt(balanceAfter, balanceBefore);
    }

    function _deployReactor(address oracleAddress) internal returns (StableCoinReactor) {
        address reactorAddress = factory.deployReactor(
            "Generic Vault",
            "USD Coin",
            "USDC",
            "Gluon USD",
            "GUSD",
            address(baseToken),
            oracleAddress,
            "Gluon Gov",
            "GOV",
            treasury,
            0,
            0,
            15e17
        );

        return StableCoinReactor(reactorAddress);
    }

    function _fundAndFission(StableCoinReactor reactor, address user, uint256 amount) internal {
        baseToken.mint(user, amount);

        vm.startPrank(user);
        baseToken.approve(address(reactor), amount);
        reactor.fission(amount, user);
        vm.stopPrank();
    }
}
