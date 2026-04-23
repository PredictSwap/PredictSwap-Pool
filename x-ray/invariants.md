# Invariants & Guards -- PredictSwap v3

---

## Guards (G-N)

Guards are explicit revert conditions in the source code.

#### G-1 SwapPool: DepositsPaused

`depositsPaused == true` reverts `DepositsPaused()` -- SwapPool.sol L258 -- prevents deposits when operator has paused.

#### G-2 SwapPool: MarketResolved (deposit)

`resolved == true` reverts `MarketResolved()` -- SwapPool.sol L259 -- prevents deposits after market resolution.

#### G-3 SwapPool: SwapsPaused

`swapsPaused == true` reverts `SwapsPaused()` -- SwapPool.sol L290 (swap), L343 (withdrawal) -- blocks swaps and active-mode withdrawals when paused.

#### G-4 SwapPool: MarketResolved (swap)

`resolved == true` reverts `MarketResolved()` -- SwapPool.sol L291 -- prevents swaps after resolution.

#### G-5 SwapPool: ZeroAmount

`amount == 0` reverts `ZeroAmount()` -- SwapPool.sol L260 (deposit), L292 (swap), L344 (withdrawal), L429 (withdrawProRata) -- rejects zero-value operations.

#### G-6 SwapPool: DepositTooSmall

`lpMinted == 0` reverts `DepositTooSmall()` -- SwapPool.sol L271 -- prevents rounding-to-zero deposits that would grant no LP tokens.

#### G-7 SwapPool: SwapTooSmall

`rawOut == 0` reverts `SwapTooSmall()` -- SwapPool.sol L316 -- prevents swaps where output rounds to zero after fees.

#### G-8 SwapPool: InsufficientLiquidity (swap)

`normOut > availableOut` reverts `InsufficientLiquidity(available, required)` -- SwapPool.sol L302 -- prevents swaps exceeding physical output-side balance.

#### G-9 SwapPool: InsufficientLiquidity (withdrawal)

`totalOutflow > available` reverts `InsufficientLiquidity(available, totalOutflow)` -- SwapPool.sol L371 -- prevents withdrawals exceeding physical receive-side balance (payout + protocolFee).

#### G-10 SwapPool: InsufficientLiquidity (withdrawProRata cross)

`crossShare > availableCross` reverts `InsufficientLiquidity(availableCross, crossShare)` -- SwapPool.sol L448 -- prevents pro-rata cross portion exceeding physical balance.

#### G-11 SwapPool: rawPayout == 0 (withdrawal)

`rawPayout == 0` reverts `ZeroAmount()` -- SwapPool.sol L396 -- prevents withdrawal where payout rounds to zero after fees and normalization.

#### G-12 SwapPool: FeeTooHigh (constructor)

`lpFeeBps_ > MAX_LP_FEE` or `protocolFeeBps_ > MAX_PROTOCOL_FEE` reverts `FeeTooHigh()` -- SwapPool.sol L176-177 -- enforces hard caps at construction.

#### G-13 SwapPool: FeeTooHigh (setFees)

`lpFeeBps_ > MAX_LP_FEE` or `protocolFeeBps_ > MAX_PROTOCOL_FEE` reverts `FeeTooHigh()` -- SwapPool.sol L531-532 -- enforces hard caps on fee updates.

#### G-14 SwapPool: Unauthorized

`msg.sender != address(factory)` reverts `Unauthorized()` -- SwapPool.sol L195, L502, L508, L514, L519, L530, L542, L561, L571, L578 -- all admin functions gated to factory only.

#### G-15 SwapPool: AlreadyInitialized

`_initialized == true` reverts `AlreadyInitialized()` -- SwapPool.sol L196 -- one-shot initialization.

#### G-16 SwapPool: NotInitialized

`_initialized == false` reverts `NotInitialized()` -- SwapPool.sol L205 -- blocks user operations before initialization.

#### G-17 SwapPool: SwapsNotPaused

`swapsPaused == false` reverts `SwapsNotPaused()` -- SwapPool.sol L428 -- withdrawProRata only available when swaps are paused.

#### G-18 LPToken: OnlyPool

`msg.sender != pool[tokenId]` reverts `OnlyPool()` -- LPToken.sol L84 -- restricts mint/burn to registered pool for that tokenId.

#### G-19 LPToken: OnlyFactory

`msg.sender != factory` reverts `OnlyFactory()` -- LPToken.sol L98 -- restricts registerPool to factory.

#### G-20 LPToken: TokenIdAlreadyRegistered

