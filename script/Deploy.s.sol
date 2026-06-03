// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {GluonPythAdapter} from "../src/oracles/GluonPythAdapter.sol";
import {GluonChainlinkAdapter} from "../src/oracles/GluonChainlinkAdapter.sol";
import {GluonOrbAdapter} from "../src/oracles/GluonOrbAdapter.sol"; // Added for Orb

contract DeployGluon is Script {
    StableCoinFactory public factory;
    GluonPythAdapter public pythAdapter;
    GluonChainlinkAdapter public chainlinkAdapter;
    GluonOrbAdapter public orbAdapter;

    // Configuration for target network (should be set in .env)
    address pythContractAddress;
    bytes32 pythPriceId;
    address chainlinkFeedAddress;
    address orbFeedAddress;

    // Security: Maximum allowable price staleness in seconds (e.g., 60s)
    uint256 constant ORACLE_MAX_AGE = 60;

    function setUp() public {
        // Load env variables or set defaults for local testing
        pythContractAddress = vm.envOr("PYTH_ADDRESS", address(0)); 
        pythPriceId = vm.envOr("PYTH_PRICE_ID", bytes32(0));
        chainlinkFeedAddress = vm.envOr("CHAINLINK_FEED", address(0));
        orbFeedAddress = vm.envOr("ORB_FEED", address(0));
    }

    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // 1. Deploy Factory
        factory = new StableCoinFactory();
        console.log("Factory Deployed: ", address(factory));

        // 2. Deploy Pyth Adapter (if config exists)
        if (pythContractAddress != address(0)) {
            // Passed ORACLE_MAX_AGE to constructor
            pythAdapter = new GluonPythAdapter(pythContractAddress, pythPriceId, ORACLE_MAX_AGE);
            console.log("Pyth Adapter Deployed: ", address(pythAdapter));
        }

        // 3. Deploy Chainlink Adapter (if config exists)
        if (chainlinkFeedAddress != address(0)) {
            // Passed ORACLE_MAX_AGE to constructor
            chainlinkAdapter = new GluonChainlinkAdapter(chainlinkFeedAddress, ORACLE_MAX_AGE);
            console.log("Chainlink Adapter Deployed: ", address(chainlinkAdapter));
        }

        // 4. Deploy Orb Adapter (if config exists)
        if (orbFeedAddress != address(0)) {
            // Passed ORACLE_MAX_AGE to constructor
            orbAdapter = new GluonOrbAdapter(orbFeedAddress, ORACLE_MAX_AGE);
            console.log("Orb Adapter Deployed: ", address(orbAdapter));
        }

        // Example: To deploy a Reactor, you would now call factory.deployReactor(...) 
        // passing address(pythAdapter), address(chainlinkAdapter), or address(orbAdapter) as the oracleParam.

        vm.stopBroadcast();
    }
}
