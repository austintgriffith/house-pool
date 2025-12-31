# 🎲 Roll House

> An example of how to build your USDC app on top of existing DeFi to earn yield on your game treasury.

Deposit USDC to become the house. LP tokens = ownership. Idle funds auto-invest in Summer.fi to earn yield while you wait for bets.

## Architecture

Roll House separates concerns into three immutable contracts:

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                                                                                  │
│   ┌─────────────────────┐         ┌─────────────────────────────┐               │
│   │      DiceGame       │────────▶│         HousePool           │               │
│   │   (Game Logic)      │         │     (Liquidity Pool)        │               │
│   └─────────────────────┘         └──────────────┬──────────────┘               │
│            │                                      │                              │
│    - Commit/Reveal                               │                              │
│    - Win/Loss logic                              ▼                              │
│    - MIN_RESERVE check              ┌─────────────────────────────┐             │
│    - Calls payout()                 │       VaultManager          │             │
│                                     │   (DeFi Yield Strategy)     │             │
│                                     └──────────────┬──────────────┘             │
│                                                    │                             │
│                                     - Deposits idle USDC                        │
│                                     - Summer.fi FleetCommander                  │
│                                     - Earns LVUSDC yield                        │
│                                                    │                             │
│                                                    ▼                             │
│                                     ┌─────────────────────────────┐             │
│                                     │    Summer.fi LVUSDC Vault   │             │
│                                     │     (External Protocol)     │             │
│                                     └─────────────────────────────┘             │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### DiceGame.sol

The game contract handles all betting logic:

- **Deploys VaultManager & HousePool** in its constructor, linking them together
- **Commit-reveal gambling** - fair randomness using player secret + blockhash
- **MIN_RESERVE tracking** - ensures enough liquidity for payouts
- **Calls `housePool.payout()`** when players win

### HousePool.sol

The liquidity pool contract:

- **Issues HOUSE tokens** (ERC20) representing pool ownership
- **Auto-invests USDC** - all idle USDC is deposited into VaultManager for yield
- **Delayed withdrawals** - 10 sec cooldown prevents front-running
- **`payout()` function** - only callable by the immutable game contract
- **Yield-aware accounting** - share price reflects total value (liquid + vault)

### VaultManager.sol

The DeFi yield strategy contract:

- **Integrates with Summer.fi** FleetCommander (LVUSDC) vault on Base
- **Automatic deposits** - HousePool sends all USDC here for yield generation
- **On-demand withdrawals** - pulls funds back when needed for payouts
- **One-time HousePool linkage** - immutable connection, no admin keys

## How It Works

### For LPs (House Owners)

1. **Deposit USDC** → Receive HOUSE tokens at current share price
2. **Hold** → Earn from gambling losses + DeFi yield (Summer.fi)
3. **Withdraw** → Request withdrawal (10 sec cooldown) → Execute within 1 min window

```
Total Value = Liquid USDC + Vault Value (with accrued yield)
Share Price = Total Value / Total HOUSE Supply
Your Value = Your HOUSE × Share Price
```

**Yield Sources:**

- 🎲 **Gambling Edge** - ~9% house edge on all bets
- 📈 **DeFi Yield** - Summer.fi FleetCommander vault returns

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

| Function                            | Description                                       |
| ----------------------------------- | ------------------------------------------------- |
| `deposit(usdcAmount)`               | Deposit USDC, receive HOUSE shares (auto-invests) |
| `deposit(usdcAmount, minSharesOut)` | Deposit with slippage protection                  |
| `requestWithdrawal(shares)`         | Start 10 sec cooldown                             |
| `withdraw()`                        | Execute within 1 min window                       |
| `withdraw(minUsdcOut)`              | Execute with slippage protection                  |
| `cancelWithdrawal()`                | Cancel pending request                            |
| `cleanupExpiredWithdrawal(address)` | Anyone can clear expired requests                 |

**View Functions:**

| Function             | Description                                   |
| -------------------- | --------------------------------------------- |
| `totalPool()`        | Total USDC value (liquid + vault)             |
| `liquidPool()`       | USDC held directly in contract                |
| `vaultPool()`        | USDC value in Summer.fi vault                 |
| `effectivePool()`    | Total pool minus pending withdrawal value     |
| `sharePrice()`       | Current USDC per HOUSE (18 decimal precision) |
| `usdcValue(address)` | USDC value of an LP's holdings                |
| `game()`             | Address of the immutable game contract        |
| `vaultManager()`     | Address of the VaultManager contract          |