`pool[tokenId] != address(0)` reverts `TokenIdAlreadyRegistered()` -- LPToken.sol L101 -- one-shot registration per tokenId.

#### G-21 PoolFactory: NotOperator

`msg.sender != operator && msg.sender != owner()` reverts `NotOperator()` -- PoolFactory.sol L139 -- gates operator-level functions.

#### G-22 PoolFactory: PoolAlreadyExists

`poolIndex[key] != 0` reverts `PoolAlreadyExists(key)` -- PoolFactory.sol L203 -- prevents duplicate tokenId-pair pools.

#### G-23 PoolFactory: MarketATokenIdAlreadyUsed

`usedMarketATokenId[tokenId] == true` reverts `MarketATokenIdAlreadyUsed(tokenId)` -- PoolFactory.sol L204 -- enforces non-reuse of market A tokenIds across all pools.

#### G-24 PoolFactory: MarketBTokenIdAlreadyUsed

`usedMarketBTokenId[tokenId] == true` reverts `MarketBTokenIdAlreadyUsed(tokenId)` -- PoolFactory.sol L205 -- enforces non-reuse of market B tokenIds across all pools.

#### G-25 FeeCollector: ZeroAmount

`amount == 0` reverts `ZeroAmount()` -- FeeCollector.sol L34 (recordFee), L42 (withdraw), L55 (withdrawBatch), L65 (withdrawAll), L80 (withdrawAllBatch) -- rejects zero-value operations.

#### G-26 FeeCollector: ZeroAddress

`to == address(0)` reverts `ZeroAddress()` -- FeeCollector.sol L41 (withdraw), L53 (withdrawBatch), L63 (withdrawAll), L73 (withdrawAllBatch) -- prevents transfers to zero address.

---

## Intra-Contract Invariants (I-N)

#### I-1 Conservation: aSideValue + bSideValue approximates physicalBalanceNorm(A) + physicalBalanceNorm(B)

`aSideValue + bSideValue <= physicalBalanceNorm(MARKET_A) + physicalBalanceNorm(MARKET_B)` -- SwapPool.sol L81-86 (value tracking), L230-233 (physical balance) -- ensures total tracked obligations never exceed total physical tokens held. The inequality allows for rounding dust and surplus from external sends. **Derivation:** deposit adds normAmount to sideValue and pulls normAmount physical; swap redistributes value without changing total; withdrawal subtracts from sideValue and pushes physical; protocolFee push reduces physical without reducing sideValue (only lpFee stays). Strict equality breaks due to _fromNorm truncation and external token sends.

#### I-2 Bound: lpFeeBps in [0, MAX_LP_FEE]

`0 <= lpFeeBps <= 100` -- SwapPool.sol L176 (constructor), L531 (setFees) -- hard cap at 1.00%. **Derivation:** constructor reverts on lpFeeBps_ > 100; setFees (only callable by factory, which is only callable by owner) also reverts on > 100. No other write path to lpFeeBps.

#### I-3 Bound: protocolFeeBps in [0, MAX_PROTOCOL_FEE]

`0 <= protocolFeeBps <= 50` -- SwapPool.sol L177 (constructor), L532 (setFees) -- hard cap at 0.50%. **Derivation:** same enforcement as I-2 for protocolFeeBps.

#### I-4 Ratio: LP minting proportional to sideValue

`lpMinted = normAmount * supply / sideValue` (subsequent deposits) or `lpMinted = normAmount` (first deposit) -- SwapPool.sol L268-270. **Derivation:** maintains pro-rata LP share. First deposit sets 1:1 baseline. Subsequent deposits scale by current rate. Reverts if lpMinted == 0 (G-6).

#### I-5 Ratio: shares = lpAmount * rate / 1e18

`shares = (lpAmount * rate) / RATE_PRECISION` where `rate = sideValue * 1e18 / supply` -- SwapPool.sol L591-594. **Derivation:** _lpToShares converts LP tokens to normalized share value using current rate. Rate starts at 1e18 (1:1) and increases as fees accrue.

#### I-6 StateMachine: _initialized transitions false -> true (one-shot)

`_initialized: false -> true`, never back -- SwapPool.sol L198 (set), L196 (guard). **Derivation:** initialize() checks _initialized is false before setting true; no function sets it back to false.

#### I-7 StateMachine: pool[tokenId] transitions address(0) -> pool (one-shot)

`pool[tokenId]: address(0) -> nonzero`, never changed after -- LPToken.sol L101-102. **Derivation:** registerPool checks pool[tokenId] == address(0) before assignment; no function can overwrite a non-zero mapping entry.

