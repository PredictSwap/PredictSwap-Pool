# Entry Point Map

> PredictSwap | 28 entry points | 5 permissionless | 6 role-gated | 17 admin-only

---

## Protocol Flow Paths

### Setup (Owner → Operator)

`PoolFactory.constructor(owner_)` → `PoolFactory.setOperator(operator_)` ◄── optional, set in constructor
→ `PoolFactory.createPool(marketA, marketB, fees)` → `SwapPool.initialize(lpIdA, lpIdB)` ◄── atomic in createPool

### User Flow

`[pool created above]` → `SwapPool.deposit(side, amount)` ◄── deposits not paused, not resolved
                              ├─→ `SwapPool.swap(fromSide, sharesIn)` ◄── swaps not paused, output-side liquidity exists
                              ├─→ `SwapPool.withdrawal(receiveSide, lpAmount, lpSide)` ◄── swaps not paused
                              └─→ `SwapPool.withdrawProRata(lpAmount, lpSide)` ◄── swaps ARE paused

### Resolution (Operator)

`[pool active]` → [event resolves off-chain] → `PoolFactory.resolvePoolAndPause(poolId)`
→ `SwapPool.withdrawProRata(...)` ◄── fee-free proportional exit

### Fee Withdrawal (Owner)

`[swaps/withdrawals generate fees]` → `FeeCollector.withdraw(token, tokenId, amount, to)`

---

## Permissionless

### `SwapPool.deposit()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenInitialized |
| Caller | User / LP |
| Parameters | side (user-controlled), amount (user-controlled) |
| Call chain | `→ SwapPool._pullTokens() → IERC1155.safeTransferFrom()` → `SwapPool._addSideValue()` → `SwapPool._mintLp() → LPToken.mint() → ERC1155._mint()` |
| State modified | `aSideValue` or `bSideValue` += normAmount; `LPToken.totalSupply[tokenId]` += lpMinted; `LPToken.freshDeposit[user][tokenId]` updated |
| Value flow | Tokens: user → SwapPool |
| Reentrancy guard | yes |

### `SwapPool.swap()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenInitialized |
| Caller | User / Swapper |
| Parameters | fromSide (user-controlled), sharesIn (user-controlled) |
| Call chain | `→ SwapPool._pullTokens(fromSide)` → `SwapPool._pushTokens(fromSide → FeeCollector)` → `FeeCollector.recordFee()` → `SwapPool._pushTokens(toSide → user)` → `SwapPool._addSideValue(toSide, lpFee)` |
| State modified | `aSideValue` or `bSideValue` += lpFee (drained side) |
| Value flow | Tokens: user → SwapPool (input) + SwapPool → user (output) + SwapPool → FeeCollector (protocol fee) |
| Reentrancy guard | yes |

### `SwapPool.withdrawal()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenInitialized |
| Caller | User / LP |
| Parameters | receiveSide (user-controlled), lpAmount (user-controlled), lpSide (user-controlled) |
| Call chain | `→ SwapPool._lpToShares()` → `SwapPool._freshConsumedForBurn() → LPToken.lockedAmount()` → `SwapPool._subSideValue()` → `SwapPool._burnLp() → LPToken.burn()` → `SwapPool._pushTokens(→ user)` → `SwapPool._pushTokens(→ FeeCollector)` → `SwapPool._flushResidualIfEmpty()` |
| State modified | `aSideValue`/`bSideValue` debited; `LPToken.totalSupply` -= lpAmount; `LPToken.freshDeposit` updated |
| Value flow | Tokens: SwapPool → user (payout) + SwapPool → FeeCollector (protocol fee) |
| Reentrancy guard | yes |

### `SwapPool.withdrawProRata()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenInitialized |
| Caller | User / LP |
| Parameters | lpAmount (user-controlled), lpSide (user-controlled) |
| Call chain | `→ SwapPool._lpToShares()` → `SwapPool._subSideValue()` → `SwapPool._burnLp() → LPToken.burn()` → `SwapPool._pushTokens(nativeSide → user)` → `SwapPool._pushTokens(crossSide → user)` → `SwapPool._flushResidualIfEmpty()` |
| State modified | `aSideValue`/`bSideValue` debited; `LPToken.totalSupply` -= lpAmount |
| Value flow | Tokens: SwapPool → user (native + cross portions) |
| Reentrancy guard | yes |

