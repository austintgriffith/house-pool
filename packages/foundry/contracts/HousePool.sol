// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title HousePool - Simplified gambling pool where LP tokens = house ownership
/// @notice Deposit USDC to become the house. Share price grows as house profits.
contract HousePool is ERC20 {
    /* ========== CUSTOM ERRORS ========== */
    error InsufficientPool();
    error NoCommitment();
    error TooEarly();
    error TooLate();
    error InvalidReveal();
    error WithdrawalNotReady();
    error WithdrawalExpired();
    error NoPendingWithdrawal();
    error InsufficientShares();
    error ZeroAmount();
    error TransferFailed();

    /* ========== STATE VARIABLES ========== */
    
    IERC20 public immutable usdc;
    
    // Withdrawal tracking
    struct WithdrawalRequest {
        uint256 shares;
        uint256 unlockTime;
        uint256 expiryTime;
    }
    mapping(address => WithdrawalRequest) public withdrawals;
    uint256 public totalPendingShares;
    
    // Commit-reveal gambling
    struct Commitment {
        bytes32 hash;
        uint256 blockNumber;
    }
    mapping(address => Commitment) public commits;

    /* ========== CONSTANTS ========== */
    
    // Gambling parameters
    uint256 public constant ROLL_COST = 1e6;        // 1 USDC (6 decimals)
    uint256 public constant ROLL_PAYOUT = 10e6;     // 10 USDC
    uint256 public constant WIN_MODULO = 11;        // 1/11 ≈ 9% win rate, 9% house edge
    
    // Pool thresholds
    uint256 public constant MIN_RESERVE = 30e6;     // 30 USDC minimum (covers 2 wins in a row)
    
    // Withdrawal timing
    uint256 public constant WITHDRAWAL_DELAY = 10 seconds;
    uint256 public constant WITHDRAWAL_WINDOW = 1 minutes;
    
    // First deposit minimum (prevents share manipulation attack)
    uint256 public constant MIN_FIRST_DEPOSIT = 1e6; // 1 USDC

    /* ========== EVENTS ========== */
    
    event Deposit(address indexed lp, uint256 usdcIn, uint256 sharesOut);
    event WithdrawalRequested(address indexed lp, uint256 shares, uint256 unlockTime, uint256 expiryTime);
    event WithdrawalCancelled(address indexed lp, uint256 shares);
    event WithdrawalExpiredCleanup(address indexed lp, uint256 shares);
    event Withdraw(address indexed lp, uint256 sharesIn, uint256 usdcOut);
    event RollCommitted(address indexed player, bytes32 commitment);
    event RollRevealed(address indexed player, bool won, uint256 payout);

    /* ========== CONSTRUCTOR ========== */
    
    constructor(
        address _usdc
    ) ERC20("HouseShare", "HOUSE") {
        usdc = IERC20(_usdc);
    }

    /* ========== LP FUNCTIONS ========== */
    
    /// @notice Deposit USDC, receive HOUSE shares proportional to pool
    /// @param usdcAmount Amount of USDC to deposit
    /// @return shares Amount of HOUSE tokens minted
    function deposit(uint256 usdcAmount) external returns (uint256 shares) {
        if (usdcAmount == 0) revert ZeroAmount();
        
        uint256 supply = totalSupply();
        uint256 pool = usdc.balanceOf(address(this));
        
        if (supply == 0) {
            // First deposit: enforce minimum and 1:1 ratio (scaled to 18 decimals)
            if (usdcAmount < MIN_FIRST_DEPOSIT) revert InsufficientPool();
            shares = usdcAmount * 1e12; // Scale 6 decimals → 18 decimals
        } else {
            // Proportional shares based on current pool
            shares = (usdcAmount * supply) / pool;
        }
        
        bool success = usdc.transferFrom(msg.sender, address(this), usdcAmount);
        if (!success) revert TransferFailed();
        
        _mint(msg.sender, shares);
        
        emit Deposit(msg.sender, usdcAmount, shares);
    }
    
    /// @notice Request withdrawal - starts cooldown period
    /// @param shares Amount of HOUSE tokens to withdraw
    function requestWithdrawal(uint256 shares) external {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();
        
        // If there's an existing request, remove it from pending first
        if (withdrawals[msg.sender].shares > 0) {
            totalPendingShares -= withdrawals[msg.sender].shares;
        }
        
        uint256 unlockTime = block.timestamp + WITHDRAWAL_DELAY;
        uint256 expiryTime = unlockTime + WITHDRAWAL_WINDOW;
        
        withdrawals[msg.sender] = WithdrawalRequest({
            shares: shares,
            unlockTime: unlockTime,
            expiryTime: expiryTime
        });
        
        totalPendingShares += shares;
        
        emit WithdrawalRequested(msg.sender, shares, unlockTime, expiryTime);
    }
    
    /// @notice Execute withdrawal after cooldown, within window
    /// @return usdcOut Amount of USDC received
    function withdraw() external returns (uint256 usdcOut) {
        WithdrawalRequest memory req = withdrawals[msg.sender];
        
        if (req.shares == 0) revert NoPendingWithdrawal();
        if (block.timestamp < req.unlockTime) revert WithdrawalNotReady();
        if (block.timestamp > req.expiryTime) revert WithdrawalExpired();
        
        uint256 pool = usdc.balanceOf(address(this));
        uint256 supply = totalSupply();
        
        usdcOut = (req.shares * pool) / supply;
        
        // Ensure we keep minimum reserve for payouts, UNLESS pool is being fully drained
        // (if pool goes to 0, that's fine - rolling will be disabled anyway)
        uint256 remainingPool = pool - usdcOut;
        if (remainingPool > 0 && remainingPool < MIN_RESERVE) revert InsufficientPool();
        
        totalPendingShares -= req.shares;
        delete withdrawals[msg.sender];
        
        _burn(msg.sender, req.shares);
        
        bool success = usdc.transfer(msg.sender, usdcOut);
        if (!success) revert TransferFailed();
        
        emit Withdraw(msg.sender, req.shares, usdcOut);
    }
    
    /// @notice Cancel pending withdrawal request
    function cancelWithdrawal() external {
        WithdrawalRequest memory req = withdrawals[msg.sender];
        if (req.shares == 0) revert NoPendingWithdrawal();
        
        totalPendingShares -= req.shares;
        delete withdrawals[msg.sender];
        
        emit WithdrawalCancelled(msg.sender, req.shares);
    }
    
    /// @notice Clean up expired withdrawal requests (anyone can call)
    /// @param lp Address of the LP with expired request
    function cleanupExpiredWithdrawal(address lp) external {
        WithdrawalRequest memory req = withdrawals[lp];
        
        if (req.shares == 0) revert NoPendingWithdrawal();
        if (block.timestamp <= req.expiryTime) revert WithdrawalNotReady();
        
        totalPendingShares -= req.shares;
        delete withdrawals[lp];
        
        emit WithdrawalExpiredCleanup(lp, req.shares);
    }

    /* ========== GAMBLING FUNCTIONS ========== */
    
    /// @notice Step 1: Commit to a roll. Hash = keccak256(abi.encodePacked(secret))
    /// @param commitHash Hash of the player's secret
    function commitRoll(bytes32 commitHash) external {
        // Check effective pool can cover payout
        if (effectivePool() < MIN_RESERVE + ROLL_PAYOUT) revert InsufficientPool();
        
        // Take payment
        bool success = usdc.transferFrom(msg.sender, address(this), ROLL_COST);
        if (!success) revert TransferFailed();
        
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
            bool success = usdc.transfer(msg.sender, ROLL_PAYOUT);
            if (!success) revert TransferFailed();
        }
        
        emit RollRevealed(msg.sender, won, won ? ROLL_PAYOUT : 0);
    }

    /* ========== VIEW FUNCTIONS ========== */
    
    /// @notice Total USDC in contract
    function totalPool() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
    
    /// @notice Effective pool = total minus pending withdrawal value
    function effectivePool() public view returns (uint256) {
        uint256 pool = usdc.balanceOf(address(this));
        uint256 supply = totalSupply();
        
        if (supply == 0 || totalPendingShares == 0) return pool;
        
        uint256 pendingValue = (totalPendingShares * pool) / supply;
        return pool > pendingValue ? pool - pendingValue : 0;
    }
    
    /// @notice Current USDC value per HOUSE share (18 decimal precision)
    function sharePrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18; // 1 USDC (in 18 decimals) before first deposit
        
        // Returns price with 18 decimal precision
        // pool is 6 decimals, supply is 18 decimals
        // (pool * 1e18) / supply gives price in 6 decimal USDC terms
        return (usdc.balanceOf(address(this)) * 1e18) / supply;
    }
    
    /// @notice USDC value of an LP's shares
    function usdcValue(address lp) external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (balanceOf(lp) * usdc.balanceOf(address(this))) / supply;
    }
    
    /// @notice Whether the pool can accept new rolls
    function canRoll() external view returns (bool) {
        return effectivePool() >= MIN_RESERVE + ROLL_PAYOUT;
    }
    
    /// @notice Get withdrawal request details for an LP
    function getWithdrawalRequest(address lp) external view returns (
        uint256 shares,
        uint256 unlockTime,
        uint256 expiryTime,
        bool canWithdraw,
        bool isExpired
    ) {
        WithdrawalRequest memory req = withdrawals[lp];
        shares = req.shares;
        unlockTime = req.unlockTime;
        expiryTime = req.expiryTime;
        canWithdraw = req.shares > 0 && 
                      block.timestamp >= req.unlockTime && 
                      block.timestamp <= req.expiryTime;
        isExpired = req.shares > 0 && block.timestamp > req.expiryTime;
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
