// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./HousePool.sol";

/// @title DiceGame - Commit-reveal dice game using HousePool liquidity
/// @notice Players commit to a roll, then reveal to determine win/loss
/// @dev Deploys its own HousePool with this contract as the immutable game
contract DiceGame {
    /* ========== CUSTOM ERRORS ========== */
    error GameNotPlayable();
    error NoCommitment();
    error TooEarly();
    error TooLate();
    error InvalidReveal();

    /* ========== STATE VARIABLES ========== */
    
    HousePool public immutable housePool;
    IERC20 public immutable usdc;
    
    // Commit-reveal gambling
    struct Commitment {
        bytes32 hash;
        uint256 blockNumber;
    }
    mapping(address => Commitment) public commits;

    /* ========== CONSTANTS ========== */
    
    // Gambling parameters
    uint256 public constant ROLL_COST = 1e5;        // 0.10 USDC (10 cents)
    uint256 public constant ROLL_PAYOUT = 1e6;      // 1 USDC
    uint256 public constant WIN_MODULO = 11;        // 1/11 ≈ 9% win rate, 9% house edge
    
    // Pool thresholds (game-specific reserve requirement)
    uint256 public constant MIN_RESERVE = 3e6;      // 3 USDC minimum (covers 2 wins in a row)

    /* ========== EVENTS ========== */
    
    event RollCommitted(address indexed player, bytes32 commitment);
    event RollRevealed(address indexed player, bool won, uint256 payout);

    /* ========== CONSTRUCTOR ========== */
    
    /// @notice Deploys a new HousePool with this DiceGame as the immutable game contract
    /// @param _usdc Address of the USDC token
    constructor(address _usdc) {
        usdc = IERC20(_usdc);
        // Deploy HousePool with this contract as the game
        housePool = new HousePool(_usdc, address(this));
    }

    /* ========== GAMBLING FUNCTIONS ========== */
    
    /// @notice Step 1: Commit to a roll. Hash = keccak256(abi.encodePacked(secret))
    /// @param commitHash Hash of the player's secret
    function commitRoll(bytes32 commitHash) external {
        // Check game is playable (enough liquidity)
        if (!canPlay()) revert GameNotPlayable();
        
        // Take payment via HousePool
        housePool.receivePayment(msg.sender, ROLL_COST);
        
        commits[msg.sender] = Commitment({
            hash: commitHash,
            blockNumber: block.number
        });
        
        emit RollCommitted(msg.sender, commitHash);
    }
    
    /// @notice Step 2: Reveal secret after 1+ block, within 256 blocks
    /// @param secret The secret that was hashed in commitRoll
    /// @return won Whether the player won
    function revealRoll(bytes32 secret) external returns (bool won) {
        Commitment memory c = commits[msg.sender];
        
        if (c.blockNumber == 0) revert NoCommitment();
        if (block.number <= c.blockNumber) revert TooEarly();
        if (keccak256(abi.encodePacked(secret)) != c.hash) revert InvalidReveal();
        
        // Get the commit block's hash - must not be 0 (only available for last 256 blocks)
        bytes32 commitBlockHash = blockhash(c.blockNumber);
        if (commitBlockHash == 0) revert TooLate();
        
        delete commits[msg.sender];
        
        // Fair randomness: player's secret + unknowable commit block hash
        bytes32 entropy = keccak256(abi.encodePacked(
            secret,
            commitBlockHash
        ));
        
        won = (uint256(entropy) % WIN_MODULO) == 0;
        
        if (won) {
            housePool.payout(msg.sender, ROLL_PAYOUT);
        }
        
        emit RollRevealed(msg.sender, won, won ? ROLL_PAYOUT : 0);
    }

    /* ========== VIEW FUNCTIONS ========== */
    
    /// @notice Whether the game can accept new rolls
    function canPlay() public view returns (bool) {
        return housePool.effectivePool() >= MIN_RESERVE + ROLL_PAYOUT;
    }
    
    /// @notice Get commitment details for a player
    function getCommitment(address player) external view returns (
        bytes32 hash,
        uint256 blockNumber,
        bool canReveal,
        bool isExpired
    ) {
        Commitment memory c = commits[player];
        hash = c.hash;
        blockNumber = c.blockNumber;
        canReveal = c.blockNumber > 0 && 
                    block.number > c.blockNumber && 
                    block.number <= c.blockNumber + 256;
        isExpired = c.blockNumber > 0 && block.number > c.blockNumber + 256;
    }
    
    /// @notice Check if a roll would be a winner (call before reveal to save gas on losses)
    /// @param player The player's address
    /// @param secret The secret that was hashed in commitRoll
    /// @return canCheck Whether the result can be checked (valid commitment, correct secret, blockhash available)
    /// @return isWinner Whether the roll is a winner
    function checkRoll(address player, bytes32 secret) external view returns (bool canCheck, bool isWinner) {
        Commitment memory c = commits[player];
        
        // No commitment
        if (c.blockNumber == 0) return (false, false);
        
        // Too early (still in commit block)
        if (block.number <= c.blockNumber) return (false, false);
        
        // Wrong secret
        if (keccak256(abi.encodePacked(secret)) != c.hash) return (false, false);
        
        // Get commit block hash
        bytes32 commitBlockHash = blockhash(c.blockNumber);
        
        // Too late (blockhash no longer available)
        if (commitBlockHash == 0) return (false, false);
        
        // Calculate result
        bytes32 entropy = keccak256(abi.encodePacked(secret, commitBlockHash));
        isWinner = (uint256(entropy) % WIN_MODULO) == 0;
        
        return (true, isWinner);
    }
}
