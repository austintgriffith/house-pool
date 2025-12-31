// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/HousePool.sol";
import "../contracts/DiceGame.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple mock USDC for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    
    function decimals() public pure override returns (uint8) { return 6; }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract HousePoolTest is Test {
    HousePool public housePool;
    DiceGame public diceGame;
    MockUSDC public usdc;
    
    address public lp1 = address(2);
    address public lp2 = address(3);
    address public player1 = address(4);
    address public player2 = address(5);
    
    uint256 constant INITIAL_USDC = 10_000 * 10**6; // 10k USDC each
    
    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();
        
        // Deploy DiceGame (which deploys HousePool internally)
        diceGame = new DiceGame(address(usdc));
        housePool = diceGame.housePool();
        
        // Distribute USDC to test accounts
        usdc.mint(lp1, INITIAL_USDC);
        usdc.mint(lp2, INITIAL_USDC);
        usdc.mint(player1, INITIAL_USDC);
        usdc.mint(player2, INITIAL_USDC);
        
        // Approve HousePool for LP accounts (for deposits)
        vm.prank(lp1);
        usdc.approve(address(housePool), type(uint256).max);
        
        vm.prank(lp2);
        usdc.approve(address(housePool), type(uint256).max);
        
        // Approve HousePool for player accounts (for receivePayment)
        vm.prank(player1);
        usdc.approve(address(housePool), type(uint256).max);
        
        vm.prank(player2);
        usdc.approve(address(housePool), type(uint256).max);
    }

    /* ========== DEPLOYMENT TESTS ========== */
    
    function test_Deployment() public view {
        assertEq(address(housePool.game()), address(diceGame));
        assertEq(address(housePool.usdc()), address(usdc));
        assertEq(address(diceGame.housePool()), address(housePool));
        assertEq(address(diceGame.usdc()), address(usdc));
    }

    /* ========== DEPOSIT TESTS ========== */
    
    function test_FirstDeposit() public {
        uint256 depositAmount = 100 * 10**6; // 100 USDC
        
        vm.prank(lp1);
        uint256 shares = housePool.deposit(depositAmount);
        
        // First deposit: 1 USDC = 1e12 HOUSE (scaling 6 → 18 decimals)
        assertEq(shares, depositAmount * 1e12);
        assertEq(housePool.balanceOf(lp1), shares);
        assertEq(housePool.totalPool(), depositAmount);
    }
    
    function test_FirstDeposit_MinimumEnforced() public {
        vm.prank(lp1);
        vm.expectRevert(HousePool.InsufficientPool.selector);
        housePool.deposit(0.5 * 10**6); // 0.5 USDC, below minimum
    }
    
    function test_SubsequentDeposit_ProportionalShares() public {
        // First deposit: 100 USDC
        vm.prank(lp1);
        housePool.deposit(100 * 10**6);
        
        // Second deposit: 50 USDC (should get 50% of existing shares)
        vm.prank(lp2);
        uint256 shares2 = housePool.deposit(50 * 10**6);
        
        // LP2 should have half as many shares as LP1
        assertEq(shares2, housePool.balanceOf(lp1) / 2);
    }
    
    function test_Deposit_ZeroAmount_Reverts() public {
        vm.prank(lp1);
        vm.expectRevert(HousePool.ZeroAmount.selector);
        housePool.deposit(0);
    }

    /* ========== WITHDRAWAL TESTS ========== */
    
    function test_RequestWithdrawal() public {
        // Setup: deposit first
        vm.prank(lp1);
        uint256 shares = housePool.deposit(200 * 10**6);
        
        // Request withdrawal
        vm.prank(lp1);
        housePool.requestWithdrawal(shares);
        
        (uint256 reqShares, uint256 unlockTime, uint256 expiryTime, bool canWithdraw, bool isExpired) = 
            housePool.getWithdrawalRequest(lp1);
        
        assertEq(reqShares, shares);
        assertEq(unlockTime, block.timestamp + 10); // 10 second cooldown
        assertEq(expiryTime, unlockTime + 60);       // 1 minute window
        assertFalse(canWithdraw); // Can't withdraw yet
        assertFalse(isExpired);
        assertEq(housePool.totalPendingShares(), shares);
    }
    
    function test_Withdraw_AfterCooldown() public {
        // Setup: deposit 300 USDC
        vm.prank(lp1);
        housePool.deposit(300 * 10**6);
        
        // Calculate shares for 200 USDC worth
        uint256 totalShares = housePool.balanceOf(lp1);
        uint256 sharesToWithdraw = (totalShares * 200) / 300; // ~2/3 of shares
        
        // Request partial withdrawal
        vm.prank(lp1);
        housePool.requestWithdrawal(sharesToWithdraw);
        
        // Fast forward past cooldown (10 seconds) but within window (1 minute)
        vm.warp(block.timestamp + 11);
        
        uint256 usdcBefore = usdc.balanceOf(lp1);
        uint256 poolBefore = housePool.totalPool();
        
        vm.prank(lp1);
        uint256 usdcOut = housePool.withdraw();
        
        // Should get back ~200 USDC
        assertApproxEqAbs(usdcOut, 200 * 10**6, 1); // Within 1 wei
        assertEq(usdc.balanceOf(lp1), usdcBefore + usdcOut);
        assertEq(housePool.totalPool(), poolBefore - usdcOut);
        assertEq(housePool.totalPendingShares(), 0);
    }
    
    function test_Withdraw_BeforeCooldown_Reverts() public {
        vm.prank(lp1);
        housePool.deposit(300 * 10**6);
        
        // Request partial withdrawal
        uint256 sharesToWithdraw = (housePool.balanceOf(lp1) * 200) / 300;
        vm.prank(lp1);
        housePool.requestWithdrawal(sharesToWithdraw);
        
        // Try to withdraw immediately - should fail because cooldown not passed
        vm.prank(lp1);
        vm.expectRevert(HousePool.WithdrawalNotReady.selector);
        housePool.withdraw();
    }
    
    function test_Withdraw_AfterExpiry_Reverts() public {
        vm.prank(lp1);
        housePool.deposit(300 * 10**6);
        
        uint256 sharesToWithdraw = (housePool.balanceOf(lp1) * 200) / 300;
        vm.prank(lp1);
        housePool.requestWithdrawal(sharesToWithdraw);
        
        // Fast forward past expiry (10 seconds cooldown + 1 minute window + 1 second)
        vm.warp(block.timestamp + 10 + 60 + 1);
        
        vm.prank(lp1);
        vm.expectRevert(HousePool.WithdrawalExpired.selector);
        housePool.withdraw();
    }
    
    function test_CleanupExpiredWithdrawal() public {
        vm.prank(lp1);
        uint256 shares = housePool.deposit(200 * 10**6);
        
        vm.prank(lp1);
        housePool.requestWithdrawal(shares);
        
        assertEq(housePool.totalPendingShares(), shares);
        
        // Fast forward past expiry (10 seconds cooldown + 1 minute window + 1 second)
        vm.warp(block.timestamp + 10 + 60 + 1);
        
        // Anyone can cleanup
        vm.prank(player1);
        housePool.cleanupExpiredWithdrawal(lp1);
        
        // LP1 still has shares, but request is cleared
        assertEq(housePool.balanceOf(lp1), shares);
        assertEq(housePool.totalPendingShares(), 0);
        
        (uint256 reqShares,,,,) = housePool.getWithdrawalRequest(lp1);
        assertEq(reqShares, 0);
    }
    
    function test_CancelWithdrawal() public {
        vm.prank(lp1);
        uint256 shares = housePool.deposit(200 * 10**6);
        
        vm.prank(lp1);
        housePool.requestWithdrawal(shares);
        
        assertEq(housePool.totalPendingShares(), shares);
        
        vm.prank(lp1);
        housePool.cancelWithdrawal();
        
        assertEq(housePool.totalPendingShares(), 0);
        assertEq(housePool.balanceOf(lp1), shares); // Still has shares
    }

    /* ========== EFFECTIVE POOL TESTS ========== */
    
    function test_EffectivePool_ReducedByPendingWithdrawals() public {
        vm.prank(lp1);
        housePool.deposit(200 * 10**6);
        
        uint256 poolBefore = housePool.effectivePool();
        assertEq(poolBefore, 200 * 10**6);
        
        // Request half withdrawal
        uint256 halfShares = housePool.balanceOf(lp1) / 2;
        vm.prank(lp1);
        housePool.requestWithdrawal(halfShares);
        
        // Effective pool should be reduced by half
        uint256 poolAfter = housePool.effectivePool();
        assertEq(poolAfter, 100 * 10**6);
    }

    /* ========== GAME FUNCTIONS TESTS ========== */
    
    function test_ReceivePayment_OnlyGame() public {
        vm.prank(lp1);
        housePool.deposit(100 * 10**6);
        
        // Non-game caller should fail
        vm.prank(player1);
        vm.expectRevert(HousePool.Unauthorized.selector);
        housePool.receivePayment(player1, 1 * 10**6);
    }
    
    function test_Payout_OnlyGame() public {
        vm.prank(lp1);
        housePool.deposit(100 * 10**6);
        
        // Non-game caller should fail
        vm.prank(player1);
        vm.expectRevert(HousePool.Unauthorized.selector);
        housePool.payout(player1, 10 * 10**6);
    }

    /* ========== VIEW FUNCTIONS TESTS ========== */
    
    function test_SharePrice() public {
        // Before any deposits
        assertEq(housePool.sharePrice(), 1e18);
        
        // After deposit
        vm.prank(lp1);
        housePool.deposit(100 * 10**6);
        
        assertTrue(housePool.sharePrice() > 0);
    }
    
    function test_UsdcValue() public {
        vm.prank(lp1);
        housePool.deposit(100 * 10**6);
        
        // LP1's USDC value should equal their deposit
        assertEq(housePool.usdcValue(lp1), 100 * 10**6);
    }

    /* ========== FUZZ TESTS ========== */
    
    function testFuzz_Deposit(uint256 amount) public {
        // Bound to reasonable range (1 USDC to available balance)
        amount = bound(amount, 1 * 10**6, INITIAL_USDC);
        
        vm.prank(lp1);
        uint256 shares = housePool.deposit(amount);
        
        assertTrue(shares > 0);
        assertEq(housePool.totalPool(), amount);
    }
    
    function testFuzz_WithdrawalTiming(uint256 waitTime) public {
        vm.prank(lp1);
        uint256 shares = housePool.deposit(200 * 10**6);
        
        vm.prank(lp1);
        housePool.requestWithdrawal(shares);
        
        // Bound wait time (10 sec cooldown + 1 min window = 70 sec total)
        waitTime = bound(waitTime, 0, 5 minutes);
        vm.warp(block.timestamp + waitTime);
        
        (,,,bool canWithdraw, bool isExpired) = housePool.getWithdrawalRequest(lp1);
        
        if (waitTime < 10) {
            // Before cooldown
            assertFalse(canWithdraw);
            assertFalse(isExpired);
        } else if (waitTime <= 10 + 60) {
            // In withdrawal window
            assertTrue(canWithdraw);
            assertFalse(isExpired);
        } else {
            // After window expired
            assertFalse(canWithdraw);
            assertTrue(isExpired);
        }
    }
}

