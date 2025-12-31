// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./DeployHelpers.s.sol";
import "../contracts/DiceGame.sol";

/// @notice Standalone deployment script for DiceGame + HousePool
/// @dev Use Deploy.s.sol for the main deployment (auto-detects Base fork vs local)
contract DeployHousePool is ScaffoldETHDeploy {
    function run(address usdc) external ScaffoldEthDeployerRunner {
        // Deploy DiceGame (which deploys its own HousePool internally)
        DiceGame diceGame = new DiceGame(usdc);
        
        console.log("DiceGame deployed at:", address(diceGame));
        console.log("HousePool deployed at:", address(diceGame.housePool()));
        console.log("USDC:", usdc);
    }
}
