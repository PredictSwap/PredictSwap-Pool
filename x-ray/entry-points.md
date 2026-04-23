# Entry Points -- PredictSwap v3

---

## Protocol Flow Paths

### Path 1: Deposit -> Earn Fees -> Withdraw (Happy Path)

1. User approves SwapPool on the ERC-1155 market contract
2. User calls `SwapPool.deposit(side, amount)` -- pool pulls ERC-1155 shares, mints LP tokens via LPToken, updates sideValue
3. Other users swap via `SwapPool.swap()` -- LP fees accrue to the drained side's sideValue, increasing LP rate
4. After 24h (JIT lock matures), user calls `SwapPool.withdrawal(sameSide, lpAmount, lpSide)` -- no JIT fee, burns LP, pushes shares

### Path 2: Deposit -> Market Resolution -> WithdrawProRata

1. User deposits as above
2. Operator calls `PoolFactory.resolvePoolAndPause(poolId)` -- atomically sets resolved=true, depositsPaused=true, swapsPaused=true
3. User calls `SwapPool.withdrawProRata(lpAmount, lpSide)` -- proportional split of native + cross tokens, no fees

### Path 3: Swap

1. User approves SwapPool on fromSide ERC-1155 contract
2. User calls `SwapPool.swap(fromSide, sharesIn)` -- pool pulls fromSide shares, computes fees, checks output liquidity, pushes toSide shares
3. LP fee accrues to drained (toSide) sideValue; protocol fee pushed to FeeCollector

### Path 4: Pool Lifecycle (Admin)

1. Owner deploys PoolFactory with market contracts, fee collector, operator, names
2. Operator calls `PoolFactory.createPool(marketA, marketB, lpFee, protocolFee, desc)` -- deploys SwapPool, registers LP tokenIds, calls initialize
3. During operation: operator pauses/unpauses/resolves as needed
4. Owner adjusts fees via `setPoolFees`, rescues stuck tokens via rescue functions
5. Owner withdraws accumulated fees from FeeCollector

---

## Permissionless Entry Points

### SwapPool.deposit

```
function deposit(Side side, uint256 amount) external nonReentrant whenInitialized returns (uint256 lpMinted)
```

**File:** SwapPool.sol L252-277

**Guards:**
- `nonReentrant` -- reentrancy lock
- `whenInitialized` -- reverts NotInitialized if pool not yet wired
- `depositsPaused` -- reverts DepositsPaused
- `resolved` -- reverts MarketResolved
- `amount == 0` -- reverts ZeroAmount
- `lpMinted == 0` -- reverts DepositTooSmall (rounding to zero)

**Value flow:** IN. User sends ERC-1155 shares to pool; pool mints LP tokens to user.

**State changes:**
- aSideValue or bSideValue += normAmount
- LPToken.totalSupply[tokenId] += lpMinted
- LPToken.freshDeposit[user][tokenId] updated (JIT lock starts)
- ERC-1155 balance: user -= amount, pool += amount

**Preconditions:**
- User must have approved SwapPool on the relevant ERC-1155 market contract
- Pool must be initialized, deposits not paused, not resolved

**Downstream calls:**
- `IERC1155.safeTransferFrom` (pull shares from user)
- `LPToken.mint` (mint LP to user, triggers _update with JIT bucket logic)

**Key math:**
- First deposit: `lpMinted = normAmount`
- Subsequent: `lpMinted = (normAmount * supply) / sideValue`

---

### SwapPool.swap

```
function swap(Side fromSide, uint256 sharesIn) external nonReentrant whenInitialized returns (uint256 sharesOut)
```

**File:** SwapPool.sol L284-324

**Guards:**
- `nonReentrant`
- `whenInitialized`
- `swapsPaused` -- reverts SwapsPaused
- `resolved` -- reverts MarketResolved
- `sharesIn == 0` -- reverts ZeroAmount
- `normOut > availableOut` -- reverts InsufficientLiquidity
- `rawOut == 0` -- reverts SwapTooSmall

**Value flow:** IN + OUT. User sends fromSide shares, receives toSide shares minus fees.

**State changes:**
- toSide sideValue += lpFee (LP fee accrues to drained side)
- ERC-1155: user sends fromSide, receives toSide
- FeeCollector receives protocolFee in fromSide tokens (if rawProtocol > 0)

**Preconditions:**
- User must have approved SwapPool on fromSide ERC-1155 contract
- Pool must have sufficient toSide physical liquidity
- Pool not paused, not resolved

**Downstream calls:**
- `IERC1155.safeTransferFrom` (pull fromSide, push toSide, push protocol fee)
- `FeeCollector.recordFee` (if rawProtocol > 0)

**Key math:**
- `normOut = normIn - lpFee - protocolFee`
- Fees: `totalFee = (normIn * totalBps + FEE_DENOMINATOR - 1) / FEE_DENOMINATOR` (rounds up)
- `protocolFee = (totalFee * protocolFeeBps) / totalBps`
- `lpFee = totalFee - protocolFee`

---

### SwapPool.withdrawal

```
function withdrawal(Side receiveSide, uint256 lpAmount, Side lpSide) external nonReentrant whenInitialized returns (uint256 received)
```

**File:** SwapPool.sol L337-409

**Guards:**
- `nonReentrant`
- `whenInitialized`
- `swapsPaused` -- reverts SwapsPaused (must use withdrawProRata when paused)
- `lpAmount == 0` -- reverts ZeroAmount
- `totalOutflow > available` -- reverts InsufficientLiquidity
- `rawPayout == 0` -- reverts ZeroAmount (line 396)

**Value flow:** OUT. User burns LP tokens, receives ERC-1155 shares.

