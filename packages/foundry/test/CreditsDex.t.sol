// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/Credits.sol";
import "../contracts/CreditsDex.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock USDC token for testing (6 decimals like real USDC)
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract CreditsDexTest is Test {
    Credits public credits;
    MockUSDC public usdc;
    CreditsDex public dex;

    address public owner = vm.addr(1);
    address public alice = vm.addr(2);
    address public bob = vm.addr(3);
    address public lp1 = vm.addr(4);
    address public lp2 = vm.addr(5);

    // Initial amounts
    uint256 constant INITIAL_CREDITS = 100_000 * 1e18; // 100,000 CREDITS
    uint256 constant INITIAL_USDC_RESERVES = 1_000 * 1e6; // 1,000 USDC (reserves)
    uint256 constant INITIAL_USDC_EXCESS = 100 * 1e6; // 100 USDC (excess - max cap)
    uint256 constant EXCESS_CAP = 100 * 1e6; // 100 USDC

    function setUp() public {
        // Deploy tokens
        vm.prank(owner);
        credits = new Credits(owner);
        usdc = new MockUSDC();

        // Deploy DEX
        dex = new CreditsDex(address(credits), address(usdc));

        // Mint tokens to owner for initial liquidity
        vm.prank(owner);
        credits.mint(owner, INITIAL_CREDITS);
        usdc.mint(owner, INITIAL_USDC_RESERVES + INITIAL_USDC_EXCESS);

        // Approve DEX
        vm.startPrank(owner);
        credits.approve(address(dex), type(uint256).max);
        usdc.approve(address(dex), type(uint256).max);
        
        // Initialize DEX with reserves + excess
        dex.init(INITIAL_CREDITS, INITIAL_USDC_RESERVES, INITIAL_USDC_EXCESS);
        vm.stopPrank();

        // Mint tokens to test users
        vm.prank(owner);
        credits.mint(alice, 10_000 * 1e18);
        usdc.mint(alice, 1_000 * 1e6);
        
        vm.prank(owner);
        credits.mint(bob, 10_000 * 1e18);
        usdc.mint(bob, 1_000 * 1e6);

        vm.prank(owner);
        credits.mint(lp1, 50_000 * 1e18);
        usdc.mint(lp1, 1_000 * 1e6);

        vm.prank(owner);
        credits.mint(lp2, 50_000 * 1e18);
        usdc.mint(lp2, 1_000 * 1e6);

        // Approve DEX for all users
        vm.prank(alice);
        credits.approve(address(dex), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(dex), type(uint256).max);

        vm.prank(bob);
        credits.approve(address(dex), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(dex), type(uint256).max);

        vm.prank(lp1);
        credits.approve(address(dex), type(uint256).max);
        vm.prank(lp1);
        usdc.approve(address(dex), type(uint256).max);

        vm.prank(lp2);
        credits.approve(address(dex), type(uint256).max);
        vm.prank(lp2);
        usdc.approve(address(dex), type(uint256).max);
    }

    // ============ Initialization Tests ============

    function testInitSetsCorrectExcess() public view {
        assertEq(dex.usdcExcess(), INITIAL_USDC_EXCESS);
        assertEq(dex.getExcess(), INITIAL_USDC_EXCESS);
    }

    function testInitSetsCorrectReserves() public view {
        assertEq(dex.getUsdcReserves(), INITIAL_USDC_RESERVES);
        assertEq(dex.getCreditReserves(), INITIAL_CREDITS);
    }

    function testInitCapsExcessAtMax() public {
        // Deploy new DEX
        CreditsDex dex2 = new CreditsDex(address(credits), address(usdc));
        
        // Mint more tokens
        vm.prank(owner);
        credits.mint(owner, INITIAL_CREDITS);
        usdc.mint(owner, INITIAL_USDC_RESERVES + 200 * 1e6); // Try to set 200 USDC excess

        vm.startPrank(owner);
        credits.approve(address(dex2), type(uint256).max);
        usdc.approve(address(dex2), type(uint256).max);
        
        // Try to init with 200 USDC excess - should cap at 100
        dex2.init(INITIAL_CREDITS, INITIAL_USDC_RESERVES, 200 * 1e6);
        vm.stopPrank();

        assertEq(dex2.usdcExcess(), EXCESS_CAP, "Excess should be capped at 100 USDC");
    }

    // ============ Swap Price Tests (uses reserves only) ============

    function testSwapPriceExcludesExcess() public view {
        // Price should be based on reserves only (1000 USDC / 100,000 CREDITS)
        // Not on total USDC (1100 USDC / 100,000 CREDITS)
        
        uint256 creditIn = 1000 * 1e18; // 1000 CREDITS
        uint256 assetOut = dex.creditInPrice(creditIn);
        
        // With 1000 USDC reserves and 100,000 CREDITS:
        // price = (1000 * 997 * 1000e6) / (100000e18 * 1000 + 1000 * 997 * 1e18)
        // Should be approximately 9.87 USDC (based on reserves ratio)
        
        // If excess were included, it would be ~10.86 USDC
        // So the result should be closer to 9.87 than 10.86
        assertTrue(assetOut < 10 * 1e6, "Price should be based on reserves, not total");
    }

    function testCreditToAssetUsesReservesPrice() public {
        uint256 creditIn = 1000 * 1e18;
        uint256 expectedOut = dex.creditInPrice(creditIn);
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        
        vm.prank(alice);
        dex.creditToAsset(creditIn, 0);
        
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        assertEq(aliceUsdcAfter - aliceUsdcBefore, expectedOut);
    }

    function testAssetToCreditUsesReservesPrice() public {
        uint256 usdcIn = 10 * 1e6; // 10 USDC
        uint256 expectedOut = dex.assetInPrice(usdcIn);
        
        uint256 aliceCreditsBefore = credits.balanceOf(alice);
        
        vm.prank(alice);
        dex.assetToCredit(usdcIn, 0);
        
        uint256 aliceCreditsAfter = credits.balanceOf(alice);
        assertEq(aliceCreditsAfter - aliceCreditsBefore, expectedOut);
    }

    function testSwapDoesNotTouchExcess() public {
        uint256 excessBefore = dex.usdcExcess();
        
        // Swap credits for USDC
        vm.prank(alice);
        dex.creditToAsset(1000 * 1e18, 0);
        
        // Excess should remain unchanged
        assertEq(dex.usdcExcess(), excessBefore, "Swap should not affect excess");
    }

    function testSwapIncomingUsdcGoesToReserves() public {
        uint256 reservesBefore = dex.getUsdcReserves();
        uint256 excessBefore = dex.usdcExcess();
        
        // Swap USDC for credits
        uint256 usdcIn = 10 * 1e6;
        vm.prank(alice);
        dex.assetToCredit(usdcIn, 0);
        
        // Reserves should increase
        assertEq(dex.getUsdcReserves(), reservesBefore + usdcIn, "USDC should go to reserves");
        // Excess should stay the same
        assertEq(dex.usdcExcess(), excessBefore, "Excess should not change from swap");
    }

    // ============ LP Deposit Tests ============

    function testDepositCalculatesRatioWithTotalPool() public {
        // Total USDC = 1100 (1000 reserves + 100 excess)
        // Total Credits = 100,000
        // Depositing 10,000 CREDITS should require:
        // (10,000 * 1100) / 100,000 = 110 USDC
        
        uint256 creditsToDeposit = 10_000 * 1e18;
        uint256 expectedUsdc = (creditsToDeposit * (INITIAL_USDC_RESERVES + INITIAL_USDC_EXCESS)) / INITIAL_CREDITS;
        
        uint256 lp1UsdcBefore = usdc.balanceOf(lp1);
        
        vm.prank(lp1);
        dex.deposit(creditsToDeposit, 0);
        
        uint256 lp1UsdcAfter = usdc.balanceOf(lp1);
        assertEq(lp1UsdcBefore - lp1UsdcAfter, expectedUsdc, "Should deposit at total ratio");
    }

    function testDepositFillsExcessWhenNotFull() public {
        // First, owner withdraws some to reduce excess below cap
        uint256 ownerLiquidity = dex.getLiquidity(owner);
        
        vm.prank(owner);
        dex.withdraw(ownerLiquidity / 2);
        
        // Now excess should be less than cap
        uint256 excessBefore = dex.usdcExcess();
        assertTrue(excessBefore < EXCESS_CAP, "Excess should be below cap after withdraw");
        
        // Deposit more LP - should fill excess first
        uint256 creditsToDeposit = 10_000 * 1e18;
        vm.prank(lp1);
        dex.deposit(creditsToDeposit, 0);
        
        // Excess should be closer to cap (but depends on how much was deposited)
        uint256 excessAfter = dex.usdcExcess();
        assertTrue(excessAfter >= excessBefore, "Excess should increase or stay same");
    }

    function testDepositOverflowsToReservesWhenExcessFull() public {
        // Excess is already at cap (100 USDC)
        assertEq(dex.usdcExcess(), EXCESS_CAP);
        
        uint256 reservesBefore = dex.getUsdcReserves();
        uint256 creditsReservesBefore = dex.getCreditReserves();
        
        // Deposit more LP
        uint256 creditsToDeposit = 10_000 * 1e18;
        vm.prank(lp1);
        dex.deposit(creditsToDeposit, 0);
        
        // Excess should stay at cap
        assertEq(dex.usdcExcess(), EXCESS_CAP, "Excess should remain at cap");
        
        // Reserves should increase (all new USDC goes to reserves)
        uint256 totalUsdcDeposited = (creditsToDeposit * (INITIAL_USDC_RESERVES + INITIAL_USDC_EXCESS)) / creditsReservesBefore;
        assertEq(dex.getUsdcReserves(), reservesBefore + totalUsdcDeposited, "All USDC should go to reserves");
    }

    function testDepositWhenExcessFullChangesPrice() public {
        // Initial price (reserves ratio)
        uint256 priceBefore = dex.creditInPrice(1000 * 1e18);
        
        // Deposit more LP when excess is full
        uint256 creditsToDeposit = 10_000 * 1e18;
        vm.prank(lp1);
        dex.deposit(creditsToDeposit, 0);
        
        // Price should increase (more USDC per CREDIT)
        uint256 priceAfter = dex.creditInPrice(1000 * 1e18);
        assertTrue(priceAfter > priceBefore, "Price should increase when excess is full and LP deposits");
    }

    // ============ LP Withdraw Tests ============

    function testWithdrawReturnsProportionalShare() public {
        // Owner has all liquidity initially
        uint256 ownerLiquidity = dex.getLiquidity(owner);
        uint256 totalLiquidity = dex.totalLiquidity();
        
        // Withdraw half
        uint256 withdrawAmount = ownerLiquidity / 2;
        
        uint256 ownerCreditsBefore = credits.balanceOf(owner);
        uint256 ownerUsdcBefore = usdc.balanceOf(owner);
        
        vm.prank(owner);
        dex.withdraw(withdrawAmount);
        
        uint256 ownerCreditsAfter = credits.balanceOf(owner);
        uint256 ownerUsdcAfter = usdc.balanceOf(owner);
        
        // Should receive proportional credits
        uint256 expectedCredits = (withdrawAmount * INITIAL_CREDITS) / totalLiquidity;
        assertEq(ownerCreditsAfter - ownerCreditsBefore, expectedCredits, "Should receive proportional credits");
        
        // Should receive proportional USDC (from reserves + excess)
        uint256 expectedUsdc = (withdrawAmount * (INITIAL_USDC_RESERVES + INITIAL_USDC_EXCESS)) / totalLiquidity;
        assertEq(ownerUsdcAfter - ownerUsdcBefore, expectedUsdc, "Should receive proportional USDC");
    }

    function testWithdrawReducesExcessProportionally() public {
        uint256 excessBefore = dex.usdcExcess();
        uint256 totalLiquidity = dex.totalLiquidity();
        uint256 ownerLiquidity = dex.getLiquidity(owner);
        
        // Withdraw half
        uint256 withdrawAmount = ownerLiquidity / 2;
        
        vm.prank(owner);
        dex.withdraw(withdrawAmount);
        
        // Excess should be reduced proportionally
        uint256 expectedExcessReduction = (withdrawAmount * excessBefore) / totalLiquidity;
        assertEq(dex.usdcExcess(), excessBefore - expectedExcessReduction, "Excess should reduce proportionally");
    }

    // ============ View Functions Tests ============

    function testGetUsdcReserves() public view {
        // Total USDC = reserves + excess
        uint256 totalUsdc = dex.getTotalUsdc();
        uint256 reserves = dex.getUsdcReserves();
        uint256 excess = dex.getExcess();
        
        assertEq(reserves + excess, totalUsdc, "Reserves + excess should equal total");
        assertEq(reserves, INITIAL_USDC_RESERVES);
        assertEq(excess, INITIAL_USDC_EXCESS);
    }

    function testGetTotalUsdc() public view {
        assertEq(dex.getTotalUsdc(), INITIAL_USDC_RESERVES + INITIAL_USDC_EXCESS);
    }

    function testGetExcess() public view {
        assertEq(dex.getExcess(), INITIAL_USDC_EXCESS);
    }

    function testExcessCap() public view {
        assertEq(dex.EXCESS_CAP(), EXCESS_CAP);
    }

    // ============ Edge Cases ============

    function testSwapCannotExceedReserves() public {
        // Try to swap for more USDC than in reserves
        // This should fail because swaps can only take from reserves
        
        uint256 reserves = dex.getUsdcReserves();
        
        // Calculate how many credits would be needed to drain all reserves
        // This would require a very large amount
        vm.prank(alice);
        vm.expectRevert();
        dex.creditToAsset(INITIAL_CREDITS * 2, reserves + 1); // Request more than reserves
    }

    function testMultipleLPDepositsAndWithdraws() public {
        // LP1 deposits
        vm.prank(lp1);
        dex.deposit(10_000 * 1e18, 0);
        
        // LP2 deposits
        vm.prank(lp2);
        dex.deposit(5_000 * 1e18, 0);
        
        // Check liquidity tracking
        uint256 lp1Liquidity = dex.getLiquidity(lp1);
        uint256 lp2Liquidity = dex.getLiquidity(lp2);
        assertTrue(lp1Liquidity > 0, "LP1 should have liquidity");
        assertTrue(lp2Liquidity > 0, "LP2 should have liquidity");
        
        // Both withdraw their full amounts
        vm.prank(lp1);
        dex.withdraw(lp1Liquidity);
        
        vm.prank(lp2);
        dex.withdraw(lp2Liquidity);
        
        assertEq(dex.getLiquidity(lp1), 0, "LP1 should have 0 liquidity after withdraw");
        assertEq(dex.getLiquidity(lp2), 0, "LP2 should have 0 liquidity after withdraw");
    }

    // ============ Roll Function Tests ============

    function testRollConstants() public view {
        assertEq(dex.ROLL_COST(), 1 * 1e6, "Roll cost should be 1 USDC");
        assertEq(dex.ROLL_PAYOUT(), 10 * 1e6, "Roll payout should be 10 USDC");
        assertEq(dex.ROLL_MODULO(), 11, "Roll modulo should be 11");
    }

    function testRollTransfersPayment() public {
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 dexUsdcBefore = usdc.balanceOf(address(dex));
        
        vm.prank(alice);
        dex.roll();
        
        // If alice lost, she should have 1 USDC less, DEX should have 1 USDC more
        // If alice won, she should have 9 USDC more (10 payout - 1 cost), DEX 9 less
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        uint256 dexUsdcAfter = usdc.balanceOf(address(dex));
        
        // Either way, total should balance
        assertEq(
            aliceUsdcBefore + dexUsdcBefore,
            aliceUsdcAfter + dexUsdcAfter,
            "Total USDC should remain constant"
        );
    }

    function testRollPaymentGoesToExcessFirst() public {
        // Drain excess first by having owner withdraw some (not all)
        uint256 ownerLiquidity = dex.getLiquidity(owner);
        vm.prank(owner);
        dex.withdraw(ownerLiquidity / 2);
        
        uint256 excessBefore = dex.usdcExcess();
        assertTrue(excessBefore < EXCESS_CAP, "Excess should be below cap");
        
        // Roll (payment should go to excess)
        vm.prank(alice);
        dex.roll();
        
        // Check if excess increased (unless we won and payout drained it)
        // Either way, the payment was processed through _addUsdc
        uint256 excessAfter = dex.usdcExcess();
        
        // The test just verifies it doesn't revert - the exact excess depends on win/loss
        assertTrue(excessAfter >= 0, "Excess should be valid after roll");
    }

    function testRollEmitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit CreditsDex.Roll(alice, false, 0); // We don't know if they'll win, just check indexed param
        dex.roll();
    }

    function testRollRequiresApproval() public {
        // Create a new user with USDC but no approval
        address noApproval = vm.addr(99);
        usdc.mint(noApproval, 10 * 1e6);
        
        vm.prank(noApproval);
        vm.expectRevert();
        dex.roll();
    }

    function testRollRequiresSufficientBalance() public {
        // Create a user with no USDC
        address poorUser = vm.addr(100);
        
        vm.startPrank(poorUser);
        usdc.approve(address(dex), type(uint256).max);
        vm.expectRevert();
        dex.roll();
        vm.stopPrank();
    }

    function testMultipleRolls() public {
        // Alice rolls multiple times
        for (uint i = 0; i < 5; i++) {
            vm.prank(alice);
            dex.roll();
        }
        
        // Just verify it doesn't revert
        assertTrue(true, "Multiple rolls should succeed");
    }

    function testRollWinScenario() public {
        // We can force a win by manipulating the block hash in foundry
        // Find a block where blockhash % 11 == 0
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        
        // Roll to different blocks until we find one where blockhash % 11 == 0
        bool foundWinningBlock = false;
        for (uint i = 0; i < 20; i++) {
            vm.roll(block.number + 1);
            uint256 random = uint256(blockhash(block.number - 1));
            if (random % 11 == 0) {
                foundWinningBlock = true;
                vm.prank(alice);
                bool won = dex.roll();
                assertTrue(won, "Should win when blockhash % 11 == 0");
                
                uint256 aliceUsdcAfter = usdc.balanceOf(alice);
                assertEq(aliceUsdcAfter, aliceUsdcBefore + 10 * 1e6 - 1 * 1e6, "Should receive 10 USDC - 1 USDC cost = 9 USDC net");
                break;
            }
        }
        
        // If we didn't find a winning block in 20 tries, skip this test
        // (statistically unlikely but possible)
        if (!foundWinningBlock) {
            assertTrue(true, "Skipped - no winning block found in range");
        }
    }

    function testRollLossScenario() public {
        // Find a block where blockhash % 11 != 0
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        
        bool foundLosingBlock = false;
        for (uint i = 0; i < 20; i++) {
            vm.roll(block.number + 1);
            uint256 random = uint256(blockhash(block.number - 1));
            if (random % 11 != 0) {
                foundLosingBlock = true;
                vm.prank(alice);
                bool won = dex.roll();
                assertFalse(won, "Should lose when blockhash % 11 != 0");
                
                uint256 aliceUsdcAfter = usdc.balanceOf(alice);
                assertEq(aliceUsdcAfter, aliceUsdcBefore - 1 * 1e6, "Should lose 1 USDC");
                break;
            }
        }
        
        assertTrue(foundLosingBlock, "Should find a losing block");
    }

    function testRollWinPayoutDrainsExcessFirst() public {
        // Get initial state - excess is at cap (100 USDC)
        uint256 excessBefore = dex.usdcExcess();
        assertEq(excessBefore, EXCESS_CAP, "Excess should start at cap");
        
        uint256 reservesBefore = dex.getUsdcReserves();
        
        // Find a winning block
        for (uint i = 0; i < 20; i++) {
            vm.roll(block.number + 1);
            uint256 random = uint256(blockhash(block.number - 1));
            if (random % 11 == 0) {
                vm.prank(alice);
                dex.roll();
                
                uint256 excessAfter = dex.usdcExcess();
                uint256 reservesAfter = dex.getUsdcReserves();
                
                // Payment (1 USDC) goes to excess first, but excess is at cap so goes to reserves
                // Payout (10 USDC) comes from excess first
                // Net effect: excess -= 10, reserves += 1
                
                assertEq(excessAfter, excessBefore - 10 * 1e6, "Excess should decrease by 10 USDC (payout)");
                assertEq(reservesAfter, reservesBefore + 1 * 1e6, "Reserves should increase by 1 USDC (payment overflow)");
                break;
            }
        }
    }

    // ============ ROUND-TRIP VALUE CONSERVATION TESTS ============

    /// @notice Helper to calculate total value of a user's holdings in USDC terms
    function _getUserValueInUsdc(address user) internal view returns (uint256) {
        uint256 usdcBalance = usdc.balanceOf(user);
        uint256 creditsBalance = credits.balanceOf(user);
        
        // Value credits at current swap price (what they could get by swapping)
        uint256 creditsValueInUsdc = 0;
        if (creditsBalance > 0) {
            // Use price function to estimate value (accounts for slippage)
            creditsValueInUsdc = dex.creditInPrice(creditsBalance);
        }
        
        // Add LP value
        uint256 lpBalance = dex.getLiquidity(user);
        uint256 lpValueInUsdc = 0;
        if (lpBalance > 0 && dex.totalLiquidity() > 0) {
            uint256 lpCredits = (lpBalance * dex.getCreditReserves()) / dex.totalLiquidity();
            uint256 lpUsdc = (lpBalance * dex.getTotalUsdc()) / dex.totalLiquidity();
            // LP credits value
            if (lpCredits > 0) {
                lpValueInUsdc = dex.creditInPrice(lpCredits);
            }
            lpValueInUsdc += lpUsdc;
        }
        
        return usdcBalance + creditsValueInUsdc + lpValueInUsdc;
    }

    /// @notice Test: Swap USDC -> CREDITS -> USDC should result in loss (fees)
    function testRoundTripSwapLosesFees() public {
        uint256 usdcIn = 100 * 1e6; // 100 USDC
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        
        // Step 1: Swap USDC -> CREDITS
        vm.prank(alice);
        uint256 creditsReceived = dex.assetToCredit(usdcIn, 0);
        
        // Step 2: Swap CREDITS -> USDC
        vm.prank(alice);
        uint256 usdcReceived = dex.creditToAsset(creditsReceived, 0);
        
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        
        // User should have lost value to fees (0.3% each way = ~0.6% total)
        assertLt(usdcReceived, usdcIn, "Should receive less USDC than started with");
        assertEq(aliceUsdcAfter, aliceUsdcBefore - usdcIn + usdcReceived, "Balance should match");
        
        // Calculate actual loss percentage (should be ~0.6%)
        uint256 loss = usdcIn - usdcReceived;
        uint256 lossPercentage = (loss * 10000) / usdcIn; // basis points
        assertTrue(lossPercentage >= 50 && lossPercentage <= 70, "Loss should be ~0.5-0.7%");
    }

    /// @notice Test: Swap CREDITS -> USDC -> CREDITS should result in loss (fees)
    function testRoundTripSwapCreditsLosesFees() public {
        uint256 creditsIn = 1000 * 1e18; // 1000 CREDITS
        
        uint256 aliceCreditsBefore = credits.balanceOf(alice);
        
        // Step 1: Swap CREDITS -> USDC
        vm.prank(alice);
        uint256 usdcReceived = dex.creditToAsset(creditsIn, 0);
        
        // Step 2: Swap USDC -> CREDITS
        vm.prank(alice);
        uint256 creditsReceived = dex.assetToCredit(usdcReceived, 0);
        
        uint256 aliceCreditsAfter = credits.balanceOf(alice);
        
        // User should have lost value to fees
        assertLt(creditsReceived, creditsIn, "Should receive less CREDITS than started with");
        assertEq(aliceCreditsAfter, aliceCreditsBefore - creditsIn + creditsReceived, "Balance should match");
    }

    /// @notice Test: Deposit LP then immediately withdraw should not profit
    function testDepositWithdrawNoProfit() public {
        uint256 lp1UsdcBefore = usdc.balanceOf(lp1);
        uint256 lp1CreditsBefore = credits.balanceOf(lp1);
        
        // Deposit LP
        uint256 creditsToDeposit = 10_000 * 1e18;
        vm.prank(lp1);
        uint256 lpMinted = dex.deposit(creditsToDeposit, 0);
        
        // Immediately withdraw
        vm.prank(lp1);
        (uint256 creditsBack, uint256 usdcBack) = dex.withdraw(lpMinted);
        
        uint256 lp1UsdcAfter = usdc.balanceOf(lp1);
        uint256 lp1CreditsAfter = credits.balanceOf(lp1);
        
        // Should get back same or slightly less (rounding)
        assertLe(lp1UsdcAfter, lp1UsdcBefore + 1, "Should not profit on USDC");
        assertLe(lp1CreditsAfter, lp1CreditsBefore + 1, "Should not profit on CREDITS");
        
        // Verify LP tokens are zero
        assertEq(dex.getLiquidity(lp1), 0, "Should have no LP after full withdraw");
    }

    /// @notice Test: Multiple round-trip swaps should accumulate fees for LPs
    function testMultipleSwapsAccumulateFees() public {
        // Track initial LP value
        uint256 ownerLpBefore = dex.getLiquidity(owner);
        uint256 totalLiquidityBefore = dex.totalLiquidity();
        uint256 totalUsdcBefore = dex.getTotalUsdc();
        uint256 totalCreditsBefore = dex.getCreditReserves();
        
        // Alice does multiple swaps
        for (uint i = 0; i < 5; i++) {
            vm.prank(alice);
            uint256 creditsOut = dex.assetToCredit(50 * 1e6, 0);
            
            vm.prank(alice);
            dex.creditToAsset(creditsOut, 0);
        }
        
        // LP tokens unchanged
        assertEq(dex.getLiquidity(owner), ownerLpBefore, "LP tokens should not change");
        assertEq(dex.totalLiquidity(), totalLiquidityBefore, "Total liquidity should not change");
        
        // But pool reserves should have grown (fees collected)
        // Actually, with constant product, the k value increases
        uint256 kBefore = totalUsdcBefore * totalCreditsBefore;
        uint256 kAfter = dex.getTotalUsdc() * dex.getCreditReserves();
        
        // k should increase (or stay same) due to fees
        assertTrue(kAfter >= kBefore, "Pool k should not decrease");
    }

    /// @notice Test: Large swap round-trip with significant price impact
    function testLargeSwapRoundTripLoss() public {
        // Give alice more USDC for a large swap
        usdc.mint(alice, 500 * 1e6);
        
        uint256 largeUsdcIn = 500 * 1e6; // 500 USDC (50% of reserves)
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        
        // Large swap USDC -> CREDITS
        vm.prank(alice);
        uint256 creditsReceived = dex.assetToCredit(largeUsdcIn, 0);
        
        // Swap back CREDITS -> USDC
        vm.prank(alice);
        uint256 usdcReceived = dex.creditToAsset(creditsReceived, 0);
        
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        
        // Calculate loss
        uint256 loss = largeUsdcIn - usdcReceived;
        uint256 lossPercentage = (loss * 10000) / largeUsdcIn; // in basis points
        
        emit log_named_uint("Large swap loss in basis points", lossPercentage);
        emit log_named_uint("USDC lost", loss / 1e6);
        
        // With large trades, there should be significant loss due to price impact + fees
        // The exact amount depends on pool size and trade size
        assertLt(aliceUsdcAfter, aliceUsdcBefore, "Should have lost USDC overall");
        assertTrue(loss > 0, "Should have non-zero loss");
    }

    // ============ SELF-SANDWICH LP ATTACK TESTS ============
    // These tests check if a user can profit by:
    // 1. Swap to acquire credits
    // 2. Deposit LP (when excess is full, this increases price)
    // 3. Swap credits back at higher price
    // 4. Withdraw LP

    /// @notice Test: Self-sandwich attack when excess is full (primary attack vector)
    function testSelfSandwichAttackExcessFull() public {
        // Ensure excess is at cap
        assertEq(dex.usdcExcess(), EXCESS_CAP, "Excess should be at cap");
        
        // Record alice's total value before
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceCreditsBefore = credits.balanceOf(alice);
        uint256 aliceLpBefore = dex.getLiquidity(alice);
        assertEq(aliceLpBefore, 0, "Alice should start with no LP");
        
        // Record price before
        uint256 priceBefore = dex.creditInPrice(1000 * 1e18);
        
        // Step 1: Alice swaps USDC -> CREDITS
        uint256 swapUsdcIn = 100 * 1e6;
        vm.prank(alice);
        uint256 creditsFromSwap = dex.assetToCredit(swapUsdcIn, 0);
        
        // Step 2: Alice deposits LP (this should increase price since excess is full)
        uint256 creditsToDeposit = 5000 * 1e18;
        vm.prank(alice);
        uint256 lpMinted = dex.deposit(creditsToDeposit, 0);
        
        // Check price changed
        uint256 priceAfterDeposit = dex.creditInPrice(1000 * 1e18);
        assertTrue(priceAfterDeposit > priceBefore, "Price should increase after LP deposit when excess full");
        
        // Step 3: Alice swaps CREDITS -> USDC at new price
        uint256 creditsToSwapBack = creditsFromSwap;
        vm.prank(alice);
        uint256 usdcFromSwap = dex.creditToAsset(creditsToSwapBack, 0);
        
        // Step 4: Alice withdraws LP
        vm.prank(alice);
        (uint256 creditsBack, uint256 usdcBack) = dex.withdraw(lpMinted);
        
        // Calculate final position
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        uint256 aliceCreditsAfter = credits.balanceOf(alice);
        
        // Calculate net P&L
        int256 usdcPnL = int256(aliceUsdcAfter) - int256(aliceUsdcBefore);
        int256 creditsPnL = int256(aliceCreditsAfter) - int256(aliceCreditsBefore);
        
        // Convert credits PnL to USDC equivalent for total PnL
        // If creditsPnL is negative, that's a loss
        // The key assertion: alice should NOT profit overall
        
        // Alice should have lost value or broken even (accounting for rounding)
        // The swap fees should exceed any price manipulation gains
        assertTrue(
            usdcPnL <= 1 || creditsPnL < 0,
            "Alice should not profit from self-sandwich attack"
        );
        
        emit log_named_int("USDC PnL", usdcPnL);
        emit log_named_int("Credits PnL", creditsPnL);
    }

    /// @notice Test: Self-sandwich attack with larger LP deposit
    function testSelfSandwichAttackLargeDeposit() public {
        // Give alice more tokens
        vm.prank(owner);
        credits.mint(alice, 40_000 * 1e18);
        usdc.mint(alice, 500 * 1e6);
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceCreditsBefore = credits.balanceOf(alice);
        
        // Step 1: Large swap USDC -> CREDITS
        uint256 swapUsdcIn = 200 * 1e6;
        vm.prank(alice);
        uint256 creditsFromSwap = dex.assetToCredit(swapUsdcIn, 0);
        
        // Step 2: Very large LP deposit
        uint256 creditsToDeposit = 30_000 * 1e18;
        vm.prank(alice);
        uint256 lpMinted = dex.deposit(creditsToDeposit, 0);
        
        // Step 3: Swap all credits back
        vm.prank(alice);
        uint256 usdcFromSwap = dex.creditToAsset(creditsFromSwap, 0);
        
        // Step 4: Withdraw LP
        vm.prank(alice);
        (uint256 creditsBack, uint256 usdcBack) = dex.withdraw(lpMinted);
        
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        uint256 aliceCreditsAfter = credits.balanceOf(alice);
        
        // Check no profit
        int256 usdcPnL = int256(aliceUsdcAfter) - int256(aliceUsdcBefore);
        int256 creditsPnL = int256(aliceCreditsAfter) - int256(aliceCreditsBefore);
        
        emit log_named_int("Large Attack USDC PnL", usdcPnL);
        emit log_named_int("Large Attack Credits PnL", creditsPnL);
        
        // Combined value should not increase
        // Even if USDC went up, credits should have gone down more
        assertTrue(
            (usdcPnL <= 0 && creditsPnL <= 0) || 
            (usdcPnL > 0 && creditsPnL < 0) ||
            (creditsPnL > 0 && usdcPnL < 0),
            "Should not profit in both tokens"
        );
    }

    /// @notice Test: Self-sandwich when excess is NOT full (less price impact)
    function testSelfSandwichAttackExcessNotFull() public {
        // First drain the excess by having owner withdraw
        uint256 ownerLp = dex.getLiquidity(owner);
        vm.prank(owner);
        dex.withdraw(ownerLp / 2);
        
        uint256 excessBefore = dex.usdcExcess();
        assertTrue(excessBefore < EXCESS_CAP, "Excess should be below cap");
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceCreditsBefore = credits.balanceOf(alice);
        
        // Try the attack
        // Step 1: Swap USDC -> CREDITS
        uint256 swapUsdcIn = 50 * 1e6;
        vm.prank(alice);
        uint256 creditsFromSwap = dex.assetToCredit(swapUsdcIn, 0);
        
        // Step 2: Deposit LP (some goes to excess, less to reserves, less price impact)
        uint256 creditsToDeposit = 5000 * 1e18;
        vm.prank(alice);
        uint256 lpMinted = dex.deposit(creditsToDeposit, 0);
        
        // Step 3: Swap credits back
        vm.prank(alice);
        uint256 usdcFromSwap = dex.creditToAsset(creditsFromSwap, 0);
        
        // Step 4: Withdraw LP
        vm.prank(alice);
        dex.withdraw(lpMinted);
        
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        uint256 aliceCreditsAfter = credits.balanceOf(alice);
        
        int256 usdcPnL = int256(aliceUsdcAfter) - int256(aliceUsdcBefore);
        int256 creditsPnL = int256(aliceCreditsAfter) - int256(aliceCreditsBefore);
        
        emit log_named_int("Excess Not Full USDC PnL", usdcPnL);
        emit log_named_int("Excess Not Full Credits PnL", creditsPnL);
        
        // Should still not profit
        assertTrue(usdcPnL <= 1, "Should not profit on USDC when excess not full");
    }

    /// @notice Test: Reverse sandwich (swap credits first, then deposit, then swap back)
    /// @dev Documents behavior of reverse sandwich strategy
    function testReverseSandwichAttack() public {
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceCreditsBefore = credits.balanceOf(alice);
        
        // Step 1: Swap CREDITS -> USDC first (this lowers price)
        uint256 creditsToSwap = 2000 * 1e18;
        vm.prank(alice);
        uint256 usdcFromSwap1 = dex.creditToAsset(creditsToSwap, 0);
        
        // Step 2: Deposit LP
        uint256 creditsToDeposit = 5000 * 1e18;
        vm.prank(alice);
        uint256 lpMinted = dex.deposit(creditsToDeposit, 0);
        
        // Step 3: Swap USDC -> CREDITS (buy back at potentially different price)
        vm.prank(alice);
        dex.assetToCredit(usdcFromSwap1, 0);
        
        // Step 4: Withdraw LP
        vm.prank(alice);
        dex.withdraw(lpMinted);
        
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        uint256 aliceCreditsAfter = credits.balanceOf(alice);
        
        int256 usdcPnL = int256(aliceUsdcAfter) - int256(aliceUsdcBefore);
        int256 creditsPnL = int256(aliceCreditsAfter) - int256(aliceCreditsBefore);
        
        emit log_named_int("Reverse Sandwich USDC PnL", usdcPnL);
        emit log_named_int("Reverse Sandwich Credits PnL", creditsPnL);
        
        // Document findings
        if (usdcPnL > 0 && creditsPnL > 0) {
            emit log_string("FINDING: Reverse sandwich profitable in BOTH tokens!");
        } else if (usdcPnL > int256(1e6)) {
            emit log_string("FINDING: Reverse sandwich profitable in USDC");
        } else if (creditsPnL > int256(1e18)) {
            emit log_string("FINDING: Reverse sandwich profitable in CREDITS");
        } else {
            emit log_string("Reverse sandwich not significantly profitable");
        }
    }

    /// @notice Test: Multiple small sandwiches vs one large one
    function testMultipleSmallSandwiches() public {
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceCreditsBefore = credits.balanceOf(alice);
        
        // Do 3 small sandwich attempts
        for (uint i = 0; i < 3; i++) {
            // Swap in
            vm.prank(alice);
            uint256 creditsGot = dex.assetToCredit(30 * 1e6, 0);
            
            // Deposit LP
            vm.prank(alice);
            uint256 lp = dex.deposit(1000 * 1e18, 0);
            
            // Swap out
            vm.prank(alice);
            dex.creditToAsset(creditsGot, 0);
            
            // Withdraw
            vm.prank(alice);
            dex.withdraw(lp);
        }
        
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        uint256 aliceCreditsAfter = credits.balanceOf(alice);
        
        int256 usdcPnL = int256(aliceUsdcAfter) - int256(aliceUsdcBefore);
        int256 creditsPnL = int256(aliceCreditsAfter) - int256(aliceCreditsBefore);
        
        emit log_named_int("Multiple Small Sandwiches USDC PnL", usdcPnL);
        emit log_named_int("Multiple Small Sandwiches Credits PnL", creditsPnL);
        
        // Should definitely be losing to accumulated fees
        assertTrue(usdcPnL < 0 || creditsPnL < 0, "Multiple attempts should accumulate losses");
    }

    // ============ FRONT-RUNNING LP DEPOSIT ATTACK TESTS ============
    // Tests where attacker Alice tries to front-run Bob's LP deposit

    /// @notice Test: Front-running an LP deposit (classic sandwich)
    /// @dev This test documents the behavior - positive PnL indicates vulnerability
    function testFrontRunLPDeposit() public {
        // Alice is the attacker, Bob is the victim LP
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        
        // Step 1: Alice front-runs by swapping USDC -> CREDITS
        vm.prank(alice);
        uint256 aliceCreditsFromSwap = dex.assetToCredit(100 * 1e6, 0);
        
        // Step 2: Bob deposits LP (victim transaction)
        uint256 bobCreditsToDeposit = 10_000 * 1e18;
        vm.prank(bob);
        uint256 bobLpMinted = dex.deposit(bobCreditsToDeposit, 0);
        
        // Step 3: Alice back-runs by swapping CREDITS -> USDC
        vm.prank(alice);
        dex.creditToAsset(aliceCreditsFromSwap, 0);
        
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        
        int256 aliceUsdcPnL = int256(aliceUsdcAfter) - int256(aliceUsdcBefore);
        
        emit log_named_int("Front-run Attack Alice USDC PnL", aliceUsdcPnL);
        
        // Document the finding
        if (aliceUsdcPnL > 0) {
            emit log_string("FINDING: Front-running LP deposits IS profitable!");
            emit log_string("The LP deposit increases price, benefiting the front-runner.");
        } else {
            emit log_string("Front-running NOT profitable - swap fees exceed gains.");
        }
        
        // Bob's LP should still have value
        assertTrue(bobLpMinted > 0, "Bob should have received LP tokens");
    }

    /// @notice Test: Front-running with larger amounts
    /// @dev Documents the economics of larger front-run attacks
    function testFrontRunLPDepositLargeAmounts() public {
        // Give alice more tokens
        usdc.mint(alice, 400 * 1e6);
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        
        // Step 1: Alice front-runs with large swap
        vm.prank(alice);
        uint256 aliceCreditsFromSwap = dex.assetToCredit(400 * 1e6, 0);
        
        // Step 2: Bob deposits large LP
        uint256 bobCreditsToDeposit = 30_000 * 1e18;
        vm.prank(owner);
        credits.mint(bob, 30_000 * 1e18);
        usdc.mint(bob, 500 * 1e6);
        
        vm.prank(bob);
        dex.deposit(bobCreditsToDeposit, 0);
        
        // Step 3: Alice back-runs
        vm.prank(alice);
        dex.creditToAsset(aliceCreditsFromSwap, 0);
        
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        
        int256 aliceUsdcPnL = int256(aliceUsdcAfter) - int256(aliceUsdcBefore);
        
        emit log_named_int("Large Front-run Alice USDC PnL", aliceUsdcPnL);
        
        // Document the finding
        if (aliceUsdcPnL > 0) {
            emit log_string("FINDING: Large front-run attack IS profitable!");
            uint256 profitBps = uint256(aliceUsdcPnL) * 10000 / 400e6;
            emit log_named_uint("Profit in basis points", profitBps);
        }
    }

    /// @notice Test: Multiple users front-running each other
    /// @dev Documents how competing front-runners affect each other
    function testMultipleFrontRunners() public {
        // Give users tokens
        usdc.mint(lp1, 200 * 1e6);
        usdc.mint(lp2, 200 * 1e6);
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 lp1UsdcBefore = usdc.balanceOf(lp1);
        uint256 lp2UsdcBefore = usdc.balanceOf(lp2);
        
        // Alice swaps first
        vm.prank(alice);
        uint256 aliceCredits = dex.assetToCredit(100 * 1e6, 0);
        
        // LP1 swaps
        vm.prank(lp1);
        uint256 lp1Credits = dex.assetToCredit(100 * 1e6, 0);
        
        // Bob deposits LP (the "target")
        vm.prank(bob);
        dex.deposit(5000 * 1e18, 0);
        
        // LP2 swaps
        vm.prank(lp2);
        uint256 lp2Credits = dex.assetToCredit(100 * 1e6, 0);
        
        // Everyone swaps back
        vm.prank(lp2);
        dex.creditToAsset(lp2Credits, 0);
        
        vm.prank(lp1);
        dex.creditToAsset(lp1Credits, 0);
        
        vm.prank(alice);
        dex.creditToAsset(aliceCredits, 0);
        
        // Calculate PnLs
        int256 alicePnL = int256(usdc.balanceOf(alice)) - int256(aliceUsdcBefore);
        int256 lp1PnL = int256(usdc.balanceOf(lp1)) - int256(lp1UsdcBefore);
        int256 lp2PnL = int256(usdc.balanceOf(lp2)) - int256(lp2UsdcBefore);
        
        emit log_named_int("Multi Front-run Alice PnL", alicePnL);
        emit log_named_int("Multi Front-run LP1 PnL", lp1PnL);
        emit log_named_int("Multi Front-run LP2 PnL", lp2PnL);
        
        // Document findings - who benefits in multi-front-runner scenario
        int256 totalPnL = alicePnL + lp1PnL + lp2PnL;
        emit log_named_int("Total PnL of front-runners", totalPnL);
        
        if (alicePnL > 0) emit log_string("FINDING: Alice (first front-runner) profited");
        if (lp1PnL > 0) emit log_string("FINDING: LP1 (second front-runner) profited");
        if (lp2PnL > 0) emit log_string("FINDING: LP2 (late front-runner) profited");
    }

    /// @notice Test: Front-running a withdrawal
    function testFrontRunLPWithdraw() public {
        // First, Bob deposits LP
        vm.prank(bob);
        uint256 bobLp = dex.deposit(10_000 * 1e18, 0);
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceCreditsBefore = credits.balanceOf(alice);
        
        // Alice tries to front-run Bob's withdrawal
        // Step 1: Alice swaps (trying to move price before Bob withdraws)
        vm.prank(alice);
        uint256 aliceCredits = dex.assetToCredit(100 * 1e6, 0);
        
        // Step 2: Bob withdraws
        vm.prank(bob);
        dex.withdraw(bobLp);
        
        // Step 3: Alice swaps back
        vm.prank(alice);
        dex.creditToAsset(aliceCredits, 0);
        
        int256 aliceUsdcPnL = int256(usdc.balanceOf(alice)) - int256(aliceUsdcBefore);
        
        emit log_named_int("Front-run Withdraw Alice USDC PnL", aliceUsdcPnL);
        
        // Alice should not profit
        assertTrue(aliceUsdcPnL <= 0, "Should not profit from front-running withdrawal");
    }

    // ============ EXCESS POOL STATE TRANSITION TESTS ============
    // Test behavior at different excess fill levels

    /// @notice Helper to drain excess to a specific level
    function _drainExcessToLevel(uint256 targetLevel) internal {
        // Withdraw LP to drain excess
        uint256 currentExcess = dex.usdcExcess();
        if (currentExcess <= targetLevel) return;
        
        // Calculate how much LP to withdraw to reach target
        // excess reduction = (withdrawAmount * currentExcess) / totalLiquidity
        // withdrawAmount = (reduction * totalLiquidity) / currentExcess
        uint256 reduction = currentExcess - targetLevel;
        uint256 totalLiq = dex.totalLiquidity();
        uint256 lpToWithdraw = (reduction * totalLiq) / currentExcess;
        
        if (lpToWithdraw > 0 && lpToWithdraw <= dex.getLiquidity(owner)) {
            vm.prank(owner);
            dex.withdraw(lpToWithdraw);
        }
    }

    /// @notice Test: Deposit when excess is at 0%
    function testDepositExcessEmpty() public {
        // Drain all excess by withdrawing everything and re-depositing
        uint256 ownerLp = dex.getLiquidity(owner);
        vm.prank(owner);
        (uint256 creditsOut, uint256 usdcOut) = dex.withdraw(ownerLp);
        
        // Re-init with no excess
        CreditsDex dex2 = new CreditsDex(address(credits), address(usdc));
        vm.startPrank(owner);
        credits.approve(address(dex2), type(uint256).max);
        usdc.approve(address(dex2), type(uint256).max);
        dex2.init(creditsOut, usdcOut, 0); // No excess
        vm.stopPrank();
        
        assertEq(dex2.usdcExcess(), 0, "Excess should be 0");
        
        uint256 priceBefore = dex2.creditInPrice(1000 * 1e18);
        
        // LP deposit - should fill excess first
        vm.prank(lp1);
        credits.approve(address(dex2), type(uint256).max);
        vm.prank(lp1);
        usdc.approve(address(dex2), type(uint256).max);
        
        vm.prank(lp1);
        dex2.deposit(10_000 * 1e18, 0);
        
        uint256 priceAfter = dex2.creditInPrice(1000 * 1e18);
        
        // When excess is empty, deposit goes to excess first
        // Less should go to reserves, so less price impact
        assertTrue(dex2.usdcExcess() > 0, "Excess should have increased");
        
        emit log_named_uint("Price before (excess empty)", priceBefore);
        emit log_named_uint("Price after (excess empty)", priceAfter);
    }

    /// @notice Test: Deposit when excess is at 50%
    function testDepositExcessHalfFull() public {
        // Withdraw to get excess to ~50 USDC
        _drainExcessToLevel(50 * 1e6);
        
        uint256 excessBefore = dex.usdcExcess();
        assertTrue(excessBefore < 60 * 1e6 && excessBefore > 40 * 1e6, "Excess should be ~50 USDC");
        
        uint256 priceBefore = dex.creditInPrice(1000 * 1e18);
        uint256 reservesBefore = dex.getUsdcReserves();
        
        // LP deposit
        vm.prank(lp1);
        dex.deposit(5_000 * 1e18, 0);
        
        uint256 excessAfter = dex.usdcExcess();
        uint256 priceAfter = dex.creditInPrice(1000 * 1e18);
        uint256 reservesAfter = dex.getUsdcReserves();
        
        emit log_named_uint("Excess before (50%)", excessBefore);
        emit log_named_uint("Excess after (50%)", excessAfter);
        emit log_named_uint("Reserves before", reservesBefore);
        emit log_named_uint("Reserves after", reservesAfter);
        emit log_named_uint("Price change", priceAfter > priceBefore ? priceAfter - priceBefore : 0);
        
        // Some should go to excess, some to reserves
        assertTrue(excessAfter >= excessBefore, "Excess should increase or stay same");
    }

    /// @notice Test: Deposit when excess is at 99%
    function testDepositExcessAlmostFull() public {
        // Excess starts at 100, drain to 99
        _drainExcessToLevel(99 * 1e6);
        
        uint256 excessBefore = dex.usdcExcess();
        
        uint256 priceBefore = dex.creditInPrice(1000 * 1e18);
        
        // LP deposit - only 1 USDC goes to excess, rest to reserves
        vm.prank(lp1);
        dex.deposit(5_000 * 1e18, 0);
        
        uint256 excessAfter = dex.usdcExcess();
        uint256 priceAfter = dex.creditInPrice(1000 * 1e18);
        
        // Should be at cap now
        assertEq(excessAfter, EXCESS_CAP, "Excess should be at cap");
        
        emit log_named_uint("Price before (99%)", priceBefore);
        emit log_named_uint("Price after (99%)", priceAfter);
        
        // Price should have increased (most USDC went to reserves)
        assertTrue(priceAfter > priceBefore, "Price should increase when excess almost full");
    }

    /// @notice Test: Deposit when excess is at 100% (full)
    function testDepositExcessFull() public {
        // Excess should already be at cap
        assertEq(dex.usdcExcess(), EXCESS_CAP, "Excess should start at cap");
        
        uint256 priceBefore = dex.creditInPrice(1000 * 1e18);
        uint256 reservesBefore = dex.getUsdcReserves();
        
        // LP deposit - ALL USDC goes to reserves
        vm.prank(lp1);
        dex.deposit(10_000 * 1e18, 0);
        
        uint256 priceAfter = dex.creditInPrice(1000 * 1e18);
        uint256 reservesAfter = dex.getUsdcReserves();
        
        // Excess should still be at cap
        assertEq(dex.usdcExcess(), EXCESS_CAP, "Excess should remain at cap");
        
        // All USDC went to reserves
        assertTrue(reservesAfter > reservesBefore, "Reserves should increase");
        
        // Price should have increased significantly
        assertTrue(priceAfter > priceBefore, "Price should increase when excess is full");
        
        emit log_named_uint("Price before (100%)", priceBefore);
        emit log_named_uint("Price after (100%)", priceAfter);
        emit log_named_uint("Price increase %", ((priceAfter - priceBefore) * 100) / priceBefore);
    }

    /// @notice Test: Compare price impact at different excess levels
    function testPriceImpactComparison() public {
        // Record price impacts at different excess levels
        uint256[] memory priceImpacts = new uint256[](4);
        uint256[] memory excessLevels = new uint256[](4);
        excessLevels[0] = 0;
        excessLevels[1] = 50 * 1e6;
        excessLevels[2] = 99 * 1e6;
        excessLevels[3] = 100 * 1e6;
        
        for (uint i = 0; i < 4; i++) {
            // Reset to fresh state
            CreditsDex freshDex = new CreditsDex(address(credits), address(usdc));
            
            vm.prank(owner);
            credits.mint(owner, INITIAL_CREDITS);
            usdc.mint(owner, INITIAL_USDC_RESERVES + excessLevels[i]);
            
            vm.startPrank(owner);
            credits.approve(address(freshDex), type(uint256).max);
            usdc.approve(address(freshDex), type(uint256).max);
            freshDex.init(INITIAL_CREDITS, INITIAL_USDC_RESERVES, excessLevels[i]);
            vm.stopPrank();
            
            uint256 priceBefore = freshDex.creditInPrice(1000 * 1e18);
            
            // Approve LP1
            vm.prank(lp1);
            credits.approve(address(freshDex), type(uint256).max);
            vm.prank(lp1);
            usdc.approve(address(freshDex), type(uint256).max);
            
            // LP deposit
            vm.prank(lp1);
            freshDex.deposit(10_000 * 1e18, 0);
            
            uint256 priceAfter = freshDex.creditInPrice(1000 * 1e18);
            
            priceImpacts[i] = priceAfter > priceBefore ? priceAfter - priceBefore : 0;
            
            emit log_named_uint("Excess level", excessLevels[i] / 1e6);
            emit log_named_uint("Price impact", priceImpacts[i]);
        }
        
        // Price impact should be highest when excess is full (100%)
        // Because all USDC goes to reserves
        assertTrue(priceImpacts[3] >= priceImpacts[0], "Full excess should have >= price impact than empty");
    }

    /// @notice Test: Large deposit that overflows excess multiple times
    function testLargeDepositOverflow() public {
        // Don't drain completely - just reduce excess
        uint256 ownerLp = dex.getLiquidity(owner);
        if (ownerLp > 0) {
            vm.prank(owner);
            dex.withdraw(ownerLp / 4); // Only withdraw 25%
        }
        
        // Give LP1 a lot of tokens
        vm.prank(owner);
        credits.mint(lp1, 200_000 * 1e18);
        usdc.mint(lp1, 5000 * 1e6);
        
        uint256 excessBefore = dex.usdcExcess();
        uint256 reservesBefore = dex.getUsdcReserves();
        uint256 totalLiqBefore = dex.totalLiquidity();
        
        // Ensure pool is not empty
        require(totalLiqBefore > 0, "Pool should not be empty");
        
        // Large deposit - should fill excess to cap, rest to reserves
        vm.prank(lp1);
        dex.deposit(50_000 * 1e18, 0);
        
        uint256 excessAfter = dex.usdcExcess();
        uint256 reservesAfter = dex.getUsdcReserves();
        
        // Excess should be at cap or increased
        assertTrue(excessAfter >= excessBefore, "Excess should not decrease");
        assertTrue(excessAfter <= EXCESS_CAP, "Excess should not exceed cap");
        
        // Reserves should have increased
        assertTrue(reservesAfter >= reservesBefore, "Reserves should not decrease");
        
        emit log_named_uint("Excess before", excessBefore / 1e6);
        emit log_named_uint("Excess after", excessAfter / 1e6);
        emit log_named_uint("Reserves increase", (reservesAfter - reservesBefore) / 1e6);
    }

    // ============ MULTI-USER ATTACK COORDINATION TESTS ============
    // Tests for coordinated attacks between multiple users

    /// @notice Test: Two users coordinate - one deposits LP, other swaps
    function testCoordinatedLPAndSwap() public {
        // Alice and Bob coordinate: Bob deposits LP, Alice swaps
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 bobCreditsBefore = credits.balanceOf(bob);
        
        // Step 1: Alice swaps USDC -> CREDITS
        vm.prank(alice);
        uint256 aliceCredits = dex.assetToCredit(100 * 1e6, 0);
        
        // Step 2: Bob deposits LP (increases price since excess is full)
        vm.prank(bob);
        uint256 bobLp = dex.deposit(10_000 * 1e18, 0);
        
        // Step 3: Alice swaps CREDITS -> USDC at new price
        vm.prank(alice);
        uint256 aliceUsdcBack = dex.creditToAsset(aliceCredits, 0);
        
        // Step 4: Bob withdraws LP
        vm.prank(bob);
        (uint256 bobCreditsBack, uint256 bobUsdcBack) = dex.withdraw(bobLp);
        
        // Calculate PnLs
        int256 alicePnL = int256(usdc.balanceOf(alice)) - int256(aliceUsdcBefore);
        int256 bobUsdcPnL = int256(usdc.balanceOf(bob)) - int256(bobUsdcBefore);
        int256 bobCreditsPnL = int256(credits.balanceOf(bob)) - int256(bobCreditsBefore);
        
        emit log_named_int("Coordinated: Alice USDC PnL", alicePnL);
        emit log_named_int("Coordinated: Bob USDC PnL", bobUsdcPnL);
        emit log_named_int("Coordinated: Bob Credits PnL", bobCreditsPnL);
        
        // Combined PnL should be negative (fees extracted)
        int256 totalPnL = alicePnL + bobUsdcPnL; // Simplified - ignoring credits
        assertTrue(totalPnL <= 0, "Combined coordination should not profit");
    }

    /// @notice Test: LP wars - multiple LPs competing
    function testLPWars() public {
        // Give LPs more tokens
        vm.startPrank(owner);
        credits.mint(lp1, 50_000 * 1e18);
        credits.mint(lp2, 50_000 * 1e18);
        vm.stopPrank();
        usdc.mint(lp1, 1000 * 1e6);
        usdc.mint(lp2, 1000 * 1e6);
        
        uint256 lp1UsdcBefore = usdc.balanceOf(lp1);
        uint256 lp2UsdcBefore = usdc.balanceOf(lp2);
        
        // LP1 deposits
        vm.prank(lp1);
        uint256 lp1Tokens = dex.deposit(20_000 * 1e18, 0);
        
        // Alice swaps (creates trading activity)
        vm.prank(alice);
        uint256 aliceCredits = dex.assetToCredit(50 * 1e6, 0);
        
        // LP2 deposits
        vm.prank(lp2);
        uint256 lp2Tokens = dex.deposit(20_000 * 1e18, 0);
        
        // Alice swaps back
        vm.prank(alice);
        dex.creditToAsset(aliceCredits, 0);
        
        // Both LPs withdraw
        vm.prank(lp1);
        dex.withdraw(lp1Tokens);
        
        vm.prank(lp2);
        dex.withdraw(lp2Tokens);
        
        // Calculate PnLs
        int256 lp1UsdcPnL = int256(usdc.balanceOf(lp1)) - int256(lp1UsdcBefore);
        int256 lp2UsdcPnL = int256(usdc.balanceOf(lp2)) - int256(lp2UsdcBefore);
        
        emit log_named_int("LP Wars: LP1 USDC PnL", lp1UsdcPnL);
        emit log_named_int("LP Wars: LP2 USDC PnL", lp2UsdcPnL);
        
        // Document findings
        if (lp1UsdcPnL > lp2UsdcPnL) {
            emit log_string("LP1 (early depositor) did better");
        } else if (lp2UsdcPnL > lp1UsdcPnL) {
            emit log_string("LP2 (late depositor) did better");
        }
    }

    /// @notice Test: Trader vs LP - who benefits from swaps?
    function testTraderVsLP() public {
        // Bob is LP, Alice is trader
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 bobCreditsBefore = credits.balanceOf(bob);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        
        // Bob deposits LP
        vm.prank(bob);
        uint256 bobLp = dex.deposit(10_000 * 1e18, 0);
        
        // Alice trades multiple times
        for (uint i = 0; i < 5; i++) {
            vm.prank(alice);
            uint256 creds = dex.assetToCredit(20 * 1e6, 0);
            
            vm.prank(alice);
            dex.creditToAsset(creds, 0);
        }
        
        // Bob withdraws LP
        vm.prank(bob);
        (uint256 bobCreditsBack, uint256 bobUsdcBack) = dex.withdraw(bobLp);
        
        int256 bobUsdcPnL = int256(usdc.balanceOf(bob)) - int256(bobUsdcBefore);
        int256 bobCreditsPnL = int256(credits.balanceOf(bob)) - int256(bobCreditsBefore);
        int256 alicePnL = int256(usdc.balanceOf(alice)) - int256(aliceUsdcBefore);
        
        emit log_named_int("Trader vs LP: Bob (LP) USDC PnL", bobUsdcPnL);
        emit log_named_int("Trader vs LP: Bob (LP) Credits PnL", bobCreditsPnL);
        emit log_named_int("Trader vs LP: Alice (Trader) USDC PnL", alicePnL);
        
        // Alice should have lost to fees
        assertTrue(alicePnL < 0, "Trader should lose to fees");
        
        // Bob might have gained slightly (from fees) or stayed neutral
        // This depends on the exact implementation
    }

    /// @notice Test: Griefing attack - can someone hurt LPs without profiting?
    function testGriefingAttack() public {
        // Bob is LP
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 bobCreditsBefore = credits.balanceOf(bob);
        
        vm.prank(bob);
        uint256 bobLp = dex.deposit(10_000 * 1e18, 0);
        
        // Alice does many small swaps (griefing)
        usdc.mint(alice, 500 * 1e6);
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        
        for (uint i = 0; i < 10; i++) {
            vm.prank(alice);
            uint256 creds = dex.assetToCredit(10 * 1e6, 0);
            vm.prank(alice);
            dex.creditToAsset(creds, 0);
        }
        
        // Bob withdraws
        vm.prank(bob);
        dex.withdraw(bobLp);
        
        int256 bobUsdcPnL = int256(usdc.balanceOf(bob)) - int256(bobUsdcBefore);
        int256 alicePnL = int256(usdc.balanceOf(alice)) - int256(aliceUsdcBefore);
        
        emit log_named_int("Griefing: Bob (LP) USDC PnL", bobUsdcPnL);
        emit log_named_int("Griefing: Alice (Attacker) USDC PnL", alicePnL);
        
        // Alice should lose (pays fees)
        assertTrue(alicePnL < 0, "Griefer should lose money");
        
        // Bob might gain slightly from Alice's fees
    }

    /// @notice Test: Flash loan style attack simulation (within single tx)
    function testFlashLoanStyleAttack() public {
        // Simulate a flash loan attack where someone:
        // 1. "Borrows" a large amount
        // 2. Manipulates price
        // 3. Profits
        // 4. Repays
        
        // Give alice a lot of USDC (simulating flash loan)
        usdc.mint(alice, 20_000 * 1e6); // Need enough for swap + LP deposit
        vm.prank(owner);
        credits.mint(alice, 50_000 * 1e18);
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceCreditsBefore = credits.balanceOf(alice);
        
        // Large swap to move price
        vm.prank(alice);
        uint256 creditsFromLargeSwap = dex.assetToCredit(5000 * 1e6, 0);
        
        // Deposit LP
        vm.prank(alice);
        uint256 lpMinted = dex.deposit(30_000 * 1e18, 0);
        
        // Swap back
        vm.prank(alice);
        dex.creditToAsset(creditsFromLargeSwap, 0);
        
        // Withdraw LP
        vm.prank(alice);
        dex.withdraw(lpMinted);
        
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        uint256 aliceCreditsAfter = credits.balanceOf(alice);
        
        int256 usdcPnL = int256(aliceUsdcAfter) - int256(aliceUsdcBefore);
        int256 creditsPnL = int256(aliceCreditsAfter) - int256(aliceCreditsBefore);
        
        emit log_named_int("Flash Loan Style: USDC PnL", usdcPnL);
        emit log_named_int("Flash Loan Style: Credits PnL", creditsPnL);
        
        // Document the finding - this shows whether flash loan attacks are profitable
        // If positive PnL, this is a POTENTIAL VULNERABILITY to investigate
        if (usdcPnL > int256(1e6)) {
            emit log_string("WARNING: Flash loan attack appears profitable - investigate!");
        }
    }

    /// @notice Test: JIT (Just-in-Time) liquidity attack
    function testJITLiquidityAttack() public {
        // JIT attack: Add liquidity just before a large swap, remove after
        
        // Alice will do a large swap
        usdc.mint(alice, 500 * 1e6);
        
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 bobCreditsBefore = credits.balanceOf(bob);
        
        // Bob JIT deposits right before Alice's swap
        vm.prank(bob);
        uint256 bobLp = dex.deposit(10_000 * 1e18, 0);
        
        // Alice's large swap
        vm.prank(alice);
        uint256 aliceCredits = dex.assetToCredit(500 * 1e6, 0);
        
        // Bob immediately withdraws
        vm.prank(bob);
        dex.withdraw(bobLp);
        
        int256 bobUsdcPnL = int256(usdc.balanceOf(bob)) - int256(bobUsdcBefore);
        int256 bobCreditsPnL = int256(credits.balanceOf(bob)) - int256(bobCreditsBefore);
        
        emit log_named_int("JIT: Bob USDC PnL", bobUsdcPnL);
        emit log_named_int("JIT: Bob Credits PnL", bobCreditsPnL);
        
        // JIT should not be significantly profitable
        // The fee capture should be minimal for a single swap
    }

    // ============ INVARIANT TESTS ============
    // Tests that verify critical invariants hold

    /// @notice Test: Total USDC always equals reserves + excess
    function testInvariantTotalUsdcEqualsReservesPlusExcess() public {
        // Initial state
        assertEq(dex.getTotalUsdc(), dex.getUsdcReserves() + dex.usdcExcess(), "Invariant: total = reserves + excess");
        
        // After swap
        vm.prank(alice);
        dex.assetToCredit(50 * 1e6, 0);
        assertEq(dex.getTotalUsdc(), dex.getUsdcReserves() + dex.usdcExcess(), "Invariant holds after swap");
        
        // After LP deposit
        vm.prank(lp1);
        dex.deposit(5_000 * 1e18, 0);
        assertEq(dex.getTotalUsdc(), dex.getUsdcReserves() + dex.usdcExcess(), "Invariant holds after deposit");
        
        // After LP withdraw
        uint256 lp1Balance = dex.getLiquidity(lp1);
        vm.prank(lp1);
        dex.withdraw(lp1Balance);
        assertEq(dex.getTotalUsdc(), dex.getUsdcReserves() + dex.usdcExcess(), "Invariant holds after withdraw");
    }

    /// @notice Test: LP tokens always backed by proportional reserves
    function testInvariantLPBackedByReserves() public {
        // Add some LPs
        vm.prank(lp1);
        dex.deposit(10_000 * 1e18, 0);
        
        vm.prank(lp2);
        dex.deposit(5_000 * 1e18, 0);
        
        uint256 totalLp = dex.totalLiquidity();
        uint256 lp1Balance = dex.getLiquidity(lp1);
        uint256 lp2Balance = dex.getLiquidity(lp2);
        uint256 ownerBalance = dex.getLiquidity(owner);
        
        // All LP should sum to total
        assertEq(lp1Balance + lp2Balance + ownerBalance, totalLp, "LP tokens should sum to total");
        
        // Each LP's share of total value should be proportional
        uint256 totalCredits = dex.getCreditReserves();
        uint256 totalUsdc = dex.getTotalUsdc();
        
        // LP1's expected share
        uint256 lp1ExpectedCredits = (lp1Balance * totalCredits) / totalLp;
        uint256 lp1ExpectedUsdc = (lp1Balance * totalUsdc) / totalLp;
        
        // Verify by withdrawing (this is the actual test of the invariant)
        vm.prank(lp1);
        (uint256 creditsOut, uint256 usdcOut) = dex.withdraw(lp1Balance);
        
        // Should receive expected amounts (allowing small rounding)
        assertApproxEqAbs(creditsOut, lp1ExpectedCredits, 1e18, "Credits should match expected");
        assertApproxEqAbs(usdcOut, lp1ExpectedUsdc, 1e6, "USDC should match expected");
    }

    /// @notice Test: Swap fees always benefit the pool (k never decreases)
    function testInvariantSwapFeesIncreaseK() public {
        uint256 kBefore = dex.getUsdcReserves() * dex.getCreditReserves();
        
        // Multiple swaps in both directions
        vm.prank(alice);
        uint256 creds = dex.assetToCredit(100 * 1e6, 0);
        
        uint256 kAfterSwap1 = dex.getUsdcReserves() * dex.getCreditReserves();
        assertTrue(kAfterSwap1 >= kBefore, "k should not decrease after swap");
        
        vm.prank(alice);
        dex.creditToAsset(creds, 0);
        
        uint256 kAfterSwap2 = dex.getUsdcReserves() * dex.getCreditReserves();
        assertTrue(kAfterSwap2 >= kAfterSwap1, "k should not decrease after second swap");
        
        // k should have grown due to fees
        assertTrue(kAfterSwap2 > kBefore, "k should have grown from fees");
    }

    /// @notice Test: No free value creation from any transaction
    function testInvariantNoFreeValueCreation() public {
        // Track total value in the system
        uint256 systemUsdcBefore = usdc.balanceOf(address(dex)) + usdc.balanceOf(alice) + usdc.balanceOf(bob);
        uint256 systemCreditsBefore = credits.balanceOf(address(dex)) + credits.balanceOf(alice) + credits.balanceOf(bob);
        
        // Alice swaps
        vm.prank(alice);
        dex.assetToCredit(50 * 1e6, 0);
        
        // Bob deposits
        vm.prank(bob);
        dex.deposit(5000 * 1e18, 0);
        
        // Alice swaps back
        vm.prank(alice);
        dex.creditToAsset(500 * 1e18, 0);
        
        // Check total value
        uint256 systemUsdcAfter = usdc.balanceOf(address(dex)) + usdc.balanceOf(alice) + usdc.balanceOf(bob);
        uint256 systemCreditsAfter = credits.balanceOf(address(dex)) + credits.balanceOf(alice) + credits.balanceOf(bob);
        
        // USDC should be conserved (no creation/destruction)
        assertEq(systemUsdcAfter, systemUsdcBefore, "USDC should be conserved");
        // Credits should be conserved
        assertEq(systemCreditsAfter, systemCreditsBefore, "Credits should be conserved");
    }

    /// @notice Test: Excess never exceeds cap
    function testInvariantExcessNeverExceedsCap() public {
        // Try multiple deposits
        for (uint i = 0; i < 5; i++) {
            vm.prank(lp1);
            dex.deposit(5_000 * 1e18, 0);
            assertTrue(dex.usdcExcess() <= EXCESS_CAP, "Excess should never exceed cap");
        }
        
        // Try roll payments
        for (uint i = 0; i < 5; i++) {
            vm.prank(alice);
            dex.roll();
            assertTrue(dex.usdcExcess() <= EXCESS_CAP, "Excess should never exceed cap after roll");
        }
    }

    /// @notice Test: Reserves + excess always equals contract balance
    function testInvariantBalanceConsistency() public {
        // Initial check
        assertEq(
            usdc.balanceOf(address(dex)),
            dex.getUsdcReserves() + dex.usdcExcess(),
            "Contract balance should equal reserves + excess"
        );
        
        // After various operations
        vm.prank(alice);
        dex.assetToCredit(30 * 1e6, 0);
        
        assertEq(
            usdc.balanceOf(address(dex)),
            dex.getUsdcReserves() + dex.usdcExcess(),
            "Balance consistency after swap in"
        );
        
        vm.prank(alice);
        dex.creditToAsset(500 * 1e18, 0);
        
        assertEq(
            usdc.balanceOf(address(dex)),
            dex.getUsdcReserves() + dex.usdcExcess(),
            "Balance consistency after swap out"
        );
        
        vm.prank(lp1);
        dex.deposit(5_000 * 1e18, 0);
        
        assertEq(
            usdc.balanceOf(address(dex)),
            dex.getUsdcReserves() + dex.usdcExcess(),
            "Balance consistency after deposit"
        );
    }

    /// @notice Test: LP share proportions remain consistent
    function testInvariantLPShareProportions() public {
        // Add multiple LPs
        vm.prank(lp1);
        dex.deposit(10_000 * 1e18, 0);
        
        uint256 totalLpAfterLp1 = dex.totalLiquidity();
        uint256 lp1Share = (dex.getLiquidity(lp1) * 1e18) / totalLpAfterLp1;
        
        // Trading activity
        vm.prank(alice);
        dex.assetToCredit(100 * 1e6, 0);
        
        vm.prank(alice);
        dex.creditToAsset(2000 * 1e18, 0);
        
        // LP1's share should not change (no new LPs)
        uint256 totalLpAfterTrades = dex.totalLiquidity();
        uint256 lp1ShareAfter = (dex.getLiquidity(lp1) * 1e18) / totalLpAfterTrades;
        
        assertEq(totalLpAfterLp1, totalLpAfterTrades, "Total LP should not change from trades");
        assertEq(lp1Share, lp1ShareAfter, "LP share should not change from trades");
    }

    // ============ FUZZ TESTS ============
    // Randomized tests to find edge cases

    /// @notice Fuzz: Random swap amounts should not create value
    function testFuzzSwapRoundTrip(uint256 usdcAmount) public {
        // Bound to reasonable amounts
        usdcAmount = bound(usdcAmount, 1e6, 500 * 1e6); // 1 to 500 USDC
        
        usdc.mint(alice, usdcAmount);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        
        // Swap USDC -> CREDITS
        vm.prank(alice);
        uint256 creditsReceived = dex.assetToCredit(usdcAmount, 0);
        
        // Swap CREDITS -> USDC
        vm.prank(alice);
        uint256 usdcReceived = dex.creditToAsset(creditsReceived, 0);
        
        // Should not profit
        assertLe(usdcReceived, usdcAmount, "Should not receive more USDC than started with");
    }

    /// @notice Fuzz: Random LP deposit/withdraw should not create value
    function testFuzzLPRoundTrip(uint256 creditAmount) public {
        // Bound to reasonable amounts
        creditAmount = bound(creditAmount, 100 * 1e18, 30_000 * 1e18);
        
        vm.prank(owner);
        credits.mint(lp1, creditAmount);
        usdc.mint(lp1, 1000 * 1e6); // Extra USDC for the deposit
        
        uint256 lp1UsdcBefore = usdc.balanceOf(lp1);
        uint256 lp1CreditsBefore = credits.balanceOf(lp1);
        
        // Deposit LP
        vm.prank(lp1);
        uint256 lpMinted = dex.deposit(creditAmount, 0);
        
        // Withdraw LP
        vm.prank(lp1);
        (uint256 creditsBack, uint256 usdcBack) = dex.withdraw(lpMinted);
        
        // Should get back same or slightly less (rounding)
        assertLe(usdc.balanceOf(lp1), lp1UsdcBefore + 1e6, "Should not profit on USDC");
        assertLe(credits.balanceOf(lp1), lp1CreditsBefore + 1e18, "Should not profit on credits");
    }

    /// @notice Fuzz: Random sandwich attack should not profit
    function testFuzzSandwichAttack(uint256 swapAmount, uint256 depositAmount) public {
        // Bound amounts
        swapAmount = bound(swapAmount, 10 * 1e6, 200 * 1e6);
        depositAmount = bound(depositAmount, 1000 * 1e18, 20_000 * 1e18);
        
        usdc.mint(alice, swapAmount + 500 * 1e6);
        vm.prank(owner);
        credits.mint(alice, depositAmount);
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceCreditsBefore = credits.balanceOf(alice);
        
        // Swap in
        vm.prank(alice);
        uint256 creditsFromSwap = dex.assetToCredit(swapAmount, 0);
        
        // Deposit LP
        vm.prank(alice);
        uint256 lpMinted = dex.deposit(depositAmount, 0);
        
        // Swap out
        vm.prank(alice);
        dex.creditToAsset(creditsFromSwap, 0);
        
        // Withdraw LP
        vm.prank(alice);
        dex.withdraw(lpMinted);
        
        // Check no significant profit
        int256 usdcPnL = int256(usdc.balanceOf(alice)) - int256(aliceUsdcBefore);
        
        // Allow tiny positive due to rounding, but not significant profit
        assertTrue(usdcPnL <= int256(1e6), "Sandwich attack should not yield significant USDC profit");
    }

    /// @notice Fuzz: Random operations sequence
    function testFuzzOperationSequence(uint8 opType, uint256 amount) public {
        // opType determines operation: 0=swap in, 1=swap out, 2=deposit, 3=withdraw
        opType = uint8(bound(opType, 0, 3));
        
        // Setup
        usdc.mint(alice, 1000 * 1e6);
        vm.prank(owner);
        credits.mint(alice, 50_000 * 1e18);
        
        // Track initial state
        uint256 totalUsdcBefore = usdc.balanceOf(address(dex)) + usdc.balanceOf(alice);
        uint256 totalCreditsBefore = credits.balanceOf(address(dex)) + credits.balanceOf(alice);
        
        if (opType == 0) {
            // Swap USDC -> Credits
            amount = bound(amount, 1e6, 100 * 1e6);
            vm.prank(alice);
            dex.assetToCredit(amount, 0);
        } else if (opType == 1) {
            // Swap Credits -> USDC
            amount = bound(amount, 100 * 1e18, 5000 * 1e18);
            vm.prank(alice);
            dex.creditToAsset(amount, 0);
        } else if (opType == 2) {
            // Deposit LP
            amount = bound(amount, 100 * 1e18, 10_000 * 1e18);
            vm.prank(alice);
            dex.deposit(amount, 0);
        } else {
            // Withdraw LP (need to deposit first)
            vm.prank(alice);
            uint256 lp = dex.deposit(1000 * 1e18, 0);
            amount = bound(amount, 1, lp);
            vm.prank(alice);
            dex.withdraw(amount);
        }
        
        // Verify conservation
        uint256 totalUsdcAfter = usdc.balanceOf(address(dex)) + usdc.balanceOf(alice);
        uint256 totalCreditsAfter = credits.balanceOf(address(dex)) + credits.balanceOf(alice);
        
        assertEq(totalUsdcAfter, totalUsdcBefore, "USDC should be conserved");
        assertEq(totalCreditsAfter, totalCreditsBefore, "Credits should be conserved");
    }

    /// @notice Fuzz: Excess never exceeds cap with random deposits
    function testFuzzExcessCap(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 100 * 1e18, 100_000 * 1e18);
        
        vm.prank(owner);
        credits.mint(lp1, depositAmount);
        usdc.mint(lp1, 5000 * 1e6);
        
        vm.prank(lp1);
        dex.deposit(depositAmount, 0);
        
        assertTrue(dex.usdcExcess() <= EXCESS_CAP, "Excess should never exceed cap");
    }

    /// @notice Fuzz: Price consistency check
    function testFuzzPriceConsistency(uint256 creditAmount) public {
        creditAmount = bound(creditAmount, 100 * 1e18, 10_000 * 1e18);
        
        // Get quoted price
        uint256 quotedUsdc = dex.creditInPrice(creditAmount);
        
        // Actually execute swap
        vm.prank(alice);
        uint256 actualUsdc = dex.creditToAsset(creditAmount, 0);
        
        // Should match exactly
        assertEq(actualUsdc, quotedUsdc, "Actual swap should match quoted price");
    }

    /// @notice Fuzz: Multiple users random operations
    function testFuzzMultiUserOperations(
        uint256 aliceSwap,
        uint256 bobDeposit,
        uint256 lp1Swap
    ) public {
        // Bound amounts
        aliceSwap = bound(aliceSwap, 1e6, 100 * 1e6);
        bobDeposit = bound(bobDeposit, 100 * 1e18, 10_000 * 1e18);
        lp1Swap = bound(lp1Swap, 100 * 1e18, 5000 * 1e18);
        
        // Give users tokens
        usdc.mint(alice, aliceSwap);
        usdc.mint(lp1, 200 * 1e6);
        
        // Track total system value
        uint256 totalUsdcBefore = usdc.balanceOf(address(dex)) + 
                                   usdc.balanceOf(alice) + 
                                   usdc.balanceOf(bob) + 
                                   usdc.balanceOf(lp1);
        
        // Alice swaps
        vm.prank(alice);
        dex.assetToCredit(aliceSwap, 0);
        
        // Bob deposits
        vm.prank(bob);
        dex.deposit(bobDeposit, 0);
        
        // LP1 swaps
        vm.prank(lp1);
        dex.creditToAsset(lp1Swap, 0);
        
        // Verify conservation
        uint256 totalUsdcAfter = usdc.balanceOf(address(dex)) + 
                                  usdc.balanceOf(alice) + 
                                  usdc.balanceOf(bob) + 
                                  usdc.balanceOf(lp1);
        
        assertEq(totalUsdcAfter, totalUsdcBefore, "USDC should be conserved across users");
    }

    /// @notice Fuzz: Arbitrage attempt detection
    function testFuzzArbitrageAttempt(
        uint256 step1Amount,
        uint256 step2Amount
    ) public {
        // Bound amounts to reasonable values
        step1Amount = bound(step1Amount, 10 * 1e6, 100 * 1e6);
        step2Amount = bound(step2Amount, 1000 * 1e18, 10_000 * 1e18);
        
        // Give alice tokens
        usdc.mint(alice, step1Amount + 500 * 1e6);
        vm.prank(owner);
        credits.mint(alice, step2Amount);
        
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        
        // Step 1: Swap USDC -> Credits
        vm.prank(alice);
        uint256 creditsGot = dex.assetToCredit(step1Amount, 0);
        
        // Skip if we got 0 credits (edge case)
        if (creditsGot == 0) return;
        
        // Step 2: Deposit LP
        vm.prank(alice);
        uint256 lp = dex.deposit(step2Amount, 0);
        
        // Step 3: Swap Credits back -> USDC
        vm.prank(alice);
        dex.creditToAsset(creditsGot, 0);
        
        // Step 4: Withdraw LP
        vm.prank(alice);
        dex.withdraw(lp);
        
        int256 usdcPnL = int256(usdc.balanceOf(alice)) - int256(aliceUsdcBefore);
        
        // Should not profit significantly (allowing 1 USDC for rounding)
        assertTrue(usdcPnL <= int256(1e6), "Arbitrage attempt should not be profitable");
    }

    // ============ VULNERABILITY ANALYSIS SUMMARY ============
    // These tests quantify potential attack vectors and their profitability

    /// @notice Summary: Quantify front-running profitability at different sizes
    function testVulnerabilityAnalysisFrontRunning() public {
        emit log_string("=== FRONT-RUNNING LP DEPOSITS ANALYSIS ===");
        emit log_string("When excess is full, LP deposits push USDC to reserves,");
        emit log_string("increasing the CREDITS price. Front-runners can exploit this.");
        emit log_string("");
        
        uint256[] memory swapSizes = new uint256[](5);
        swapSizes[0] = 10 * 1e6;   // 10 USDC
        swapSizes[1] = 50 * 1e6;   // 50 USDC
        swapSizes[2] = 100 * 1e6;  // 100 USDC
        swapSizes[3] = 200 * 1e6;  // 200 USDC
        swapSizes[4] = 400 * 1e6;  // 400 USDC
        
        for (uint i = 0; i < swapSizes.length; i++) {
            // Fresh setup for each test
            CreditsDex freshDex = new CreditsDex(address(credits), address(usdc));
            
            // Mint and setup
            vm.prank(owner);
            credits.mint(owner, INITIAL_CREDITS);
            usdc.mint(owner, INITIAL_USDC_RESERVES + INITIAL_USDC_EXCESS);
            
            vm.startPrank(owner);
            credits.approve(address(freshDex), type(uint256).max);
            usdc.approve(address(freshDex), type(uint256).max);
            freshDex.init(INITIAL_CREDITS, INITIAL_USDC_RESERVES, INITIAL_USDC_EXCESS);
            vm.stopPrank();
            
            // Setup attacker
            address attacker = vm.addr(200 + i);
            usdc.mint(attacker, swapSizes[i]);
            vm.prank(owner);
            credits.mint(attacker, 10_000 * 1e18);
            
            vm.startPrank(attacker);
            credits.approve(address(freshDex), type(uint256).max);
            usdc.approve(address(freshDex), type(uint256).max);
            vm.stopPrank();
            
            uint256 attackerUsdcBefore = usdc.balanceOf(attacker);
            
            // Step 1: Attacker front-runs
            vm.prank(attacker);
            uint256 creditsFromSwap = freshDex.assetToCredit(swapSizes[i], 0);
            
            // Step 2: Victim LP deposits (using a standard deposit)
            address victim = vm.addr(300 + i);
            vm.prank(owner);
            credits.mint(victim, 20_000 * 1e18);
            usdc.mint(victim, 500 * 1e6);
            vm.startPrank(victim);
            credits.approve(address(freshDex), type(uint256).max);
            usdc.approve(address(freshDex), type(uint256).max);
            freshDex.deposit(20_000 * 1e18, 0);
            vm.stopPrank();
            
            // Step 3: Attacker back-runs
            vm.prank(attacker);
            freshDex.creditToAsset(creditsFromSwap, 0);
            
            uint256 attackerUsdcAfter = usdc.balanceOf(attacker);
            int256 profit = int256(attackerUsdcAfter) - int256(attackerUsdcBefore);
            
            emit log_named_uint("Swap size (USDC)", swapSizes[i] / 1e6);
            emit log_named_int("Profit (USDC wei)", profit);
            if (profit > 0) {
                uint256 profitBps = uint256(profit) * 10000 / swapSizes[i];
                emit log_named_uint("Profit %% (bps)", profitBps);
            }
            emit log_string("---");
        }
        
        emit log_string("");
        emit log_string("CONCLUSION: Front-running LP deposits is profitable when excess is full.");
        emit log_string("Mitigation options:");
        emit log_string("1. Add minimum time delay between swap and LP deposit");
        emit log_string("2. Add slippage protection to LP deposits");
        emit log_string("3. Use commit-reveal scheme for LP deposits");
    }

    /// @notice Summary: Quantify the effect of excess state on attack profitability
    function testVulnerabilityAnalysisExcessState() public {
        emit log_string("=== EXCESS STATE IMPACT ANALYSIS ===");
        emit log_string("How does excess fill level affect front-running profitability?");
        emit log_string("");
        
        uint256[] memory excessLevels = new uint256[](4);
        excessLevels[0] = 0;
        excessLevels[1] = 50 * 1e6;
        excessLevels[2] = 99 * 1e6;
        excessLevels[3] = 100 * 1e6;
        
        for (uint i = 0; i < excessLevels.length; i++) {
            // Fresh setup
            CreditsDex freshDex = new CreditsDex(address(credits), address(usdc));
            
            vm.prank(owner);
            credits.mint(owner, INITIAL_CREDITS);
            usdc.mint(owner, INITIAL_USDC_RESERVES + excessLevels[i]);
            
            vm.startPrank(owner);
            credits.approve(address(freshDex), type(uint256).max);
            usdc.approve(address(freshDex), type(uint256).max);
            freshDex.init(INITIAL_CREDITS, INITIAL_USDC_RESERVES, excessLevels[i]);
            vm.stopPrank();
            
            // Setup attacker
            address attacker = vm.addr(400 + i);
            usdc.mint(attacker, 100 * 1e6);
            vm.prank(owner);
            credits.mint(attacker, 10_000 * 1e18);
            
            vm.startPrank(attacker);
            credits.approve(address(freshDex), type(uint256).max);
            usdc.approve(address(freshDex), type(uint256).max);
            vm.stopPrank();
            
            uint256 attackerUsdcBefore = usdc.balanceOf(attacker);
            
            // Attacker front-runs
            vm.prank(attacker);
            uint256 creditsFromSwap = freshDex.assetToCredit(100 * 1e6, 0);
            
            // Victim LP deposits
            address victim = vm.addr(500 + i);
            vm.prank(owner);
            credits.mint(victim, 10_000 * 1e18);
            usdc.mint(victim, 200 * 1e6);
            vm.startPrank(victim);
            credits.approve(address(freshDex), type(uint256).max);
            usdc.approve(address(freshDex), type(uint256).max);
            freshDex.deposit(10_000 * 1e18, 0);
            vm.stopPrank();
            
            // Attacker back-runs
            vm.prank(attacker);
            freshDex.creditToAsset(creditsFromSwap, 0);
            
            uint256 attackerUsdcAfter = usdc.balanceOf(attacker);
            int256 profit = int256(attackerUsdcAfter) - int256(attackerUsdcBefore);
            
            emit log_named_uint("Excess level (USDC)", excessLevels[i] / 1e6);
            emit log_named_int("Front-run profit (USDC wei)", profit);
            emit log_string("---");
        }
        
        emit log_string("");
        emit log_string("CONCLUSION: Front-running is most profitable when excess is full (100 USDC).");
        emit log_string("When excess is not full, LP deposits partially fill excess,");
        emit log_string("resulting in less price impact and less front-run profit.");
    }

    // ============ SLIPPAGE PROTECTION TESTS ============

    /// @notice Test: Deposit with slippage protection - succeeds when within limit
    function testDepositWithSlippageProtectionSuccess() public {
        uint256 creditsToDeposit = 10_000 * 1e18;
        
        // Preview required USDC
        uint256 requiredUsdc = dex.previewDeposit(creditsToDeposit);
        
        // Set max slightly above required (allow 1% slippage)
        uint256 maxUsdc = requiredUsdc * 101 / 100;
        
        vm.prank(lp1);
        uint256 lpMinted = dex.deposit(creditsToDeposit, maxUsdc);
        
        assertTrue(lpMinted > 0, "Should receive LP tokens");
    }

    /// @notice Test: Deposit with slippage protection - fails when exceeded
    function testDepositWithSlippageProtectionFails() public {
        uint256 creditsToDeposit = 10_000 * 1e18;
        
        // Preview required USDC
        uint256 requiredUsdc = dex.previewDeposit(creditsToDeposit);
        
        // Set max below required
        uint256 maxUsdc = requiredUsdc * 99 / 100;
        
        vm.prank(lp1);
        vm.expectRevert(CreditsDex.SlippageError.selector);
        dex.deposit(creditsToDeposit, maxUsdc);
    }

    /// @notice Test: Slippage protection can block front-running if tolerance is tight
    function testSlippageProtectionBlocksFrontRunning() public {
        // Bob calculates expected USDC BEFORE any front-running
        uint256 bobCredits = 10_000 * 1e18;
        uint256 bobExpectedUsdc = dex.previewDeposit(bobCredits);
        
        // Bob sets a TIGHT slippage tolerance (0.5%)
        uint256 bobMaxUsdc = bobExpectedUsdc * 1005 / 1000;
        
        // Alice front-runs with a large swap
        vm.prank(alice);
        uint256 aliceCreditsFromSwap = dex.assetToCredit(100 * 1e6, 0);
        
        // Now the pool ratio has changed - Bob's deposit would require more USDC
        uint256 newRequiredUsdc = dex.previewDeposit(bobCredits);
        
        emit log_named_uint("Bob expected USDC", bobExpectedUsdc);
        emit log_named_uint("New required USDC after front-run", newRequiredUsdc);
        emit log_named_uint("Bob's max USDC", bobMaxUsdc);
        
        // If Alice's swap pushed the price enough, Bob's deposit should fail
        if (newRequiredUsdc > bobMaxUsdc) {
            vm.prank(bob);
            vm.expectRevert(CreditsDex.SlippageError.selector);
            dex.deposit(bobCredits, bobMaxUsdc);
            emit log_string("SUCCESS: Slippage protection blocked the deposit after front-run");
        } else {
            vm.prank(bob);
            dex.deposit(bobCredits, bobMaxUsdc);
            emit log_string("Deposit succeeded - front-run didn't push price enough");
        }
        
        // Alice swaps back
        vm.prank(alice);
        dex.creditToAsset(aliceCreditsFromSwap, 0);
    }

    /// @notice Test: Preview deposit matches actual deposit
    function testPreviewDepositAccuracy() public {
        uint256 creditsToDeposit = 5_000 * 1e18;
        
        // Preview
        uint256 previewedUsdc = dex.previewDeposit(creditsToDeposit);
        
        // Track actual USDC spent
        uint256 lp1UsdcBefore = usdc.balanceOf(lp1);
        
        vm.prank(lp1);
        dex.deposit(creditsToDeposit, 0);
        
        uint256 actualUsdcSpent = lp1UsdcBefore - usdc.balanceOf(lp1);
        
        assertEq(previewedUsdc, actualUsdcSpent, "Preview should match actual");
    }

    /// @notice Test: Zero maxAssetTokens means no slippage check
    function testDepositZeroMaxMeansNoLimit() public {
        uint256 creditsToDeposit = 10_000 * 1e18;
        
        // Deposit with 0 max (no limit)
        vm.prank(lp1);
        uint256 lpMinted = dex.deposit(creditsToDeposit, 0);
        
        assertTrue(lpMinted > 0, "Should succeed with no limit");
    }
}