/* ========== DICE GAME TESTS ========== */

contract DiceGameTest is Test {
    HousePool public housePool;
    DiceGame public diceGame;
    MockUSDC public usdc;
    
    address public lp1 = address(2);
    address public player1 = address(4);
    address public player2 = address(5);
    
    uint256 constant INITIAL_USDC = 10_000 * 10**6;
    
    function setUp() public {
        usdc = new MockUSDC();
        diceGame = new DiceGame(address(usdc));
        housePool = diceGame.housePool();
        
        usdc.mint(lp1, INITIAL_USDC);
        usdc.mint(player1, INITIAL_USDC);
        usdc.mint(player2, INITIAL_USDC);
        
        // LPs approve HousePool for deposits
        vm.prank(lp1);
        usdc.approve(address(housePool), type(uint256).max);
        
        // Players approve HousePool for game payments
        vm.prank(player1);
        usdc.approve(address(housePool), type(uint256).max);
        
        vm.prank(player2);
        usdc.approve(address(housePool), type(uint256).max);
    }
    
    function test_CommitRoll() public {
        // Setup: LP deposits enough for gambling
        vm.prank(lp1);
        housePool.deposit(200 * 10**6);
        
        bytes32 secret = bytes32("my_secret_123");
        bytes32 commitment = keccak256(abi.encodePacked(secret));
        
        vm.prank(player1);
        diceGame.commitRoll(commitment);
        
        (bytes32 hash, uint256 blockNum, bool canReveal, bool isExpired) = 
            diceGame.getCommitment(player1);
        
        assertEq(hash, commitment);
        assertEq(blockNum, block.number);
        assertFalse(canReveal); // Can't reveal same block
        assertFalse(isExpired);
        
        // USDC transferred to pool (deposit + roll cost)
        assertEq(housePool.totalPool(), 200 * 10**6 + diceGame.ROLL_COST());
    }
    
    function test_CommitRoll_InsufficientPool_Reverts() public {
        // No deposits - pool is empty
        bytes32 secret = bytes32("my_secret");
        bytes32 commitment = keccak256(abi.encodePacked(secret));
        
        vm.prank(player1);
        vm.expectRevert(DiceGame.GameNotPlayable.selector);
        diceGame.commitRoll(commitment);
    }
    
    function test_RevealRoll_TooEarly_Reverts() public {
        vm.prank(lp1);
        housePool.deposit(200 * 10**6);
        
        bytes32 secret = bytes32("my_secret");
        bytes32 commitment = keccak256(abi.encodePacked(secret));
        
        vm.prank(player1);
        diceGame.commitRoll(commitment);
        
        // Try to reveal in same block - should fail
        vm.prank(player1);
        vm.expectRevert(DiceGame.TooEarly.selector);
        diceGame.revealRoll(secret);
    }
    
    function test_RevealRoll_AfterOneBlock_Success() public {
        vm.prank(lp1);
        housePool.deposit(200 * 10**6);
        
        bytes32 secret = bytes32("my_secret");
        bytes32 commitment = keccak256(abi.encodePacked(secret));
        
        vm.prank(player1);
        diceGame.commitRoll(commitment);
        
        // Advance 1 block - should now work
        vm.roll(block.number + 1);
        
        vm.prank(player1);
        diceGame.revealRoll(secret); // Should succeed
        
        // Commitment should be cleared
        (bytes32 hash,,,) = diceGame.getCommitment(player1);
        assertEq(hash, bytes32(0));
    }
    
    function test_RevealRoll_Success() public {
        vm.prank(lp1);
        housePool.deposit(200 * 10**6);
        
        bytes32 secret = bytes32("my_secret");
        bytes32 commitment = keccak256(abi.encodePacked(secret));
        
        vm.prank(player1);
        diceGame.commitRoll(commitment);
        
        // Advance 2 blocks
        vm.roll(block.number + 2);
        
        uint256 poolBefore = housePool.totalPool();
        
        vm.prank(player1);
        bool won = diceGame.revealRoll(secret);
        
        // Commitment should be cleared
        (bytes32 hash,,,) = diceGame.getCommitment(player1);
        assertEq(hash, bytes32(0));
        
        // Pool should change based on win/loss
        if (won) {
            assertEq(housePool.totalPool(), poolBefore - 10 * 10**6); // 10 USDC payout
        } else {
            assertEq(housePool.totalPool(), poolBefore); // No change (already received 1 USDC)
        }
    }
    
    function test_RevealRoll_TooLate_Reverts() public {
        vm.prank(lp1);
        housePool.deposit(200 * 10**6);
        
        bytes32 secret = bytes32("my_secret");
        bytes32 commitment = keccak256(abi.encodePacked(secret));
        
        vm.prank(player1);
        diceGame.commitRoll(commitment);
        
        // Advance 257 blocks (past the 256 block limit)
        vm.roll(block.number + 257);
        
        vm.prank(player1);
        vm.expectRevert(DiceGame.TooLate.selector);
        diceGame.revealRoll(secret);
    }
    
    function test_CheckRoll() public {
        vm.prank(lp1);
        housePool.deposit(200 * 10**6);
        
        bytes32 secret = bytes32("my_secret");
        bytes32 commitment = keccak256(abi.encodePacked(secret));
        
        vm.prank(player1);
        diceGame.commitRoll(commitment);
        
        // Can't check in same block
        (bool canCheck, bool isWinner) = diceGame.checkRoll(player1, secret);
        assertFalse(canCheck);
        
        // Advance 1 block
        vm.roll(block.number + 1);
        
        // Now can check
        (canCheck, isWinner) = diceGame.checkRoll(player1, secret);
        assertTrue(canCheck);
        
        // Wrong secret returns false for canCheck
        (canCheck, ) = diceGame.checkRoll(player1, bytes32("wrong"));
        assertFalse(canCheck);
        
        // Verify checkRoll matches actual reveal result
        vm.prank(player1);
        bool actualWon = diceGame.revealRoll(secret);
        assertEq(isWinner, actualWon);
    }
    
    function test_CheckRoll_TooLate() public {
        vm.prank(lp1);
        housePool.deposit(200 * 10**6);
        
        bytes32 secret = bytes32("my_secret");
        bytes32 commitment = keccak256(abi.encodePacked(secret));
        
        vm.prank(player1);
        diceGame.commitRoll(commitment);
        
        // Advance 257 blocks
        vm.roll(block.number + 257);
        
        // Can't check anymore (blockhash is 0)
        (bool canCheck, ) = diceGame.checkRoll(player1, secret);
        assertFalse(canCheck);
    }
    
    function test_RevealRoll_InvalidSecret_Reverts() public {
        vm.prank(lp1);
        housePool.deposit(200 * 10**6);
        
        bytes32 secret = bytes32("my_secret");
        bytes32 wrongSecret = bytes32("wrong_secret");
        bytes32 commitment = keccak256(abi.encodePacked(secret));
        
        vm.prank(player1);
        diceGame.commitRoll(commitment);
        
        vm.roll(block.number + 2);
        
        vm.prank(player1);
        vm.expectRevert(DiceGame.InvalidReveal.selector);
        diceGame.revealRoll(wrongSecret);
    }
    
    function test_CommitRoll_BlockedByPendingWithdrawals() public {
        // Deposit just above minimum threshold (MIN_RESERVE + ROLL_PAYOUT)
        uint256 minRequired = diceGame.MIN_RESERVE() + diceGame.ROLL_PAYOUT();
        vm.prank(lp1);
        housePool.deposit(minRequired + 1 * 10**6); // Just above threshold
        
        // Request withdrawal of most of it (99%)
        uint256 mostShares = (housePool.balanceOf(lp1) * 99) / 100;
        vm.prank(lp1);
        housePool.requestWithdrawal(mostShares);
        
        // Effective pool should now be below threshold
        assertTrue(housePool.effectivePool() < minRequired);
        
        // Should not be able to commit
        bytes32 commitment = keccak256(abi.encodePacked(bytes32("secret")));
        vm.prank(player1);
        vm.expectRevert(DiceGame.GameNotPlayable.selector);
        diceGame.commitRoll(commitment);
    }
    
    function test_CanPlay() public {
        // Empty pool - can't play
        assertFalse(diceGame.canPlay());
        
        // Deposit enough
        vm.prank(lp1);
        housePool.deposit(200 * 10**6);
        
        assertTrue(diceGame.canPlay());
    }

    /* ========== SHARE VALUE CONSISTENCY TESTS ========== */
    
    function test_ShareValue_PreservedAfterGamblingLoss() public {
        // LP deposits 200 USDC
        vm.prank(lp1);
        housePool.deposit(200 * 10**6);
        
        uint256 valueBeforeGambling = housePool.usdcValue(lp1);
        
        // Player commits and plays
        bytes32 secret = bytes32("will_probably_lose");
        bytes32 commitment = keccak256(abi.encodePacked(secret));
        
        vm.prank(player1);
        diceGame.commitRoll(commitment);
        
        vm.roll(block.number + 2);
        
        vm.prank(player1);
        bool won = diceGame.revealRoll(secret);
        
        uint256 valueAfterGambling = housePool.usdcValue(lp1);
        
        uint256 rollCost = diceGame.ROLL_COST();
        uint256 rollPayout = diceGame.ROLL_PAYOUT();
        
        if (won) {
            // Pool decreased by net payout (payout - cost)
            assertEq(valueAfterGambling, valueBeforeGambling - (rollPayout - rollCost));
        } else {
            // Pool increased by roll cost
            assertEq(valueAfterGambling, valueBeforeGambling + rollCost);
        }
    }
}
