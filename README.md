# PredictSwap

**Cross-chain prediction market arbitrage and liquidity protocol.**

Identical real-world events trade at different prices across fragmented prediction market platforms. PredictSwap is the first permissionless venue for 1:1 swaps between shares on any two ERC-1155 prediction market platforms — same outcome, different platforms, one pool.

---

## How It Works

YES shares for the same event on two platforms should cost exactly the same. In practice they don't, due to low liquidity and no cross-platform arbitrage infrastructure. PredictSwap fixes this:

1. **Bridge** — For cross-chain markets, users lock ERC-1155 shares on the source chain via an escrow contract. LayerZero V2 relays the message to the destination chain, where a receiver contract mints 1:1 wrapped tokens.
2. **Pool** — Each `SwapPool` holds one matched pair (marketA tokenId ↔ marketB tokenId). Both sides are treated as economically equivalent.
3. **Swap** — Users deposit one side and receive the other, minus a per-pool fee (default 0.40% — 0.30% to LPs, 0.10% protocol).
4. **Liquidity** — LPs deposit single-sided. LP positions accrue fees automatically through per-side rate growth — no claiming needed.

```
Source Chain                          Destination Chain
──────────────────────────────────────────────────────
Market A ERC-1155                     Market B ERC-1155
     │                                      (native)
  Escrow                                       │
     │                                         │
     └──── LayerZero V2 ────► BridgeReceiver   │
                                     │         │
                               WrappedToken    │
                                     │         │
                                     └── SwapPool ──┘
                                        (1:1 AMM)
```

Same-chain markets skip the bridge entirely — `SwapPool` works with any two ERC-1155 contracts on the same chain.

---

## Pool Mechanics

Each pool tracks two scalar accounting values — one per LP side — and derives a rate for each:

```
aSideValue    — total normalized value owed to marketA-LP holders
bSideValue    — total normalized value owed to marketB-LP holders

marketARate   = aSideValue * 1e18 / marketALpSupply     (1e18 scaled, starts at 1e18)
marketBRate   = bSideValue * 1e18 / marketBLpSupply

lpToMint      = normAmount * sideSupply / sideValue     (1:1 on first deposit)
claim         = lpAmount   * rate       / 1e18
```

Invariant (held after every operation):

```
aSideValue + bSideValue == physicalBalanceNorm(A) + physicalBalanceNorm(B)
```

All pool math operates in a shared 18-decimal normalized space. Raw balances are stored in each token's native decimals. Pairs with different decimal precisions (e.g. 6-decimal and 18-decimal shares) are handled without value distortion.

**Rate growth is per-side.** A MARKET_A → MARKET_B swap drains B reserves, so the LP fee is credited to `bSideValue` only — `marketBRate` grows, `marketARate` unchanged. Symmetric for the reverse. Same-side withdrawals keep their LP fee on the burning side; cross-side withdrawals credit it to the side whose physical tokens paid out the claim.

### Fee Calculation

Fees are set per-pool at creation time and adjustable by the factory owner. Computed as a single ceiling-rounded total, then split between LP and protocol:

```
totalFee    = ceil(amount * (lpFeeBps + protocolFeeBps) / FEE_DENOMINATOR)
protocolFee = (totalFee * protocolFeeBps) / (lpFeeBps + protocolFeeBps)
lpFee       = totalFee - protocolFee
```

A single ceiling rounding (not one per component) ensures the aggregate fee never exceeds one rounding unit above the configured rate, while still guaranteeing at least 1 unit of fee on any non-zero amount with non-zero bps.

### Fee application examples

There are 3 possible operation that requires fee payment - swap, withdraw cross-side, withdraw fresh liquidity

At any time pool is balanced by as
``` aSideValue + bSideValue == totalPoolMarketSharesA + totalPoolMarketSharesB ```

SideValue might be considered as totalSideLP * LPprice as it increases with fees gathered by LPs

Particular pool composition varies based on current market condition. That has direct influence on 
the way fees are distributed to the LP holders, as in examples below

#### 1. Swaps

