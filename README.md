# 🏠 House Pool

> A simplified gambling pool where **LP tokens = house ownership**. Deposit USDC to become the house.

## Core Concept

House Pool is a single-contract gambling protocol where:

- **One token (HOUSE)** represents your share of the USDC pool
- **Share price grows** as the house profits from gambling
- **No AMM complexity** - just deposit USDC, get HOUSE, withdraw at pool ratio

```
┌─────────────────────────────────────────────────────────────┐
│                      HousePool Contract                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              USDC Pool                              │   │
│  │  Deposits + Gambling Profits - Gambling Losses      │   │
│  └─────────────────────────────────────────────────────┘   │
│                          ↕                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │           HOUSE Token (ERC20)                       │   │
│  │  Your share of the pool = your HOUSE / total HOUSE  │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Share Price = Total USDC / Total HOUSE Supply             │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## How It Works

### For LPs (House Owners)

1. **Deposit USDC** → Receive HOUSE tokens at current share price
2. **Hold** → As gamblers lose, pool grows, your shares worth more
3. **Withdraw** → Request withdrawal (10 sec cooldown) → Execute within 1 min window

### For Gamblers

Two-step commit-reveal process (prevents manipulation):

1. **Commit**: Pay 1 USDC, submit hash of your secret
2. **Wait**: 2+ blocks
3. **Reveal**: Submit secret, get result

- **Cost**: 1 USDC
- **Win Chance**: ~9% (1/11)
- **Payout**: 10 USDC
- **House Edge**: ~9%

### Withdrawal Cooldown

To prevent front-running (LP sees winning reveal → tries to withdraw):

```
Request Withdrawal → 10 sec cooldown → 1 min window to execute → expires
```

If you don't execute within the window, request expires and you keep your HOUSE tokens.

### Effective Pool

The contract tracks "effective pool" - total USDC minus pending withdrawals:

```solidity
effectivePool = totalPool - (pendingWithdrawals value)
canRoll = effectivePool >= MIN_RESERVE + MAX_PAYOUT
```

Gambling is blocked if effective pool is too low.

### Auto Buyback & Burn (Optional)

When the pool exceeds a threshold (15 USDC), the contract can automatically:

1. Buy HOUSE tokens from Uniswap
2. Burn them

This keeps Uniswap price synced and makes HOUSE deflationary.

## Contract: HousePool.sol

Single contract that handles everything:

### LP Functions

- `deposit(usdcAmount)` - Deposit USDC, receive HOUSE shares
- `requestWithdrawal(shares)` - Start 10 sec cooldown
- `withdraw()` - Execute within 1 min window
- `cancelWithdrawal()` - Cancel pending request
- `cleanupExpiredWithdrawal(address)` - Anyone can clear expired requests

### Gambling Functions

- `commitRoll(hash)` - Pay 1 USDC, commit hash of secret
- `revealRoll(secret)` - After 2+ blocks, reveal to get result

### View Functions

- `totalPool()` - Total USDC in contract
- `effectivePool()` - Pool minus pending withdrawal value
- `sharePrice()` - Current USDC per HOUSE (18 decimal precision)
- `canRoll()` - Whether gambling is currently enabled
- `usdcValue(address)` - USDC value of an LP's holdings

### Owner Functions

- `mintForLiquidity(to, amount)` - One-time mint to seed Uniswap
- `setUniswapRouter(address)` - Configure Uniswap for buybacks

## Constants

| Constant          | Value      | Description                |
| ----------------- | ---------- | -------------------------- |
| ROLL_COST         | 1 USDC     | Cost to roll               |
| ROLL_PAYOUT       | 10 USDC    | Win payout                 |
| WIN_MODULO        | 11         | 1/11 win chance            |
| MIN_RESERVE       | 5 USDC     | Minimum pool for payouts   |
| BUYBACK_THRESHOLD | 15 USDC    | Trigger buyback above this |
| WITHDRAWAL_DELAY  | 10 seconds | Cooldown before withdrawal |
| WITHDRAWAL_WINDOW | 1 minute   | Time to execute withdrawal |

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

Visit `http://localhost:3000` to interact with the House Pool.

## Testing

```bash
cd packages/foundry
forge test --match-contract HousePoolTest -vv
```

Tests cover:

- Deposit/withdraw mechanics and share calculations
- Withdrawal cooldown and expiry
- Effective pool accounting
- Commit-reveal gambling flow
- Minimum reserve protections
- Owner functions

## Architecture

```
packages/
├── foundry/
│   ├── contracts/
│   │   └── HousePool.sol     # Single contract: ERC20 + Gambling + LP
│   ├── script/
│   │   ├── Deploy.s.sol
│   │   └── DeployHousePool.s.sol
│   └── test/
│       └── HousePool.t.sol
└── nextjs/
    └── app/
        ├── house/            # Main LP + gambling UI
        └── page.tsx          # Landing page
```

## Key Design Decisions

1. **One token, not two**: HOUSE = LP token = house ownership. No separate "credit" token.

2. **No AMM**: Share price is simply `totalUSDC / totalShares`. Trade on external DEXs if needed.

3. **Commit-reveal gambling**: Prevents both miner manipulation and LP front-running.

4. **Withdrawal cooldown + expiry**: 10 sec wait, 1 min window. Prevents griefing (signaling but never withdrawing).

5. **Effective pool accounting**: Pending withdrawals reduce available liquidity immediately.

## License

MIT