### `FeeCollector.recordFee()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, NONE — permissionless |
| Caller | Anyone (intended: SwapPool after fee transfer) |
| Parameters | token (user-controlled), tokenId (user-controlled), amount (user-controlled) |
| Call chain | emits `FeeReceived` event only |
| State modified | none (event-only accounting) |
| Value flow | none |
| Reentrancy guard | no |

---

## Role-Gated

### `onlyOperator` (Operator or Owner via PoolFactory)

#### `PoolFactory.createPool()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyOperator |
| Caller | Operator / Owner |
| Parameters | marketA_ (operator-provided), marketB_ (operator-provided), lpFeeBps_ (operator-provided), protocolFeeBps_ (operator-provided), eventDescription_ (operator-provided) |
| Call chain | `→ new SwapPool(...)` → `LPToken.registerPool() ×2` → `SwapPool.initialize()` |
| State modified | `pools[]` appended, `poolIndex[key]` set, `usedMarketATokenId`/`usedMarketBTokenId` set to true, `LPToken.pool[tokenId]` set |
| Value flow | none |
| Reentrancy guard | no |

#### `PoolFactory.setPoolDepositsPaused()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyOperator |
| Caller | Operator / Owner |
| Parameters | poolId (operator-provided), paused_ (operator-provided) |
| Call chain | `→ SwapPool.setDepositsPaused()` |
| State modified | `SwapPool.depositsPaused` |
| Value flow | none |
| Reentrancy guard | no |

#### `PoolFactory.setPoolSwapsPaused()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyOperator |
| Caller | Operator / Owner |
| Parameters | poolId (operator-provided), paused_ (operator-provided) |
| Call chain | `→ SwapPool.setSwapsPaused()` |
| State modified | `SwapPool.swapsPaused` |
| Value flow | none |
| Reentrancy guard | no |

#### `PoolFactory.setResolvePool()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyOperator |
| Caller | Operator / Owner |
| Parameters | poolId (operator-provided), resolved_ (operator-provided) |
| Call chain | `→ SwapPool.setResolved()` |
| State modified | `SwapPool.resolved` |
| Value flow | none |
| Reentrancy guard | no |

#### `PoolFactory.resolvePoolAndPause()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyOperator |
| Caller | Operator / Owner |
| Parameters | poolId (operator-provided) |
| Call chain | `→ SwapPool.setResolvedAndPaused()` |
| State modified | `SwapPool.resolved`, `SwapPool.depositsPaused`, `SwapPool.swapsPaused` — all set to true |
| Value flow | none |
| Reentrancy guard | no |

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| PoolFactory | `setOperator(operator_)` | operator_ (owner-provided) | `operator` |
| PoolFactory | `setFeeCollector(feeCollector_)` | feeCollector_ (owner-provided) | `feeCollector` |
| PoolFactory | `setPoolFees(poolId, lpFeeBps_, protocolFeeBps_)` | poolId, lpFeeBps_, protocolFeeBps_ (owner-provided) | `SwapPool.lpFeeBps`, `SwapPool.protocolFeeBps` |
| PoolFactory | `rescuePoolTokens(poolId, side, amount, to)` | poolId, side, amount, to (owner-provided) | physical balance only (surplus above tracked) |
| PoolFactory | `rescuePoolERC1155(poolId, contractAddr, tokenId, amount, to)` | all owner-provided | sends non-pool ERC-1155 tokens |
| PoolFactory | `rescuePoolERC20(poolId, token, amount, to)` | all owner-provided | sends stuck ERC-20 tokens |
| PoolFactory | `rescuePoolETH(poolId, to)` | poolId, to (owner-provided) | sends stuck ETH |
| FeeCollector | `withdraw(token, tokenId, amount, to)` | all owner-provided | ERC-1155 balance of FeeCollector |
| FeeCollector | `withdrawBatch(token, tokenIds[], amounts[], to)` | all owner-provided | ERC-1155 balances of FeeCollector |
| FeeCollector | `withdrawAll(token, tokenId, to)` | all owner-provided | entire balance of one tokenId |
| FeeCollector | `withdrawAllBatch(token, tokenIds[], to)` | all owner-provided | entire balances of multiple tokenIds |