#### I-8 Bound: marketARate >= 1e18 and marketBRate >= 1e18

`rate >= RATE_PRECISION` under normal operation -- SwapPool.sol L212-216, L219-222. **Derivation:** initial deposit sets sideValue = normAmount and supply = normAmount, so rate = 1e18. Swap fees only add to sideValue (never subtract). Withdrawal with fee: fee stays in sideValue, net subtraction < shares. Rate can only increase. **Caveat:** violated if value accounting bug in withdrawal creates sideValue < supply.

#### I-9 Temporal: lockedAmount = 0 when block.timestamp >= freshDeposit.timestamp + LOCK_PERIOD

`lockedAmount(user, tokenId) == 0` when `block.timestamp >= fd.timestamp + LOCK_PERIOD` -- LPToken.sol L121-122. **Derivation:** lockedAmount() is a pure view that checks the time condition. The FreshDeposit struct is the source of truth; graduation is lazy (happens on next inflow/outflow touch). The view correctly returns 0 even before graduation.

---

## Cross-Contract Invariants (X-N)

#### X-1 SwapPool <-> LPToken mint/burn totalSupply consistency

`LPToken.totalSupply(lpTokenId)` always equals the cumulative minted minus burned for that tokenId by SwapPool -- SwapPool.sol L616-621 (mint), L608-613 (burn); LPToken.sol L106-109 (mint), L111-114 (burn). **Derivation:** SwapPool is the only address authorized to mint/burn (G-18 enforces pool[tokenId] == SwapPool address). LPToken.mint increments totalSupply, burn decrements. No other write path to totalSupply for a given tokenId.

#### X-2 SwapPool -> FeeCollector push-before-recordFee ordering

Physical token transfer to FeeCollector always precedes the recordFee call -- SwapPool.sol L310-311 (swap), L402-403 (withdrawal). **Derivation:** _pushTokens (safeTransferFrom) is called before feeCollector.recordFee in both swap and withdrawal. If the push reverts, recordFee is never reached. This prevents recording fees that were not actually transferred.

#### X-3 SwapPool reads LPToken.lockedAmount/balanceOf for JIT fee

SwapPool._freshConsumedForBurn reads LPToken state to determine JIT fee base -- SwapPool.sol L599-606; LPToken.sol L119-125. **Derivation:** _freshConsumedForBurn calls lp.balanceOf and lp.lockedAmount for the caller. These are view calls that read current state BEFORE the burn. The burn (which updates the fresh bucket) happens after the fee calculation at L392. This ordering is correct: fee is computed on pre-burn state.

#### X-4 PoolFactory.setFeeCollector does NOT update existing pools' immutable feeCollector

SwapPool.feeCollector is immutable (set at construction from factory.feeCollector at that time) -- SwapPool.sol L63; PoolFactory.sol L213 (passes address(feeCollector) to constructor), L283-287 (updates factory.feeCollector). **Derivation:** immutable variables are set once in the constructor and stored in contract bytecode. PoolFactory.setFeeCollector only changes the factory's state variable; existing SwapPool instances retain their original feeCollector address forever. Only pools created after the change use the new address.

---

## Economic Invariants (E-N)

#### E-1 LP share value monotonically non-decreasing from fees

For each side, `sideValue / totalSupply >= previous(sideValue / totalSupply)` under normal operation -- SwapPool.sol L268-270 (deposit preserves rate), L297-320 (swap adds lpFee to drained side). **Derivation:** deposit mints LP proportional to current rate, preserving rate. Swap adds lpFee to toSide sideValue without minting LP, increasing rate. Same-side withdrawal with JIT fee: fee stays in sideValue (unless last-LP), net rate preserved. Cross-side withdrawal: lpFee added to receiveSide sideValue. **Caveat:** last-LP same-side JIT path (L378-382) subtracts full shares from lpSide and adds lpFee to opposite side; this can decrease the opposite side's effective rate if the opposite supply is large relative to lpFee.

#### E-2 No tokens extractable without LP burn or valid swap math

Every outflow from SwapPool (except rescue and flush) requires either LP burn or swap fee deduction -- SwapPool.sol L252 (deposit: inflow only), L284 (swap: normOut < normIn), L337 (withdrawal: burns LP), L422 (withdrawProRata: burns LP), L541 (rescue: owner-gated, surplus-checked), L476 (_flushResidualIfEmpty: only when all LP burned). **Derivation:** deposit is inflow-only. swap output is strictly less than input (by fees). withdrawal and withdrawProRata both burn LP before pushing tokens. rescue requires owner privilege and global surplus. flush only triggers when totalSupply == 0 across both sides.
