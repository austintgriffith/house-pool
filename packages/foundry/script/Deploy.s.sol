//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./DeployHelpers.s.sol";
import "../contracts/DiceGame.sol";

/**
 * @notice Deployment script for DiceGame (which deploys HousePool)
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
        // Deploy DiceGame (which deploys its own HousePool internally)
        DiceGame diceGame = new DiceGame(USDC);
        
        // Export both contracts for Scaffold-ETH
        deployments.push(Deployment("DiceGame", address(diceGame)));
        deployments.push(Deployment("HousePool", address(diceGame.housePool())));
        
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("DiceGame:", address(diceGame));
        console.log("HousePool:", address(diceGame.housePool()));
        console.log("USDC:", USDC);
        console.log("");
        console.log("Next: Approve USDC and call housePool.deposit(amount) to seed liquidity");
    }
}
