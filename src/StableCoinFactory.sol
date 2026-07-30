// SPDX-License-Identifier: AEL
pragma solidity ^0.8.20;

import {StableCoinReactor} from "./StableCoin.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract StableCoinFactory is Ownable {
    event ReactorDeployed(
        address indexed reactor,
        address indexed base,
        address indexed treasury,
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
        uint256 criticalReserveRatioWad
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
    error InvalidTreasury();
    error InvalidFissionFee();
    error InvalidFusionFee();
    error InvalidCriticalReserveRatio();

    constructor() Ownable(msg.sender) {}

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
        address treasuryParam,
        uint256 fissionFeeParam,
        uint256 fusionFeeParam,
        uint256 criticalReserveRatioWadParam
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
        if (treasuryParam == address(0)) revert InvalidTreasury();
        if (fissionFeeParam >= 1e18) revert InvalidFissionFee();
        if (fusionFeeParam >= 1e18) revert InvalidFusionFee();
        if (criticalReserveRatioWadParam < 1e18) revert InvalidCriticalReserveRatio();

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
            treasuryParam,
            fissionFeeParam,
            fusionFeeParam,
            criticalReserveRatioWadParam
        );

        address reactorAddress = address(reactor);
        deployedReactors.push(reactorAddress);
        reactorsByBase[baseTokenParam].push(reactorAddress);

        emit ReactorDeployed(
            reactorAddress,
            baseTokenParam,
            treasuryParam,
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
            criticalReserveRatioWadParam
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
