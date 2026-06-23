// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {ChainlinkToOracleAdapter} from "../src/oracles/ChainlinkToOracleAdapter.sol";

contract DeployGluon is Script {
    StableCoinFactory public factory;
    ChainlinkToOracleAdapter public chainlinkAdapter;

    address chainlinkFeedAddress;

    function setUp() public {
        chainlinkFeedAddress = vm.envOr("CHAINLINK_FEED", address(0));
    }

    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        factory = new StableCoinFactory();
        console.log("Factory Deployed: ", address(factory));

        if (chainlinkFeedAddress != address(0)) {
            chainlinkAdapter = new ChainlinkToOracleAdapter(chainlinkFeedAddress);
            console.log("Chainlink Adapter Deployed: ", address(chainlinkAdapter));
        }

        // To deploy a reactor, pass an IOracle-compatible adapter address as oracleParam.

        vm.stopBroadcast();
    }
}