| Type                                         | Shares in pool A:B     | SideValue A:B      | Operaion        |Fees goes to |
|----------------------------------------------|------------------------|--------------------|-----------------|-----------------|
| sufficient liqudity providers from both sides          | 510:1000               | 750:750 | Swap 150 A -> B        | all to B LP (increase bSideValue)
| insufficient liqudity providers on drained side          | 510:1000               | 1450:50 | Swap 900 A -> B        | both LPs. Fees from 50/900 to B LP, from 850/900 to A LP
| no liqudity providers on drained side          | 510:1000               | 1500:0 | Swap 900 A -> B        | all to A LP as no B LP


#### 2. Withdrawl old or fresh liquidity cross-side (Same as swaps)

| Type                                         | Shares in pool A:B     | SideValue A:B      | Operaion        |Fees goes to |
|----------------------------------------------|------------------------|--------------------|-----------------|-----------------|
| sufficient liqudity providers from both sides          | 510:1000               | 750:750 | A side LP withdraw 150 B shares       | all to B LP 
| insufficient liqudity providers on drained side          | 510:1000               | 1450:50 | A side LP withdraw 900 B shares        | both LPs. Fees from 50/900 to B LP, from 850/900 to A LP
| no liqudity providers on drained side          | 510:1000               | 1500:0 | Swap 900 A -> B        | all to A LP as no B LP          | 510:1000               | 1500:0 | A side LP withdraw 900 B shares        | all to A LP as no B LP


#### 3. Withdrawl fresh liquidity same-side
| Type                                         | Shares in pool A:B     | SideValue A:B      | Operaion        |Fees goes to |
|----------------------------------------------|------------------------|--------------------|-----------------|-----------------|
| sufficient liqudity providers from both sides          | 510:1000               | 750:750 | A side LP withdraw 150 A shares        | all to A LP 
| last LP withdraw          | 510:1000               | 500:1000 | user is the last LP on side A and withdraw side A fully        | all to B LP 
---

## Withdrawals

Two functions, selected by pool state:

| `swapsPaused` | Function callable        | Cross-side fee       | Same-side fee                   |
|---------------|--------------------------|----------------------|---------------------------------|
| `false`       | `withdrawal(...)`        | 0.4% (0 if resolved) | 0 (JIT only on fresh LP)        |
| `true`        | `withdrawProRata(...)`   | —                    | Never charged                   |

**Governing rule:** `swapsPaused` picks the function; `resolved` toggles fees inside `withdrawal`.

### `withdrawal(Side receiveSide, uint256 lpAmount, Side lpSide)`

Single entry point for the happy-path exit. The caller chooses which LP side to burn and which asset to be paid in.

- **Same-side** (`receiveSide == lpSide`): free, unless part of the burn comes from the caller's *fresh* LP bucket (deposited ≤ 24h ago). The JIT fee applies only to the overhang — `max(0, lpAmount − matured)` — not the whole claim. If `resolved`, no JIT fee even on fresh LP.
- **Cross-side** (`receiveSide != lpSide`): full 0.4% on the claim when `!resolved`; free when `resolved`. The LP fee is credited to `receiveSide` — the side whose physical tokens paid out the claim — so the remaining LPs of the side that actually provided liquidity are rewarded.
- Reverts `SwapsPaused` if swaps are paused (caller should use `withdrawProRata` instead).
- Reverts `InsufficientLiquidity(available, required)` if `physicalBalanceNorm(receiveSide) < payout + protocolFee`. When a side is illiquid, the caller either flips to the other side or waits for the operator to pause swaps (enabling pro-rata).

### `withdrawProRata(uint256 lpAmount, Side lpSide)`

Pause-gated exit: only callable while `swapsPaused == true` (reverts `SwapsNotPaused` otherwise). Never charges a fee — even on fresh LP.

Computes the caller's proportional share of the native-side physical balance, capped at their value claim. Any shortfall is paid in cross-side tokens:

```
nativeShare = (lpAmount * physicalBalanceNorm(nativeSide)) / sideSupply
if nativeShare > claim:  nativeShare = claim      // cap at user's claim
crossShare  = claim - nativeShare                 // paid in cross-side tokens
```

This guarantees safety during an emergency pause: each LP walks away with no more than their proportional share of the side's physical reserves, plus the remainder in cross-side tokens. No LP can drain the pool ahead of another.

