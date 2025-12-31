# 🎰 DAMM

> **D**IFFERENT + **A**utomated **M**arket **M**aker (some crying in the casino)

A hybrid DEX and gambling protocol where **CREDITS token holders are the house**. LPs earn swap fees but also provide the house's bankroll (the excess buffer) - they take on the gambling risk in exchange for their share of any profits.

## Core Concept

DAMM combines a traditional AMM DEX with a gambling mechanism. The key innovation is the **Excess Pool** - a USDC buffer that:

1. **Protects swap pricing** from gambling volatility
2. **Absorbs gambling winnings** without tanking the CREDITS price
3. **Overflows profits to reserves** when full, appreciating CREDITS

```
┌─────────────────────────────────────────────────────────────┐
│                      CreditsDex Contract                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  RESERVES (determines swap price)                           │
│  ┌─────────────────┬─────────────────┐                      │
│  │  USDC Reserves  │  CREDITS        │                      │
│  │  (pricing only) │  Reserves       │                      │
│  └─────────────────┴─────────────────┘                      │
│           ↑                                                 │
│           │ overflow when excess > 100 USDC                 │
│           │                                                 │
│  EXCESS (house buffer, USDC only, max 100)                  │
│  ┌─────────────────┐                                        │
│  │  USDC Excess    │ ← gambling payments fill this first    │
│  │  (max 100)      │ ← winnings paid from here first        │
│  └─────────────────┘                                        │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  LP Token = share of (reserves + excess)                    │
│  Swap price = reserves ratio ONLY                           │
│  CREDITS = ownership stake in "the house"                   │
└─────────────────────────────────────────────────────────────┘
```

## How It Works

### The Excess Pool

The **Excess Pool** is a USDC buffer (capped at 100 USDC) that acts as the "house bankroll" for gambling:

| USDC Flow           | Where It Goes                     | Price Effect                  |
| ------------------- | --------------------------------- | ----------------------------- |
| Gambling payment    | Excess first, overflow → Reserves | UP when overflows             |
| Gambling win payout | Excess first, then Reserves       | DOWN only if reserves touched |
| LP deposit          | Excess first, overflow → Reserves | UP when overflows             |
| LP withdraw         | Proportional from both            | None                          |
| Swap                | Reserves only                     | Normal AMM                    |

### CREDITS = House Ownership

When you hold CREDITS, you're essentially owning a piece of the casino:

- **House wins** → Excess fills up → Overflows to reserves → **CREDITS price goes UP**
- **House loses** → Paid from excess first → Price stays stable until excess depleted
- **More LP capital** → Stronger house → **CREDITS price goes UP**

### Price Dynamics

```
Swap Price = USDC Reserves / CREDITS Reserves
```

The swap price is determined **only by reserves**, not by the excess. This means:

1. **Gambling wins don't immediately tank the price** - they drain from excess first
2. **Gambling losses accumulate in excess** - then overflow to reserves, appreciating CREDITS
3. **The house edge compounds** - over time, CREDITS should appreciate as the house profits

## Contracts

### Credits.sol

An ERC-20 token with EIP-3009 support for gasless meta-transactions:

- `transferWithAuthorization()` - Transfer tokens with a signed message
- `receiveWithAuthorization()` - Pull tokens with holder's signature
- Owner can `mint()` and `burn()`

### CreditsDex.sol

The hybrid DEX + Casino contract:

#### DEX Functions

- `init(credits, usdcReserves, usdcExcess)` - Initialize with reserves + house buffer
- `assetToCredit(amount, minOut)` - Swap USDC → CREDITS
- `creditToAsset(amount, minOut)` - Swap CREDITS → USDC
- `deposit(creditAmount)` - Provide LP (at total pool ratio)
- `withdraw(lpAmount)` - Remove LP (proportional share of everything)

#### Gambling Functions

- `roll()` - Pay 1 USDC for ~9% chance to win 10 USDC (~9% house edge)

#### View Functions

- `getUsdcReserves()` - USDC in reserves (for pricing)
- `getExcess()` - USDC in house buffer
- `getTotalUsdc()` - Total USDC (reserves + excess)
- `creditInPrice(amount)` / `assetInPrice(amount)` - Quote swap prices

## LP Economics

**LPs get a raw deal compared to simple token holders.** Here's the honest breakdown:

When you provide liquidity:

1. **Deposit ratio** = Total pool (reserves + excess) / CREDITS
2. **Your USDC** fills excess first, then overflows to reserves
3. **If excess is full**, all your USDC goes to reserves → **price increases**

When you withdraw:

1. You receive **proportional share** of reserves + excess
2. Excess is reduced proportionally
3. Price stays stable

### The Tradeoff

| Role                        | What You Get                                | What You Risk                           |
| --------------------------- | ------------------------------------------- | --------------------------------------- |
| **CREDITS holder** (non-LP) | Token appreciation when house profits       | Token depreciation if reserves depleted |
| **LP**                      | 0.3% swap fees + proportional share of pool | Your capital IS the house bankroll      |

