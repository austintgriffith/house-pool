// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Credits-USDC DEX
/// @notice A simple AMM DEX for swapping Credits tokens with USDC
/// @dev Handles different decimal tokens (Credits: 18, USDC: 6)
contract CreditsDex {
    /* ========== CUSTOM ERRORS ========== */
    error InitError();
    error TokenTransferError(address _token);
    error ZeroQuantityError();
    error SlippageError();
    error InsufficientLiquidityError(uint256 _liquidityAvailable);

    /* ========== STATE VARS ========== */

    IERC20 public creditToken;
    IERC20 public assetToken; // USDC

    uint256 public totalLiquidity;
    mapping(address => uint256) public liquidity;

    /// @notice House buffer for gambling - not used in swap pricing
    uint256 public usdcExcess;
    /// @notice Maximum USDC that can be held in excess before overflowing to reserves
    uint256 public constant EXCESS_CAP = 100 * 10**6; // 100 USDC (6 decimals)

    /* ========== GAMBLING CONSTANTS ========== */
    
    /// @notice Cost to roll (1 USDC)
    uint256 public constant ROLL_COST = 1 * 10**6;
    /// @notice Payout on win (10 USDC)
    uint256 public constant ROLL_PAYOUT = 10 * 10**6;
    /// @notice Modulo for win calculation (1 in 11 chance = ~9% win rate, ~9% house edge)
    uint256 public constant ROLL_MODULO = 11;

    /* ========== EVENTS ========== */

    event TokenSwap(
        address indexed _user,
        uint256 _tradeDirection,
        uint256 _tokensSwapped,
        uint256 _tokensReceived
    );
    event LiquidityProvided(
        address indexed _user,
        uint256 _liquidityMinted,
        uint256 _creditTokenAdded,
        uint256 _assetTokenAdded
    );
    event LiquidityRemoved(
        address indexed _user,
        uint256 _liquidityAmount,
        uint256 _creditTokenAmount,
        uint256 _assetTokenAmount
    );
    event Roll(
        address indexed _player,
        bool _won,
        uint256 _payout
    );

    /* ========== CONSTRUCTOR ========== */
    constructor(address _creditToken, address _assetToken) {
        creditToken = IERC20(_creditToken);
        assetToken = IERC20(_assetToken);
    }

    /// @notice Initializes liquidity in the DEX with specified amounts of each token
    /// @dev User should approve DEX contract as spender for both tokens before calling init
    /// @param creditTokenAmount Number of credit tokens to initialize with
    /// @param assetReservesAmount Number of asset tokens (USDC) for reserves (determines initial price)
    /// @param assetExcessAmount Number of asset tokens (USDC) for house excess buffer
    /// @return totalLiquidity The initial liquidity amount (uses credit token amount as base)
    function init(
        uint256 creditTokenAmount, 
        uint256 assetReservesAmount, 
        uint256 assetExcessAmount
    ) public returns (uint256) {
        if (totalLiquidity != 0) revert InitError();
        if (creditTokenAmount == 0 || assetReservesAmount == 0) revert ZeroQuantityError();

        // Use credit token amount as the liquidity base
        totalLiquidity = creditTokenAmount;
        liquidity[msg.sender] = creditTokenAmount;

        // Set initial excess (capped at EXCESS_CAP)
        usdcExcess = assetExcessAmount > EXCESS_CAP ? EXCESS_CAP : assetExcessAmount;

        // Transfer credit tokens to the contract
        bool creditTokenTransferred = creditToken.transferFrom(
            msg.sender,
            address(this),
            creditTokenAmount
        );
        if (!creditTokenTransferred) revert TokenTransferError(address(creditToken));

        // Transfer total asset tokens (reserves + excess) to the contract
        uint256 totalAssetAmount = assetReservesAmount + assetExcessAmount;
        bool assetTokenTransferred = assetToken.transferFrom(
            msg.sender,
            address(this),
            totalAssetAmount
        );
        if (!assetTokenTransferred) revert TokenTransferError(address(assetToken));

        emit LiquidityProvided(msg.sender, creditTokenAmount, creditTokenAmount, totalAssetAmount);

        return totalLiquidity;
    }

    /// @notice Returns yOutput for xInput using constant product formula with 0.3% fee
    /// @param xInput Amount of token X to be sold
    /// @param xReserves Amount of liquidity for token X
    /// @param yReserves Amount of liquidity for token Y
    /// @return yOutput Amount of token Y that can be purchased
    function price(
        uint256 xInput,
        uint256 xReserves,
        uint256 yReserves
    ) public pure returns (uint256 yOutput) {
        uint256 xInputWithFee = xInput * 997;
        uint256 numerator = xInputWithFee * yReserves;
        uint256 denominator = (xReserves * 1000) + xInputWithFee;
        return numerator / denominator;
    }

    function getAssetAddr() external view returns (address) {
        return address(assetToken);
    }

    function getCreditAddr() external view returns (address) {
        return address(creditToken);
    }

    /// @notice Get credit reserves in the DEX
    function getCreditReserves() external view returns (uint256) {
        return creditToken.balanceOf(address(this));
    }

    /// @notice Get total asset (USDC) balance in the DEX (reserves + excess)
    /// @dev For pricing, use getUsdcReserves() instead
    function getAssetReserves() external view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    /// @notice Helper function to get assetOut from a specified creditIn
    /// @dev Uses USDC reserves only (excludes excess) for pricing
    /// @param creditIn Amount of credits to calculate assetToken price
    /// @return assetOut Amount of assets tradable for 'creditIn' amount of credits
    function creditInPrice(uint256 creditIn) external view returns (uint256 assetOut) {
        uint256 credReserves = creditToken.balanceOf(address(this));
        uint256 assetReserves = getUsdcReserves(); // excludes excess
        return price(creditIn, credReserves, assetReserves);
    }

    /// @notice Helper function to get creditOut from a specified assetIn
    /// @dev Uses USDC reserves only (excludes excess) for pricing
    /// @param assetIn Amount of assets to calculate creditToken price
    /// @return creditOut Amount of credits tradable for 'assetIn' amount of assets
    function assetInPrice(uint256 assetIn) external view returns (uint256 creditOut) {
        uint256 assetReserves = getUsdcReserves(); // excludes excess
        uint256 creditReserves = creditToken.balanceOf(address(this));
        return price(assetIn, assetReserves, creditReserves);
    }

    /// @notice Helper function to get assetIn required for a specified creditOut
    /// @dev Uses USDC reserves only (excludes excess) for pricing
    /// @param creditOut Amount of credit the user wishes to receive
    /// @return assetIn Amount of asset necessary to receive creditOut
    function creditOutPrice(uint256 creditOut) external view returns (uint256 assetIn) {
        uint256 assetReserves = getUsdcReserves(); // excludes excess
        uint256 creditReserves = creditToken.balanceOf(address(this));

        if (creditOut >= creditReserves) revert InsufficientLiquidityError(creditReserves);

        uint256 numerator = assetReserves * creditOut * 1000;
        uint256 denominator = (creditReserves - creditOut) * 997;
        return (numerator / denominator) + 1;
    }

    /// @notice Helper function to get creditIn required for a specified assetOut
    /// @dev Uses USDC reserves only (excludes excess) for pricing. Swaps can only take from reserves.
    /// @param assetOut Amount of asset the user wishes to receive
    /// @return creditIn Amount of credit necessary to receive assetOut
    function assetOutPrice(uint256 assetOut) external view returns (uint256 creditIn) {
        uint256 assetReserves = getUsdcReserves(); // excludes excess - swaps can't touch excess
        uint256 creditReserves = creditToken.balanceOf(address(this));

        if (assetOut >= assetReserves) revert InsufficientLiquidityError(assetReserves);

        uint256 numerator = creditReserves * assetOut * 1000;
        uint256 denominator = (assetReserves - assetOut) * 997;
        return (numerator / denominator) + 1;
    }

    /// @notice Returns amount of liquidity provided by an address
    /// @param _user The address to check the liquidity of
    /// @return Amount of liquidity _user has provided
    function getLiquidity(address _user) public view returns (uint256) {
        return liquidity[_user];
    }

    /* ========== EXCESS MANAGEMENT ========== */

    /// @notice Get USDC reserves used for pricing (excludes excess)
    /// @return The amount of USDC in reserves (not including house excess)
    function getUsdcReserves() public view returns (uint256) {
        return assetToken.balanceOf(address(this)) - usdcExcess;
    }

    /// @notice Get total USDC in contract (reserves + excess)
    /// @return The total amount of USDC held by the contract
    function getTotalUsdc() public view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    /// @notice Get current excess amount
    /// @return The amount of USDC in the house excess buffer
    function getExcess() public view returns (uint256) {
        return usdcExcess;
    }

    /// @notice Preview how much USDC is required for a given credit deposit
    /// @param creditAmount The number of credits to deposit
    /// @return assetRequired The amount of USDC required
    function previewDeposit(uint256 creditAmount) public view returns (uint256 assetRequired) {
        uint256 creditTokenReserve = creditToken.balanceOf(address(this));
        uint256 totalAssetBalance = assetToken.balanceOf(address(this));
        return (creditAmount * totalAssetBalance) / creditTokenReserve;
    }

    /// @notice Internal helper to add USDC - fills excess first, overflow to reserves
    /// @param amount The amount of USDC being added
    function _addUsdc(uint256 amount) internal {
        uint256 room = EXCESS_CAP > usdcExcess ? EXCESS_CAP - usdcExcess : 0;
        uint256 toExcess = amount < room ? amount : room;
        usdcExcess += toExcess;
        // Remainder stays in balance as reserves (already transferred)
    }

    /// @notice Internal helper to remove USDC - drains excess first, then reserves
    /// @param amount The amount of USDC being removed
    function _removeUsdc(uint256 amount) internal {
        uint256 fromExcess = amount < usdcExcess ? amount : usdcExcess;
        usdcExcess -= fromExcess;
        // Remainder comes from reserves (balance)
    }

    /* ========== GAMBLING INFRASTRUCTURE ========== */

    /// @notice Process a roll payment (USDC goes to excess first, then reserves)
    /// @dev Called when player pays to roll
    /// @param amount The USDC amount paid to roll
    function _processRollPayment(uint256 amount) internal {
        _addUsdc(amount);
    }

    /// @notice Process a win payout (drains excess first, then reserves)
    /// @dev Called when player wins
    /// @param amount The USDC amount won
    function _processWinPayout(uint256 amount) internal {
        _removeUsdc(amount);
    }

    /// @notice Roll the dice! Pay 1 USDC for a chance to win 10 USDC
    /// @dev Uses previous block hash for randomness - GAMEABLE, for testing only!
    ///      Win probability: 1/11 (~9%), House edge: ~9%
    ///      Payments go to excess first, overflows to reserves.
    ///      Payouts come from excess first, then reserves if needed.
    /// @return won Whether the player won
    function roll() external returns (bool won) {
        // Transfer payment from player
        bool paymentReceived = assetToken.transferFrom(msg.sender, address(this), ROLL_COST);
        if (!paymentReceived) revert TokenTransferError(address(assetToken));
        
        // Process payment through excess system
        _processRollPayment(ROLL_COST);
        
        // Gameable randomness (for testing only - DO NOT USE IN PRODUCTION)
        uint256 random = uint256(blockhash(block.number - 1));
        won = (random % ROLL_MODULO) == 0;
        
        if (won) {
            // Process payout through excess system (drains excess first, then reserves)
            _processWinPayout(ROLL_PAYOUT);
            
            // Transfer winnings to player
            bool payoutSent = assetToken.transfer(msg.sender, ROLL_PAYOUT);
            if (!payoutSent) revert TokenTransferError(address(assetToken));
        }
        
        emit Roll(msg.sender, won, won ? ROLL_PAYOUT : 0);
    }

    /* ========== SWAP FUNCTIONS ========== */

    /// @notice Trades creditTokens for assetTokens (USDC)
    /// @dev Uses USDC reserves only for pricing. Swaps do not touch excess.
    /// @param tokensIn The number of credit tokens to be sold
    /// @param minTokensBack The minimum number of asset tokens to accept (slippage protection)
    /// @return tokenOutput The number of asset tokens received
    function creditToAsset(
        uint256 tokensIn,
        uint256 minTokensBack
    ) public returns (uint256 tokenOutput) {
        if (tokensIn == 0) revert ZeroQuantityError();
        uint256 creditTokenReserve = creditToken.balanceOf(address(this));
        uint256 assetTokenReserve = getUsdcReserves(); // excludes excess

        tokenOutput = price(tokensIn, creditTokenReserve, assetTokenReserve);
        if (tokenOutput < minTokensBack) revert SlippageError();
        if (tokenOutput > assetTokenReserve) revert InsufficientLiquidityError(assetTokenReserve);

        bool creditTokenTransferred = creditToken.transferFrom(
            msg.sender,
            address(this),
            tokensIn
        );
        if (!creditTokenTransferred) revert TokenTransferError(address(creditToken));

        bool assetTokenTransferred = assetToken.transfer(msg.sender, tokenOutput);
        if (!assetTokenTransferred) revert TokenTransferError(address(assetToken));

        emit TokenSwap(msg.sender, 0, tokensIn, tokenOutput);
    }

    /// @notice Trades assetTokens (USDC) for creditTokens
    /// @dev Uses USDC reserves only for pricing. Incoming USDC goes to reserves (not excess).
    /// @param tokensIn The number of asset tokens to be sold
    /// @param minTokensBack The minimum number of credit tokens to accept (slippage protection)
    /// @return tokenOutput The number of credit tokens received
    function assetToCredit(
        uint256 tokensIn,
        uint256 minTokensBack
    ) public returns (uint256 tokenOutput) {
        if (tokensIn == 0) revert ZeroQuantityError();
        uint256 assetTokenReserve = getUsdcReserves(); // excludes excess
        uint256 creditTokenReserve = creditToken.balanceOf(address(this));

        tokenOutput = price(tokensIn, assetTokenReserve, creditTokenReserve);
        if (tokenOutput < minTokensBack) revert SlippageError();

        bool assetTokenTransferred = assetToken.transferFrom(
            msg.sender,
            address(this),
            tokensIn
        );
        if (!assetTokenTransferred) revert TokenTransferError(address(assetToken));

        // Note: incoming USDC goes directly to reserves (not routed through _addUsdc)
        // because swaps should only affect reserves, not excess

        bool creditTokenTransferred = creditToken.transfer(msg.sender, tokenOutput);
        if (!creditTokenTransferred) revert TokenTransferError(address(creditToken));

        emit TokenSwap(msg.sender, 1, tokensIn, tokenOutput);
    }

    /// @notice Allows user to provide liquidity to the DEX
    /// @dev USDC is deposited at ratio of total pool (reserves + excess).
    ///      USDC fills excess first (up to cap), then overflows to reserves.
    ///      This means LP deposits when excess is full will increase CREDITS price.
    /// @param creditTokenDeposited The number of credit tokens to deposit
    /// @param maxAssetTokens Maximum USDC willing to deposit (slippage protection, 0 = no limit)
    /// @return liquidityMinted The amount of liquidity tokens minted
    function deposit(uint256 creditTokenDeposited, uint256 maxAssetTokens) public returns (uint256 liquidityMinted) {
        if (creditTokenDeposited == 0) revert ZeroQuantityError();

        uint256 creditTokenReserve = creditToken.balanceOf(address(this));
        uint256 totalAssetBalance = assetToken.balanceOf(address(this)); // reserves + excess
        
        // Calculate required asset tokens based on TOTAL pool ratio (reserves + excess)
        uint256 assetTokenDeposited = (creditTokenDeposited * totalAssetBalance) / creditTokenReserve;

        // Slippage protection - revert if required USDC exceeds max
        if (maxAssetTokens > 0 && assetTokenDeposited > maxAssetTokens) revert SlippageError();

        liquidityMinted = (creditTokenDeposited * totalLiquidity) / creditTokenReserve;

        liquidity[msg.sender] += liquidityMinted;
        totalLiquidity += liquidityMinted;

        bool creditTokenTransferred = creditToken.transferFrom(
            msg.sender,
            address(this),
            creditTokenDeposited
        );
        if (!creditTokenTransferred) revert TokenTransferError(address(creditToken));

        bool assetTokenTransferred = assetToken.transferFrom(
            msg.sender,
            address(this),
            assetTokenDeposited
        );
        if (!assetTokenTransferred) revert TokenTransferError(address(assetToken));

        // Route USDC through excess system - fills excess first, overflow to reserves
        _addUsdc(assetTokenDeposited);

        emit LiquidityProvided(
            msg.sender,
            liquidityMinted,
            creditTokenDeposited,
            assetTokenDeposited
        );
    }

    /// @notice Allows users to withdraw liquidity
    /// @dev Returns proportional share of total pool (reserves + excess).
    ///      Excess is reduced proportionally when withdrawing.
    /// @param amount The amount of liquidity to withdraw
    /// @return creditTokenAmount The number of credit tokens received
    /// @return assetTokenAmount The number of asset tokens received (from reserves + excess)
    function withdraw(
        uint256 amount
    ) public returns (uint256 creditTokenAmount, uint256 assetTokenAmount) {
        if (liquidity[msg.sender] < amount)
            revert InsufficientLiquidityError(liquidity[msg.sender]);

        uint256 creditTokenReserve = creditToken.balanceOf(address(this));
        uint256 totalAssetBalance = assetToken.balanceOf(address(this)); // reserves + excess

        creditTokenAmount = (amount * creditTokenReserve) / totalLiquidity;
        assetTokenAmount = (amount * totalAssetBalance) / totalLiquidity;

        // Calculate proportional excess reduction
        uint256 excessReduction = (amount * usdcExcess) / totalLiquidity;
        usdcExcess -= excessReduction;

        liquidity[msg.sender] -= amount;
        totalLiquidity -= amount;

        bool creditTokenSent = creditToken.transfer(msg.sender, creditTokenAmount);
        if (!creditTokenSent) revert TokenTransferError(address(creditToken));
        
        bool assetTokenSent = assetToken.transfer(msg.sender, assetTokenAmount);
        if (!assetTokenSent) revert TokenTransferError(address(assetToken));

        emit LiquidityRemoved(msg.sender, amount, creditTokenAmount, assetTokenAmount);
    }
}

