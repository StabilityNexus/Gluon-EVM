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
        uint256 fissionFee,
        uint256 fusionFee,
        uint256 criticalReserveRatioWad
    );

    event ReactorDeployedWithOracle(
        address indexed reactor,
        address indexed base,
        bytes32 basePriceId
    );

    address[] public deployedReactors;
    mapping(address => address[]) public reactorsByBase;

    constructor() Ownable(msg.sender) {}

    /**
     * Deploy a new Reactor
     * @param vaultNameParam   vault label
     * @param baseAssetNameParam display name for the base asset
     * @param baseAssetSymbolParam symbol for the base asset
     * @param peggedAssetNameParam name for the pegged (neutron) token
     * @param peggedAssetSymbolParam symbol for the pegged token
     * @param baseTokenParam   ERC20 reserve
     * @param pythOracleParam  Pyth contract
     * @param priceIdParam     Pyth feed for BASE/USD (or Peg)
     * @param protonNameParam  name of the proton token
     * @param protonSymbolParam symbol of the proton token
     * @param treasuryParam    fees / governance
     * @param fissionFeeParam  WAD
     * @param fusionFeeParam   WAD
     * @param criticalReserveRatioWadParam minimum reserve ratio (>=1e18)
     */
    function deployReactor(
        string memory vaultNameParam,
        string memory baseAssetNameParam,
        string memory baseAssetSymbolParam,
        string memory peggedAssetNameParam,
        string memory peggedAssetSymbolParam,
        address baseTokenParam,
        address pythOracleParam,
        bytes32 priceIdParam,
        string memory protonNameParam,
        string memory protonSymbolParam,
        address treasuryParam,
        uint256 fissionFeeParam,
        uint256 fusionFeeParam,
        uint256 criticalReserveRatioWadParam
    ) public onlyOwner returns (address) {
        require(bytes(vaultNameParam).length > 0, "Empty vault name");
        require(bytes(baseAssetNameParam).length > 0, "Empty base name");
        require(bytes(baseAssetSymbolParam).length > 0, "Empty base symbol");
        require(bytes(peggedAssetNameParam).length > 0, "Empty peg name");
        require(bytes(peggedAssetSymbolParam).length > 0, "Empty peg symbol");
        require(bytes(protonNameParam).length > 0, "Empty proton name");
        require(bytes(protonSymbolParam).length > 0, "Empty proton symbol");
        require(baseTokenParam != address(0), "Invalid base");
        require(pythOracleParam != address(0), "Invalid Pyth");
        require(treasuryParam != address(0), "Invalid treasury");
        require(fissionFeeParam < 1e18, "fissionFee >= 100%");
        require(fusionFeeParam < 1e18, "fusionFee >= 100%");
        require(criticalReserveRatioWadParam >= 1e18, "critical ratio < 100%");

        StableCoinReactor reactor = new StableCoinReactor(
            vaultNameParam,
            baseAssetNameParam,
            baseAssetSymbolParam,
            peggedAssetNameParam,
            peggedAssetSymbolParam,
            baseTokenParam,
            pythOracleParam,
            priceIdParam,
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
            fissionFeeParam,
            fusionFeeParam,
            criticalReserveRatioWadParam
        );

        emit ReactorDeployedWithOracle(
            reactorAddress,
            baseTokenParam,
            priceIdParam
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
