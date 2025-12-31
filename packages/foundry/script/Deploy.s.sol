//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./DeployHelpers.s.sol";
import "../contracts/HousePool.sol";

/**
 * @notice Deployment script for HousePool on Base fork
 * @dev Uses real USDC on Base: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 * 
 * Usage:
 *   yarn fork --network base
 *   yarn deploy
 */
contract DeployScript is ScaffoldETHDeploy {
    // Base Mainnet USDC
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external ScaffoldEthDeployerRunner {
        // Deploy HousePool with real USDC
        HousePool housePool = new HousePool(USDC);
        
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("HousePool:", address(housePool));
        console.log("USDC:", USDC);
        console.log("");
        console.log("Next: Approve USDC and call housePool.deposit(amount) to seed liquidity");
    }
}
