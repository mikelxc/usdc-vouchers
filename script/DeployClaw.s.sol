// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Claw} from "../src/Claw.sol";

contract DeployClaw is Script {
    // Base Sepolia USDC
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        Claw claw = new Claw(USDC);
        
        console.log("Claw deployed to:", address(claw));
        
        vm.stopBroadcast();
    }
}
