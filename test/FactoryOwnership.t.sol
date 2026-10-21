// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";

contract FactoryOwnershipTest is Test {
    function testFactoryHasNoOwnershipInterface() public {
        StableCoinFactory factory = new StableCoinFactory(address(this), 0);

        (bool readsOwner,) = address(factory).staticcall(abi.encodeWithSignature("owner()"));
        (bool transfersOwner,) =
            address(factory).call(abi.encodeWithSignature("transferOwnership(address)", makeAddr("newOwner")));
        (bool renouncesOwner,) = address(factory).call(abi.encodeWithSignature("renounceOwnership()"));

        assertFalse(readsOwner);
        assertFalse(transfersOwner);
        assertFalse(renouncesOwner);
    }
}