**The catch:** LPs are literally funding the gambling buffer. When the house wins, profits sit in excess (which LPs own proportionally) and eventually overflow to reserves (appreciating CREDITS). But LPs provided that capital in the first place - they're not getting "free" exposure to casino profits, they're taking the risk.

**Why LP anyway?**

- Swap fees (0.3% on every trade)
- In the long run, the 9% house edge should grow the pool
- Your USDC share grows as the house profits
- CREDITS token price appreciation benefits everyone

## Gambling Mechanics

### Current Implementation (Gameable - Testing Only!)

```solidity
function roll() external returns (bool won) {
    // Pay 1 USDC
    assetToken.transferFrom(msg.sender, address(this), ROLL_COST);
    _processRollPayment(ROLL_COST);  // → fills excess first

    // Gameable randomness (DO NOT USE IN PRODUCTION)
    uint256 random = uint256(blockhash(block.number - 1));
    won = (random % 11) == 0;  // ~9% win rate

    if (won) {
        _processWinPayout(ROLL_PAYOUT);  // → drains excess first
        assetToken.transfer(msg.sender, ROLL_PAYOUT);  // 10 USDC
    }
}
```

**Math:**

- Cost: 1 USDC
- Win probability: 1/11 ≈ 9.09%
- Payout: 10 USDC
- Expected value: 0.909 USDC
- **House edge: ~9.1%**

⚠️ **Warning:** Uses `blockhash` for randomness - easily gameable by miners/validators. Will be replaced with Chainlink VRF or similar for production.

## Example Scenarios

### Scenario 1: House Profits

```
Initial: 1000 USDC reserves + 100 USDC excess + 100,000 CREDITS
Price: 1000/100,000 = 0.01 USDC per CREDIT

10 players roll, all lose (10 USDC collected)
→ Excess tries to add 10 USDC but already at cap
→ 10 USDC overflows to reserves

After: 1010 USDC reserves + 100 USDC excess + 100,000 CREDITS
Price: 1010/100,000 = 0.0101 USDC per CREDIT (+1%)
```

### Scenario 2: House Pays Out (Protected)

```
Initial: 1000 USDC reserves + 100 USDC excess + 100,000 CREDITS
Price: 0.01 USDC per CREDIT

1 player rolls and wins 10 USDC
→ 1 USDC payment → excess (now 101, caps at 100, 1 → reserves)
→ 10 USDC payout from excess

After: 1001 USDC reserves + 90 USDC excess + 100,000 CREDITS
Price: 1001/100,000 = 0.01001 USDC per CREDIT (barely changed!)
```

### Scenario 3: Excess Depleted (Price Impact)

```
Initial: 1000 USDC reserves + 10 USDC excess + 100,000 CREDITS
Price: 0.01 USDC per CREDIT

1 player rolls and wins 10 USDC
→ 1 USDC payment → excess (now 11)
→ 10 USDC payout: 11 from excess (depletes it) + need 0 more from reserves

After: 1001 USDC reserves + 1 USDC excess + 100,000 CREDITS
Price: 1001/100,000 = 0.01001 (still protected!)

If excess was 0 and player won:
→ Full 10 USDC comes from reserves
→ Price drops more significantly
```

## Quickstart

1. Install dependencies:

```bash
yarn install
```

2. Run a local network:

```bash
yarn chain
```

3. Deploy contracts:

```bash
yarn deploy
```

4. Start the frontend:

```bash
yarn start
```

Visit `http://localhost:3000` to interact with the DEX and gambling features.

## Testing

```bash
yarn foundry:test
```

Tests cover:

- Excess pool initialization and caps
- Swap pricing (uses reserves only)
- LP deposits (fill excess first, overflow to reserves)
- LP withdrawals (proportional from total pool)
- Roll function (win/loss scenarios, excess drainage)

## Future Improvements

- [ ] Replace `blockhash` randomness with Chainlink VRF
- [ ] Add more gambling games (blackjack, dice, etc.)
- [ ] Configurable excess cap
- [ ] Multi-token gambling (pay with CREDITS?)
- [ ] Governance for house parameters

## Architecture

```
packages/
├── foundry/
│   ├── contracts/
│   │   ├── Credits.sol      # ERC-20 + EIP-3009
│   │   └── CreditsDex.sol   # DEX + Excess Pool + Gambling
│   ├── script/
│   │   ├── Deploy.s.sol
│   │   ├── DeployCredits.s.sol
│   │   └── DeployCreditsDex.s.sol
│   └── test/
│       ├── Credits.t.sol
│       └── CreditsDex.t.sol
└── nextjs/
    └── app/
        ├── credits/         # Credits token UI
        └── dex/             # DEX + gambling UI
```

## License

MIT