**Game Functions (only callable by DiceGame):**

| Function                         | Description                                   |
| -------------------------------- | --------------------------------------------- |
| `receivePayment(player, amount)` | Pull bet payment from player (auto-invests)   |
| `payout(player, amount)`         | Send winnings to player (withdraws if needed) |

**Constants:**

| Constant          | Value      | Description                |
| ----------------- | ---------- | -------------------------- |
| WITHDRAWAL_DELAY  | 10 seconds | Cooldown before withdrawal |
| WITHDRAWAL_WINDOW | 1 minute   | Time to execute withdrawal |
| MIN_FIRST_DEPOSIT | 1 USDC     | Minimum first deposit      |

### VaultManager.sol

**Vault Functions (only callable by HousePool):**

| Function                               | Description                                   |
| -------------------------------------- | --------------------------------------------- |
| `depositIntoVault(amount)`             | Deposit USDC into Summer.fi vault (0 for all) |
| `withdrawFromVault(amount)`            | Withdraw USDC from vault (0 for max)          |
| `emergencyWithdraw(token, amount, to)` | Rescue stuck tokens if needed                 |

**View Functions:**

| Function            | Description                             |
| ------------------- | --------------------------------------- |
| `getCurrentValue()` | USDC value of vault position            |
| `getVaultShares()`  | Amount of LVUSDC shares held            |
| `getUSDCBalance()`  | USDC balance not yet deposited to vault |
| `getTotalValue()`   | Total USDC (vault + balance)            |
| `fleetCommander()`  | Summer.fi vault address                 |
| `housePool()`       | HousePool contract address              |

## Quickstart

1. Install dependencies:

```bash
yarn install
```

2. Fork Base mainnet locally (required for Summer.fi vault integration):

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

Visit `http://localhost:3000` to interact with Roll House.

> **Note:** The DeFi yield integration uses Summer.fi's FleetCommander vault (LVUSDC) which is deployed on Base. When running locally, you must fork Base mainnet to interact with the real vault contract.

## Testing

```bash
cd packages/foundry
forge test -vv
```

Tests cover:

- Deployment and immutable linkage (DiceGame → VaultManager → HousePool)
- Deposit/withdraw mechanics and share calculations
- Withdrawal cooldown and expiry
- Effective pool accounting (liquid + vault)
- Commit-reveal gambling flow
- Minimum reserve protections
- Authorization (only game can call payout, only HousePool can call vault)
- Vault integration (deposits, withdrawals, yield accounting)

## Project Structure

```
packages/
├── foundry/
│   ├── contracts/
│   │   ├── DiceGame.sol      # Game logic, deploys VaultManager + HousePool
│   │   ├── HousePool.sol     # Liquidity pool, HOUSE token, auto-invests
│   │   └── VaultManager.sol  # DeFi yield strategy (Summer.fi integration)
│   ├── script/
│   │   └── Deploy.s.sol      # Deploys DiceGame (which deploys the others)
│   └── test/
│       └── HousePool.t.sol   # Tests for all contracts
└── nextjs/
    └── app/
        ├── page.tsx          # Gambling UI
        └── house/            # LP management UI
```

## Key Design Decisions

1. **Three contracts, immutable linkage**: DiceGame deploys VaultManager and HousePool, linking them together. No admin functions, no way to change relationships.

2. **Game owns the pool**: Only DiceGame can call `payout()`. The relationship is set in the constructor and immutable.

3. **Separation of concerns**:

   - DiceGame handles betting logic and reserve checks
   - HousePool handles LP shares and withdrawal timing
   - VaultManager handles DeFi yield strategy

4. **Auto-invest strategy**: All idle USDC is automatically deposited to Summer.fi vault. Withdrawals happen on-demand when funds are needed.

5. **Commit-reveal gambling**: Prevents both miner manipulation and LP front-running.

6. **Withdrawal cooldown + expiry**: 10 sec wait, 1 min window. Prevents griefing (signaling but never withdrawing).

7. **Effective pool accounting**: Pending withdrawals reduce available liquidity immediately.

8. **Slippage protection**: Both `deposit()` and `withdraw()` accept optional minimum output parameters to protect against sandwich attacks.

## License

MIT