### The 24-hour JIT lock (two-bucket model)

Each LP position is implicitly split into two buckets at the LPToken level:

- **Matured** — deposited > 24 h ago. No fee on withdrawal.
- **Fresh**   — deposited ≤ 24 h ago. JIT fee applies on the fresh portion of a burn (when not resolved, same-side path).

Only the fresh bucket is stored (`FreshDeposit { amount, timestamp }`); matured is derived as `balance − fresh.amount`. On withdrawal, matured is consumed first — so topping up a long-held position with a small new deposit only subjects the new deposit to the JIT fee, not the whole balance. Transfers-in are always fresh at the recipient — maturity does not propagate across wallets.

### State matrix

| `swapsPaused` | `resolved` | Function      | Same-side fee            | Cross-side fee |
|---------------|------------|---------------|--------------------------|----------------|
| F             | F          | `withdrawal`  | JIT on fresh portion     | 0.4%           |
| F             | T          | `withdrawal`  | Free                     | Free           |
| T             | F          | `withdrawProRata` | Free (always)        | —              |
| T             | T          | `withdrawProRata` | Free (always)        | —              |

### Flush residual

When both LP supplies hit zero, any remaining physical balance is swept to the `FeeCollector` and both accounting scalars are zeroed. Triggered at the end of both `withdrawal` and `withdrawProRata`, so the last LP leaving never traps dust.

---

## Architecture

### Pool layer (any two ERC-1155 markets)

| Contract | Role |
|---|---|
| `PoolFactory` | Deploys pools, maintains registry, manages operator role. Hard-bound to ONE marketA↔marketB contract pair at deploy (`marketAContract`, `marketBContract` immutable). Owns two `LPToken` instances (one per side) used across all pools on this factory. |
| `SwapPool` | 1:1 AMM per matched market pair. Stores `aSideValue` / `bSideValue` accounting and withdrawal/swap/deposit logic. |
| `LPToken` | Generic ERC-1155 LP token, deployed twice per factory (one instance per side). Each instance serves every pool on its side — the pool's LP tokenId mirrors the underlying prediction-market tokenId. Maintains the per-user fresh/matured lock bucket. |
| `FeeCollector` | Accumulates protocol fees across all pools. |

One factory serves one project pair (e.g. Polymarket↔PredictFun). For a different pair, deploy a second factory. Project display names (`marketAName`, `marketBName`) are stored once on the factory at deploy; per-pool metadata is limited to a free-form `eventDescription_` string that flows only into the `PoolCreated` event for indexing.

### Bridge layer (cross-chain pairs)

| Contract | Role |
|---|---|
| `Escrow` | Locks ERC-1155 shares on source chain, sends LayerZero message |
| `BridgeReceiver` | Receives LayerZero message, mints/burns wrapped tokens on destination chain |
| `WrappedToken` | ERC-1155 wrapper, 1:1 backed by locked shares on source chain |

Cross-chain messaging uses **LayerZero V2 OApp**. Native tokens stay on their home chains — no token bridging, only message passing. Same-chain market pairs require no bridge at all.

### Roles

| Role | Permissions |
|---|---|
| Owner (multisig) | `setFeeCollector`, `setOperator`, `setPoolFees`, `rescuePool*` |
| Operator (EOA) | `createPool`, `setPoolDepositsPaused`, `setPoolSwapsPaused`, `setResolvePool(poolId, bool)` (idempotent resolve toggle), `resolvePoolAndPause(poolId)` (atomic: sets `resolved` + `depositsPaused` + `swapsPaused`) |

The owner can perform all operator actions. The operator cannot touch fees or rescue funds.

---

## Development

