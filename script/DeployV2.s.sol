// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ClawV2} from "../src/ClawV2.sol";

contract DeployV2 is Script {
    // Base Sepolia USDC
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        ClawV2 claw = new ClawV2(USDC);
        
        console.log("ClawV2 deployed to:", address(claw));
        
        vm.stopBroadcast();
    }
}
