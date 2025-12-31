// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./DeployHelpers.s.sol";
import "../contracts/HousePool.sol";

/// @notice Standalone deployment script for HousePool
/// @dev Use Deploy.s.sol for the main deployment (auto-detects Base fork vs local)
contract DeployHousePool is ScaffoldETHDeploy {
    function run(address usdc) external ScaffoldEthDeployerRunner {
        HousePool housePool = new HousePool(usdc);
        
        console.log("HousePool deployed at:", address(housePool));
        console.log("USDC:", usdc);
    }
}