Built with [Foundry](https://book.getfoundry.sh/).

### Prerequisites

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Build & Test

```bash
forge build
forge test                  # 47 tests passing
forge fmt
forge snapshot
```

---

## Deployment

All deploy scripts require environment variables to be loaded first:

```bash
source .env
```

### 1. Deploy mock market tokens (testnet only)

```bash
forge script script/integration_tests/DeployMockPoly.s.sol \
  --rpc-url $POLYGON_RPC_URL --broadcast
```

Add `MARKET_A_CONTRACT`, `MARKET_B_CONTRACT`, `MARKET_A_TOKEN_ID`, `MARKET_B_TOKEN_ID` to `.env`.

### 2. Deploy FeeCollector + PoolFactory

The factory constructor takes both market contracts as immutables along with project and LP instance names:

```
new PoolFactory(
    marketAContract, marketBContract,
    feeCollector, operator, owner,
    "Polymarket", "PredictFun",         // project names
    "Polymarket LP", "PredictFun LP"    // LP ERC-1155 instance names
)
```

Add `FEE_COLLECTOR_ADDRESS` and `POOL_FACTORY_ADDRESS` to `.env`.

### 3. Create a pool

No whitelist step — the factory is already bound to its two market contracts.

```bash
forge script script/CreatePool.s.sol \
  --rpc-url $POLYGON_RPC_URL --broadcast
```

The operator passes a `MarketConfig` per side (`tokenId`, `decimals`) plus a free-form event-description string. Market tokenIds are **strictly non-reusable** across pools on either side within a factory — `createPool` reverts on reuse.

---

## Integration Testing

```bash
# Deposit
forge script script/integration_tests/Deposit.s.sol \
  --rpc-url $POLYGON_RPC_URL --broadcast

# Swap
forge script script/integration_tests/Swap.s.sol \
  --rpc-url $POLYGON_RPC_URL --broadcast

# Withdraw (unified — picks withdrawal() or withdrawProRata() based on swapsPaused)
forge script script/integration_tests/Withdraw.s.sol \
  --rpc-url $POLYGON_RPC_URL --broadcast
```

---

## Security

- `ReentrancyGuard` on all state-mutating pool functions with CEI ordering (LP burn before ERC-1155 transfers).
- Internal value accounting (`aSideValue` / `bSideValue`) — not `balanceOf` — as the source of truth (donation-immune). Value invariant `aSideValue + bSideValue == physicalBalanceNorm(A) + physicalBalanceNorm(B)` is maintained after every operation and covered by dedicated tests.
- Factory hard-bound to one market-contract pair at deploy (both `immutable`) — no runtime whitelist to poison, no operator choice of counterparty.
- Market tokenIds strictly non-reusable across pools on either side within a factory, enforced by `usedMarketATokenId` / `usedMarketBTokenId`. Guarantees the LP tokenId = market tokenId mirroring is collision-free.
- `swapsPaused` determines withdrawal topology: active pool uses `withdrawal()` (fees per state); paused pool uses `withdrawProRata()` (always free, proportional-share safety).
- `resolved` waives cross-side fees for frictionless unwind after the underlying event settles. Doesn't touch the pause flags; operator chooses to pause separately via `setPoolSwapsPaused` / `setPoolDepositsPaused`, or atomically via `resolvePoolAndPause`.
- 24-hour two-bucket JIT lock on LP positions — JIT fee scales only with the actually-fresh portion of a burn (not all-or-nothing). Transfers-in are always fresh at the recipient — maturity doesn't launder across wallets.
- Fees are per-pool and adjustable only by factory owner (multisig). Operator cannot change fees or rescue funds.
- Decimal normalization prevents value distortion when pairing tokens with different decimal precision.
- Single ceiling-rounded fee prevents fee evasion via transaction splitting while avoiding double-rounding overcharge.
- Physical-liquidity checks on withdrawal use the full outflow (`payout + protocolFee`) against `physicalBalanceNorm(receiveSide)`.
- Last-LP residual flush (`_flushResidualIfEmpty`) sweeps orphaned dust to `FeeCollector` when both LP supplies hit zero — prevents first-depositor capture in the next epoch.
- Bridge escrow contracts are pausable by owner.
- Wrapped token bridge address is set once and immutable thereafter.
- Rescue functions for stuck tokens/ETH, owner-only, with guards preventing rescue of tracked pool balances (`rescueTokens` only succeeds when `physical > aSideValue + bSideValue`).

---

## License

BUSL-1.1 — core protocol contracts (`SwapPool`, `PoolFactory`, `LPToken`)

Scripts and tests are MIT.
