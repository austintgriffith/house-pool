# 🎲 DAMM - Decentralized Automated Market Maker for Gambling

> A two-contract gambling protocol where **LP tokens = house ownership**. Deposit USDC to become the house.

## Architecture

DAMM separates concerns into two immutable contracts:

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│   ┌─────────────────────┐         ┌─────────────────────────────┐  │
│   │      DiceGame       │────────▶│         HousePool           │  │
│   │   (Game Logic)      │         │     (Liquidity Pool)        │  │
│   └─────────────────────┘         └─────────────────────────────┘  │
│            │                                    │                   │
│    - Commit/Reveal                     - USDC deposits             │
│    - Win/Loss logic                    - HOUSE token (ERC20)       │
│    - MIN_RESERVE check                 - Delayed withdrawals       │
│    - Calls payout()                    - payout() for game         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### DiceGame.sol

The game contract handles all betting logic:

- **Deploys HousePool** in its constructor with itself as the immutable game owner
- **Commit-reveal gambling** - fair randomness using player secret + blockhash
- **MIN_RESERVE tracking** - ensures enough liquidity for payouts
- **Calls `housePool.payout()`** when players win

### HousePool.sol

The liquidity pool contract:

- **Holds all USDC** from LP deposits and player bets
- **Issues HOUSE tokens** (ERC20) representing pool ownership
- **Delayed withdrawals** - 10 sec cooldown prevents front-running
- **`payout()` function** - only callable by the immutable game contract

## How It Works

### For LPs (House Owners)

1. **Deposit USDC** → Receive HOUSE tokens at current share price
2. **Hold** → As gamblers lose, pool grows, your shares worth more
3. **Withdraw** → Request withdrawal (10 sec cooldown) → Execute within 1 min window

```
Share Price = Total USDC / Total HOUSE Supply
Your Value = Your HOUSE × Share Price
```

### For Gamblers

Two-step commit-reveal process (prevents manipulation):

1. **Commit**: Pay $0.10 USDC, submit hash of your secret
2. **Wait**: 1+ blocks
3. **Reveal**: Submit secret, get result

| Parameter  | Value      |
| ---------- | ---------- |
| Cost       | $0.10 USDC |
| Win Chance | ~9%        |
| Payout     | $1 USDC    |
| House Edge | ~9%        |

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
canPlay = effectivePool >= MIN_RESERVE + ROLL_PAYOUT
```

Gambling is blocked if effective pool is too low.

## Contracts

### DiceGame.sol

| Function                    | Description                           |
| --------------------------- | ------------------------------------- |
| `commitRoll(hash)`          | Pay $0.10 USDC, commit hash of secret |
| `revealRoll(secret)`        | Reveal secret, get win/loss result    |
| `canPlay()`                 | Whether gambling is currently enabled |
| `checkRoll(player, secret)` | Preview result before revealing       |
| `getCommitment(player)`     | Get commitment details                |

**Constants:**

| Constant    | Value      | Description                          |
| ----------- | ---------- | ------------------------------------ |
| ROLL_COST   | $0.10 USDC | Cost to roll                         |
| ROLL_PAYOUT | $1 USDC    | Win payout                           |
| WIN_MODULO  | 11         | 1/11 win chance                      |
| MIN_RESERVE | $3 USDC    | Minimum pool for game to be playable |

### HousePool.sol

**LP Functions:**

| Function                            | Description                        |
| ----------------------------------- | ---------------------------------- |
| `deposit(usdcAmount)`               | Deposit USDC, receive HOUSE shares |
| `requestWithdrawal(shares)`         | Start 10 sec cooldown              |
| `withdraw()`                        | Execute within 1 min window        |
| `cancelWithdrawal()`                | Cancel pending request             |
| `cleanupExpiredWithdrawal(address)` | Anyone can clear expired requests  |

**View Functions:**

| Function             | Description                                   |
| -------------------- | --------------------------------------------- |
| `totalPool()`        | Total USDC in contract                        |
| `effectivePool()`    | Pool minus pending withdrawal value           |
| `sharePrice()`       | Current USDC per HOUSE (18 decimal precision) |
| `usdcValue(address)` | USDC value of an LP's holdings                |
| `game()`             | Address of the immutable game contract        |

**Game Functions (only callable by DiceGame):**

| Function                         | Description                  |
| -------------------------------- | ---------------------------- |
| `receivePayment(player, amount)` | Pull bet payment from player |
| `payout(player, amount)`         | Send winnings to player      |

**Constants:**

| Constant          | Value      | Description                |
| ----------------- | ---------- | -------------------------- |
| WITHDRAWAL_DELAY  | 10 seconds | Cooldown before withdrawal |
| WITHDRAWAL_WINDOW | 1 minute   | Time to execute withdrawal |
| MIN_FIRST_DEPOSIT | 1 USDC     | Minimum first deposit      |

## Quickstart

1. Install dependencies:

```bash
yarn install
```

2. Fork Base mainnet locally:

```bash
yarn fork --network base
```

3. Deploy contracts:

```bash
yarn deploy
```

4. Start the frontend:

```bash
yarn start
```

Visit `http://localhost:3000` to interact with DAMM.

## Testing

```bash
cd packages/foundry
forge test -vv
```

Tests cover:

- Deployment and immutable linkage
- Deposit/withdraw mechanics and share calculations
- Withdrawal cooldown and expiry
- Effective pool accounting
- Commit-reveal gambling flow
- Minimum reserve protections
- Authorization (only game can call payout)

## Project Structure

```
packages/
├── foundry/
│   ├── contracts/
│   │   ├── DiceGame.sol      # Game logic, deploys HousePool
│   │   └── HousePool.sol     # Liquidity pool, HOUSE token
│   ├── script/
│   │   └── Deploy.s.sol      # Deploys DiceGame (which deploys HousePool)
│   └── test/
│       └── HousePool.t.sol   # Tests for both contracts
└── nextjs/
    └── app/
        ├── page.tsx          # Gambling UI
        └── house/            # LP management UI
```

## Key Design Decisions

1. **Two contracts, immutable linkage**: DiceGame deploys HousePool with itself as the game. No admin functions, no way to change it.

2. **Game owns the pool**: Only DiceGame can call `payout()`. The relationship is set in the constructor and immutable.

3. **Separation of concerns**: HousePool only handles liquidity. DiceGame handles all betting logic and reserve checks.

4. **Commit-reveal gambling**: Prevents both miner manipulation and LP front-running.

5. **Withdrawal cooldown + expiry**: 10 sec wait, 1 min window. Prevents griefing (signaling but never withdrawing).

6. **Effective pool accounting**: Pending withdrawals reduce available liquidity immediately.

## License

MIT
