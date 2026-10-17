// SPDX-License-Identifier: AEL
pragma solidity ^0.8.20;

import {StableCoinReactor} from "./StableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StableCoinFactory {
    using SafeERC20 for IERC20;

    event ReactorDeployed(
        address indexed reactor,
        address indexed base,
        address indexed devFeeReceiver,
        string vaultName,
        string baseAssetName,
        string baseAssetSymbol,
        string peggedAssetName,
        string peggedAssetSymbol,
        string protonName,
        string protonSymbol,
        address oracleAddress,
        uint256 fissionFee,
        uint256 fusionFee,
        uint256 criticalReserveRatioWad,
        uint256 initialReserve,
        address dev,
        uint256 devFee
    );

    address[] public deployedReactors;
    mapping(address => address[]) public reactorsByBase;

    error EmptyVaultName();
    error EmptyBaseName();
    error EmptyBaseSymbol();
    error EmptyPegName();
    error EmptyPegSymbol();
    error EmptyProtonName();
    error EmptyProtonSymbol();
    error InvalidBase();
    error InvalidOracle();
    error InvalidDev();
    error InvalidDevFee();
    error InvalidFissionFee();
    error InvalidFusionFee();
    error InvalidCriticalReserveRatio();
    error InvalidInitialReserve();

    /**
     * Deploy a new Reactor
     * @param oracleParam      Address of an IOracle-compatible adapter
     */
    function deployReactor(
        string memory vaultNameParam,
        string memory baseAssetNameParam,
        string memory baseAssetSymbolParam,
        string memory peggedAssetNameParam,
        string memory peggedAssetSymbolParam,
        address baseTokenParam,
        address oracleParam,
        string memory protonNameParam,
        string memory protonSymbolParam,
        address devParam,
        uint256 devFeeParam,
        uint256 fissionFeeParam,
        uint256 fusionFeeParam,
        uint256 criticalReserveRatioWadParam,
        uint256 initialReserveParam,
        uint256 betaPhi0Param,
        uint256 betaPhi1Param,
        uint256 decayPerSecondWadParam
    ) public returns (address) {
        if (bytes(vaultNameParam).length == 0) revert EmptyVaultName();
        if (bytes(baseAssetNameParam).length == 0) revert EmptyBaseName();
        if (bytes(baseAssetSymbolParam).length == 0) revert EmptyBaseSymbol();
        if (bytes(peggedAssetNameParam).length == 0) revert EmptyPegName();
        if (bytes(peggedAssetSymbolParam).length == 0) revert EmptyPegSymbol();
        if (bytes(protonNameParam).length == 0) revert EmptyProtonName();
        if (bytes(protonSymbolParam).length == 0) revert EmptyProtonSymbol();
        if (baseTokenParam == address(0)) revert InvalidBase();
        if (oracleParam == address(0)) revert InvalidOracle();
        if (devParam == address(0)) revert InvalidDev();
        if (devFeeParam >= 1e18) revert InvalidDevFee();
        if (fissionFeeParam >= 1e18 - devFeeParam) revert InvalidFissionFee();
        if (fusionFeeParam >= 1e18 - devFeeParam) revert InvalidFusionFee();
        if (criticalReserveRatioWadParam < 1e18) revert InvalidCriticalReserveRatio();
        if (initialReserveParam == 0) revert InvalidInitialReserve();

        StableCoinReactor reactor = new StableCoinReactor(
            vaultNameParam,
            baseAssetNameParam,
            baseAssetSymbolParam,
            peggedAssetNameParam,
            peggedAssetSymbolParam,
            baseTokenParam,
            oracleParam, // Pass the adapter address
            protonNameParam,
            protonSymbolParam,
            devParam,
            devFeeParam,
            fissionFeeParam,
            fusionFeeParam,
            criticalReserveRatioWadParam,
            betaPhi0Param,
            betaPhi1Param,
            decayPerSecondWadParam
        );

        address reactorAddress = address(reactor);

        IERC20 baseToken = IERC20(baseTokenParam);
        uint256 factoryBalanceBefore = baseToken.balanceOf(address(this));

        baseToken.safeTransferFrom(msg.sender, address(this), initialReserveParam);

        uint256 amountIn = baseToken.balanceOf(address(this)) - factoryBalanceBefore;
        if (amountIn == 0) revert InvalidInitialReserve();

        baseToken.forceApprove(reactorAddress, amountIn);
        reactor.initialFission(amountIn);

        uint256 initialReserve = reactor.reserve();

        deployedReactors.push(reactorAddress);
        reactorsByBase[baseTokenParam].push(reactorAddress);

        emit ReactorDeployed(
            reactorAddress,
            baseTokenParam,
            devParam,
            vaultNameParam,
            baseAssetNameParam,
            baseAssetSymbolParam,
            peggedAssetNameParam,
            peggedAssetSymbolParam,
            protonNameParam,
            protonSymbolParam,
            oracleParam,
            fissionFeeParam,
            fusionFeeParam,
            criticalReserveRatioWadParam,
            initialReserve,
            devParam,
            devFeeParam
        );

        return reactorAddress;
    }

    function getDeployedReactorsCount() external view returns (uint256) {
        return deployedReactors.length;
    }

    function getAllDeployedReactors() external view returns (address[] memory) {
        return deployedReactors;
    }
}