**State changes:**
- sideValue updated (complex: depends on same-side/cross-side, last-LP, JIT fee)
- LPToken.totalSupply[tokenId] -= lpAmount
- LPToken.freshDeposit[user][tokenId] updated (outflow consumes matured first)
- ERC-1155: pool sends payout + protocol fee out
- If all LP burned: _flushResidualIfEmpty sends dust to FeeCollector

**Fee logic:**
- **Same-side, not resolved:** JIT fee on fresh portion only. `feeBase = (shares * freshBurned) / lpAmount`
- **Cross-side, not resolved:** full fee on entire claim
- **Resolved (either side):** no fee
- **Last-LP same-side with fee:** lpFee credited to opposite side (value accounting issue, see x-ray 4.1)

**Preconditions:**
- User must hold lpAmount of LP tokens for lpSide
- Pool must have sufficient physical tokens on receiveSide
- Swaps must not be paused

**Downstream calls:**
- `LPToken.burn`, `IERC1155.safeTransferFrom`, `FeeCollector.recordFee`

---

### SwapPool.withdrawProRata

```
function withdrawProRata(uint256 lpAmount, Side lpSide) external nonReentrant whenInitialized returns (uint256 nativeOut, uint256 crossOut)
```

**File:** SwapPool.sol L422-471

**Guards:**
- `nonReentrant`
- `whenInitialized`
- `!swapsPaused` -- reverts SwapsNotPaused (only available when paused)
- `lpAmount == 0` -- reverts ZeroAmount
- `crossShare > availableCross` -- reverts InsufficientLiquidity
- `rawNative == 0 && rawCross == 0` -- reverts ZeroAmount

**Value flow:** OUT. User burns LP, receives proportional native + cross tokens. No fees.

**State changes:**
- sideValue -= shares
- LPToken supply decremented
- ERC-1155 tokens transferred to user
- If all LP burned: _flushResidualIfEmpty

**Key math:**
- `nativeShare = (lpAmount * availableNative) / totalSupply`, capped at shares
- `crossShare = shares - nativeShare`

**Preconditions:**
- Swaps must be paused (operator has paused or resolved-and-paused)
- User holds LP tokens

**Downstream calls:**
- `LPToken.burn`, `IERC1155.safeTransferFrom`

---

### FeeCollector.recordFee

```
function recordFee(address token, uint256 tokenId, uint256 amount) external
```

**File:** FeeCollector.sol L33-36

**Guards:**
- `amount == 0` -- reverts ZeroAmount

**Value flow:** None (event-only).

**Note:** Permissionless. Anyone can emit spoofed FeeReceived events. Off-chain indexers must filter by known pool addresses.

---

## Operator-Gated Entry Points (onlyOperator = operator OR owner)

| Function | File | Key Guards | Effect |
|---|---|---|---|
| `createPool(marketA, marketB, lpFee, protocolFee, desc)` | PoolFactory L192-248 | onlyOperator, tokenId!=0, decimals<=18, no duplicate key, no reused tokenId | Deploys SwapPool, registers LP positions, initializes pool |
| `setPoolDepositsPaused(poolId, paused)` | PoolFactory L296-299 | onlyOperator, poolId valid | Sets depositsPaused on target pool |
| `setPoolSwapsPaused(poolId, paused)` | PoolFactory L301-305 | onlyOperator, poolId valid | Sets swapsPaused on target pool |
| `setResolvePool(poolId, resolved)` | PoolFactory L308-312 | onlyOperator, poolId valid | Sets resolved flag (can un-resolve) |
| `resolvePoolAndPause(poolId)` | PoolFactory L316-322 | onlyOperator, poolId valid | Atomic: resolved=true, depositsPaused=true, swapsPaused=true |

---

## Owner-Only Entry Points (onlyOwner)

### PoolFactory Owner Functions

| Function | File | Key Guards | Effect |
|---|---|---|---|
| `setOperator(addr)` | PoolFactory L277-281 | onlyOwner, addr!=0 | Changes operator address |
| `setFeeCollector(addr)` | PoolFactory L283-287 | onlyOwner, addr!=0 | Changes feeCollector for NEW pools only |
| `setPoolFees(poolId, lpFee, protocolFee)` | PoolFactory L289-292 | onlyOwner, poolId valid | Relays setFees to pool (hard caps: lp<=100bps, proto<=50bps) |
| `rescuePoolTokens(poolId, side, amount, to)` | PoolFactory L326-331 | onlyOwner, poolId valid | Rescues surplus pool tokens (global surplus check) |
| `rescuePoolERC1155(poolId, contract, tokenId, amount, to)` | PoolFactory L333-338 | onlyOwner, rejects pool market contracts | Rescues non-pool ERC-1155 tokens |
| `rescuePoolERC20(poolId, token, amount, to)` | PoolFactory L340-344 | onlyOwner | Rescues ERC-20 tokens from pool |
| `rescuePoolETH(poolId, to)` | PoolFactory L347-350 | onlyOwner | Rescues ETH from pool |

### FeeCollector Owner Functions

| Function | File | Key Guards | Effect |
|---|---|---|---|
| `withdraw(token, tokenId, amount, to)` | FeeCollector L40-45 | onlyOwner, to!=0, amount!=0 | Withdraws specific amount of specific tokenId |
| `withdrawBatch(token, tokenIds, amounts, to)` | FeeCollector L47-59 | onlyOwner, to!=0, all amounts!=0 | Batch withdraw multiple tokenIds |
| `withdrawAll(token, tokenId, to)` | FeeCollector L62-68 | onlyOwner, to!=0, balance!=0 | Withdraws entire balance of a tokenId |
| `withdrawAllBatch(token, tokenIds, to)` | FeeCollector L72-96 | onlyOwner, to!=0, at least one balance>0 | Batch withdraw entire balances, skips zeros |
