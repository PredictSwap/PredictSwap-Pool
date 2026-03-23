# PredictSwap

**Cross-chain prediction market arbitrage and liquidity protocol.**

Identical real-world events trade at different prices across fragmented prediction market platforms. PredictSwap is the first permissionless venue for 1:1 swaps between [Polymarket](https://polymarket.com) (Polygon) and [Opinion](https://opinion.markets) (BSC) shares — the same outcome, two chains, one pool.

---

## How It Works

YES shares for the same event on Polymarket and Opinion should cost exactly the same. In practice they don't, due to low liquidity and no cross-platform arbitrage infrastructure. PredictSwap fixes this:

1. **Bridge** — Users lock Opinion ERC-1155 shares on BSC via `OpinionEscrow`. LayerZero V2 relays the message to Polygon, where `BridgeReceiver` mints 1:1 `WrappedOpinionToken` (ERC-1155).
2. **Pool** — Each `SwapPool` holds one matched pair (Polymarket tokenId ↔ Opinion tokenId). Both sides are treated as economically equivalent.
3. **Swap** — Users deposit one side and receive the other, minus a 0.40% fee (0.30% to LPs, 0.10% protocol).
4. **Liquidity** — LPs deposit single-sided. LP tokens accrue fees automatically — no claiming needed.

```
BSC                                    Polygon
───────────────────────────────────────────────────────
Opinion ERC-1155                       Polymarket ERC-1155
     │                                        │
OpinionEscrow ──── LayerZero V2 ───► BridgeReceiver
     │                                        │
     └──────────── WrappedOpinionToken ───────┘
                            │
                        SwapPool
                      (1:1 AMM)
```

---

## Pool Mechanics

```
exchangeRate  = totalShares / lpSupply          (1e18 scaled)
lpToMint      = depositAmount * lpSupply / totalShares   (1:1 on first deposit)
sharesOut     = lpBurned * totalShares / lpSupply

Swap fee:     0.40% total
  0.30% LP fee      → stays in pool (auto-compounds, no new LP minted)
  0.10% protocol    → transferred to FeeCollector
```

LP fees compound silently into `totalShares` without minting new LP tokens — existing LP positions appreciate automatically.

### Fee Calculation

Fees are computed as a single ceiling-rounded total, then split between LP and protocol:

```
totalFee    = ceil(amount * (lpFeeBps + protocolFeeBps) / FEE_DENOMINATOR)
protocolFee = (totalFee * protocolFeeBps) / (lpFeeBps + protocolFeeBps)
lpFee       = totalFee - protocolFee
```

A single ceiling rounding (not one per component) ensures the aggregate fee never exceeds one rounding unit above the configured rate, while still guaranteeing at least 1 unit of fee on any non-zero amount with non-zero bps.

### Withdrawal Rules

| Operation | Fee | Blocked by `swapsPaused`? |
|---|---|---|
| `deposit()` | None | No |
| `withdrawSingleSide()` — same side | None | No |
| `withdrawSingleSide()` — cross side | Yes (unless resolved) | Yes |
| `withdrawBothSides()` — same-side portion | None | No |
| `withdrawBothSides()` — cross-side portion | Yes (unless resolved) | Yes |
| `swap()` | Yes | Yes |

Same-side withdrawals are never blocked. LPs can always exit on their original side regardless of pool state.

`withdrawBothSides()` accepts a `samesideBps` parameter (0–10000) instead of absolute amounts — the split is computed on-chain at execution time, preventing DoS from stale off-chain values:

```
samesideAmount  = grossOut * samesideBps / FEE_DENOMINATOR
crosssideAmount = grossOut - samesideAmount
```

---

## Architecture

| Contract | Chain | Role |
|---|---|---|
| `OpinionEscrow` | BSC | Locks Opinion ERC-1155 shares, sends LZ message |
| `BridgeReceiver` | Polygon | Receives LZ message, mints/burns `WrappedOpinionToken` |
| `WrappedOpinionToken` | Polygon | ERC-1155 wrapper, 1:1 backed by locked shares |
| `PoolFactory` | Polygon | Deploys pools, owns fee config |
| `SwapPool` | Polygon | 1:1 AMM per matched market pair |
| `LPToken` | Polygon | ERC-20 LP token per pool |
| `FeeCollector` | Polygon | Accumulates protocol fees |

Cross-chain messaging uses **LayerZero V2 OApp**. Native tokens stay on their home chains — no token bridging, only message passing.

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
forge test
forge fmt
forge snapshot   # gas snapshots
```

## Deployment

All deploy scripts require environment variables to be loaded first:

```bash
source .env
```

### 1. Deploy and mint Dummy Mock Polymarket Token (testnet only)

```bash
forge script script/integration_tests/DeployMockPoly.s.sol:DeployMockPolymarket \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$POLYGON_CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

```bash
forge script script/integration_tests/MintMock.s.sol \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast
```

add POLY_TOKEN_ID and OPINION_TOKEN_ID into .env

### 2. Deploy FeeCollector + PoolFactory

```bash
forge script script/Deploy.s.sol \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$POLYGON_CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

add FEE_COLLECTOR_ADDRESS and POOL_FACTORY_ADDRESS into .env

### 3. Create a Pool

```bash
forge script script/CreatePool.s.sol \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$POLYGON_CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

---

## Integration Testing

```bash
# Deposit into pool
forge script script/integration_tests/Deposit.s.sol \
  --rpc-url $POLYGON_RPC_URL --broadcast

# Swap between sides
forge script script/integration_tests/Swap.s.sol \
  --rpc-url $POLYGON_RPC_URL --broadcast

# Withdraw from pool
forge script script/integration_tests/Withdraw.s.sol \
  --rpc-url $POLYGON_RPC_URL --broadcast
```

---

## Security

- `ReentrancyGuard` on all state-mutating pool functions with CEI ordering (LP burn before ERC-1155 transfers)
- Internal balance accounting — not `balanceOf` — as the source of truth (donation-immune)
- `swapsPaused` blocks all cross-side value transfers: `swap()`, cross-side `withdrawSingleSide()`, and the cross-side portion of `withdrawBothSides()`
- `depositsPaused` and `swapsPaused` are independent flags — pausing one does not affect the other
- `resolved` and `depositsPaused` are independent — `unsetResolved()` does not re-enable deposits
- Single ceiling-rounded fee prevents fee evasion via transaction splitting while avoiding double-rounding overcharge
- Cross-side liquidity checks use net debit (`actualOut + protocolFee`) not gross amount — prevents false reverts near side depletion
- Last-LP residual flush (`_flushResidualIfEmpty`) sends orphaned LP fees to `FeeCollector` on full exit, preventing first-depositor capture
- `WrappedOpinionToken.setBridge()` callable only once (`BridgeAlreadySet` guard)
- `OpinionEscrow` and `BridgeReceiver` are pausable by owner
- Rescue functions for stuck tokens/ETH, with guards preventing rescue of actively locked funds

---

## License

MIT