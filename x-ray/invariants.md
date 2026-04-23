# Invariant Map

> PredictSwap | 27 guards | 11 inferred | 1 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (depositsPaused) revert DepositsPaused()` · `SwapPool.sol:258` · Prevents new liquidity while pool is in maintenance or post-resolution mode

#### G-2
`if (resolved) revert MarketResolved()` · `SwapPool.sol:259` · Blocks deposits after the underlying event settles — prevents LP entry into a resolved pool

#### G-3
`if (amount == 0) revert ZeroAmount()` · `SwapPool.sol:260` · Prevents zero-amount deposits that waste gas without effect

#### G-4
`if (lpMinted == 0) revert DepositTooSmall()` · `SwapPool.sol:271` · Prevents dust deposits that round to 0 LP tokens — protects against share dilution

#### G-5
`if (swapsPaused) revert SwapsPaused()` · `SwapPool.sol:290` · Gates swap availability — paused pools require pro-rata withdrawal instead

#### G-6
`if (sharesIn == 0) revert ZeroAmount()` · `SwapPool.sol:291` · Prevents zero-amount swaps

#### G-7
`if (normOut > availableOut) revert InsufficientLiquidity(availableOut, normOut)` · `SwapPool.sol:301` · Prevents overdrawing output-side physical reserves in swaps

#### G-8
`if (rawOut == 0) revert SwapTooSmall()` · `SwapPool.sol:315` · Prevents zero-output swaps after fee deduction — protects against rounding exploitation

#### G-9
`if (swapsPaused) revert SwapsPaused()` · `SwapPool.sol:342` · Directs users to withdrawProRata when swaps are paused

#### G-10
`if (lpAmount == 0) revert ZeroAmount()` · `SwapPool.sol:343` · Prevents zero-amount withdrawals

#### G-11
`if (totalOutflow > available) revert InsufficientLiquidity(available, totalOutflow)` · `SwapPool.sol:370` · Prevents overdrawing receive-side on withdrawal (includes payout + protocol fee)

#### G-12
`if (!swapsPaused) revert SwapsNotPaused()` · `SwapPool.sol:426` · Pro-rata exit only available when swaps are paused — prevents bypassing swap fees

#### G-13
`if (lpAmount == 0) revert ZeroAmount()` · `SwapPool.sol:427` · Prevents zero-amount pro-rata withdrawals

#### G-14
`if (crossShare > availableCross) revert InsufficientLiquidity(availableCross, crossShare)` · `SwapPool.sol:446` · Prevents overdrawing cross-side reserves in pro-rata exit

#### G-15
`if (msg.sender != address(factory)) revert Unauthorized()` · `SwapPool.sol:195` · Only the factory can initialize a pool — prevents front-running of init

#### G-16
`if (_initialized) revert AlreadyInitialized()` · `SwapPool.sol:196` · One-shot initialization latch — prevents re-initialization attack

#### G-17
`if (!_initialized) revert NotInitialized()` · `SwapPool.sol:205` · All user operations require the pool to be initialized — prevents operating on unconfigured state

#### G-18
`if (lpFeeBps_ > MAX_LP_FEE) revert FeeTooHigh()` · `SwapPool.sol:176,527` · LP fee bounded to 100 bps (1.00%) hard cap at both constructor and setter

#### G-19
`if (protocolFeeBps_ > MAX_PROTOCOL_FEE) revert FeeTooHigh()` · `SwapPool.sol:177,528` · Protocol fee bounded to 50 bps (0.50%) hard cap at both constructor and setter

#### G-20
`if (factory_ == address(0) || feeCollector_ == address(0)) revert ZeroAddress()` · `SwapPool.sol:173` · Prevents deployment with zero-address dependencies

#### G-21
`if (marketA_.tokenId == 0 || marketB_.tokenId == 0) revert InvalidTokenID()` · `SwapPool.sol:174` · Prevents use of reserved tokenId 0

#### G-22
`if (marketA_.decimals > 18 || marketB_.decimals > 18) revert InvalidDecimals()` · `SwapPool.sol:175` · Prevents overflow in normalization math (`10^(18-dec)` requires dec ≤ 18)

#### G-23
`if (msg.sender != factory) revert OnlyFactory()` · `LPToken.sol:98` · Only factory can register new pool-tokenId bindings

#### G-24
`if (pool[tokenId] != address(0)) revert TokenIdAlreadyRegistered()` · `LPToken.sol:101` · One-shot pool-tokenId registration — prevents rebinding to a different pool

#### G-25
`if (msg.sender != pool[tokenId]) revert OnlyPool()` · `LPToken.sol:84` · Only the registered pool can mint/burn for its tokenId — core access control for LP supply

#### G-26
`if (amount == 0) revert ZeroAmount()` · `FeeCollector.sol:34` · Prevents meaningless zero-amount fee records

#### G-27
`if (contractAddress_ == mktA || contractAddress_ == mktB) revert CannotRescuePoolTokens()` · `SwapPool.sol:558` · Prevents rescue of any tokenId from market contract addresses — conservative guard that also traps non-pool tokenIds

---

## 2. Inferred Invariants (Single-Contract)

---

#### I-1

`Conservation` · On-chain: **Yes**

> `aSideValue + bSideValue == physicalBalanceNorm(MARKET_A) + physicalBalanceNorm(MARKET_B)`

**Derivation** — NatSpec: SwapPool.sol:54-56 — *"aSideValue + bSideValue == physicalBalanceNorm(A) + physicalBalanceNorm(B)"*. Confirmed by Δ-pair analysis across all state-changing functions:
- `deposit()`: Δ(sideValue) = +normAmount, Δ(physical) = +normAmount (pulled from user)
- `swap()`: Δ(toSideValue) = +lpFee, Δ(physical) = +normIn − normOut − protocolFee = +lpFee
- `withdrawal()`: Δ(sideValue) = −(shares − lpFee), Δ(physical) = −payout − protocolFee = −(shares − lpFee)
- `withdrawProRata()`: Δ(sideValue) = −shares, Δ(physical) = −nativeShare − crossShare = −shares
- `_flushResidualIfEmpty()`: sets both values to 0, sweeps all physical to FeeCollector

**If violated** — Pool is insolvent (claims exceed physical reserves) or has trapped value (physical exceeds claims).

---

#### I-2

`Bound` · On-chain: **Yes**

> `lpFeeBps ∈ [0, 100]` globally across all write paths

**Derivation** — Guard-lift: `if (lpFeeBps_ > MAX_LP_FEE) revert FeeTooHigh()` enforced at SwapPool.sol:176 (constructor) and SwapPool.sol:527 (setFees). Write sites: constructor:186 and setFees:529. Both guarded by MAX_LP_FEE = 100.

**If violated** — LP fee exceeds 1% hard cap, extracting excessive value from swappers/withdrawers.

---

#### I-3

`Bound` · On-chain: **Yes**

> `protocolFeeBps ∈ [0, 50]` globally across all write paths

**Derivation** — Guard-lift: `if (protocolFeeBps_ > MAX_PROTOCOL_FEE) revert FeeTooHigh()` enforced at SwapPool.sol:177 (constructor) and SwapPool.sol:528 (setFees). Write sites: constructor:187 and setFees:530. Both guarded by MAX_PROTOCOL_FEE = 50.

**If violated** — Protocol fee exceeds 0.5% hard cap.

---

#### I-4

`StateMachine` · On-chain: **Yes**

> `SwapPool._initialized: false → true` — one-shot latch, no reverse path

**Derivation** — Edge: SwapPool.sol:196 `if (_initialized) revert AlreadyInitialized()` → SwapPool.sol:198 `_initialized = true`. No function sets `_initialized = false`.

**If violated** — Pool can be re-initialized with different LP tokenIds, breaking the LP-to-market-token mapping.

---

#### I-5

`StateMachine` · On-chain: **Yes**

> `LPToken.pool[tokenId]: address(0) → concrete` — one-shot registration latch, no reverse path

**Derivation** — Edge: LPToken.sol:101 `if (pool[tokenId] != address(0)) revert TokenIdAlreadyRegistered()` → LPToken.sol:102 `pool[tokenId] = pool_`. No function resets pool[tokenId] to address(0).

**If violated** — A tokenId could be rebound to a different pool, allowing unauthorized mint/burn of LP tokens.

---

#### I-6

`Conservation` · On-chain: **Yes**

> `LPToken.totalSupply[tokenId] == Σ balanceOf(user, tokenId)` for all users

**Derivation** — Δ-pair: LPToken.sol:107 `totalSupply[tokenId] += amount` paired with `_mint(to, tokenId, amount)` (OZ ERC1155 increments balanceOf). LPToken.sol:112 `totalSupply[tokenId] -= amount` paired with `_burn(from, tokenId, amount)`. No other write sites for totalSupply. Transfers via `_update` do not change totalSupply.

**If violated** — Rate calculations (`sideValue * 1e18 / supply`) return wrong values, enabling over/under-valued LP claims.

---

#### I-7

`Temporal` · On-chain: **Yes**

> Fresh LP deposit graduates to matured after `LOCK_PERIOD` (24 hours): `block.timestamp >= freshDeposit.timestamp + 24h` → fresh amount treated as 0

**Derivation** — Temporal predicate: LPToken.sol:121 `if (f.amount == 0 || block.timestamp >= f.timestamp + LOCK_PERIOD) return 0` and LPToken.sol:152 `if (block.timestamp >= sf.timestamp + LOCK_PERIOD) { sf.amount = 0; sf.timestamp = 0; }`. LOCK_PERIOD = 24 hours (constant, LPToken.sol:51).

**If violated** — JIT fee applied to matured LP (overtaxing) or not applied to fresh LP (undertaxing).

---

#### I-8

`Bound` · On-chain: **Yes**

> `usedMarketATokenId[id]` once true, never reset to false

**Derivation** — Guard-lift: PoolFactory.sol:204 `if (usedMarketATokenId[marketA_.tokenId]) revert MarketATokenIdAlreadyUsed(...)`. Write site: PoolFactory.sol:220 `usedMarketATokenId[lpIdA] = true`. No function resets to false.

**If violated** — Same marketA tokenId reused across pools, causing LP tokenId collision on the shared LPToken instance.

---

#### I-9

`Bound` · On-chain: **Yes**

> `usedMarketBTokenId[id]` once true, never reset to false

**Derivation** — Guard-lift: PoolFactory.sol:205 `if (usedMarketBTokenId[marketB_.tokenId]) revert MarketBTokenIdAlreadyUsed(...)`. Write site: PoolFactory.sol:221 `usedMarketBTokenId[lpIdB] = true`. No function resets to false.

**If violated** — Same marketB tokenId reused across pools, causing LP tokenId collision.

---

#### I-10

`Ratio` · On-chain: **Yes**

> LP minting: `lpMinted = normAmount * supply / sideValue` when `supply > 0`; `lpMinted = normAmount` when `supply == 0`

**Derivation** — SwapPool.sol:268-270. The ratio uses `supply` (snapshot of current totalSupply) and `sideValue` (snapshot of current side accounting value). Both snapshots taken BEFORE state changes in the same function body (normAmount not yet added to sideValue, LP not yet minted).

**If violated** — LP tokens minted at wrong rate, diluting or enriching the depositor relative to existing LPs.

---

#### I-11

`Ratio` · On-chain: **Yes**

> LP claim: `shares = lpAmount * rate / RATE_PRECISION` where `rate = sideValue * RATE_PRECISION / supply`

**Derivation** — SwapPool.sol:584-587 `_lpToShares` reads rate via `marketARate()`/`marketBRate()` at SwapPool.sol:212-223. Rate uses current `sideValue` and `totalSupply` — snapshot taken before withdrawal state changes.

**If violated** — Withdrawers receive incorrect claim amounts, breaking conservation.

---

## 3. Inferred Invariants (Cross-Contract)

---

#### X-1

On-chain: **Yes**

> SwapPool assumes LPToken.totalSupply accurately reflects outstanding LP for rate calculation

**Caller side** — `SwapPool.sol:213,220` — `factory.marketALpToken().totalSupply(marketALpTokenId)` used in rate calculation

**Callee side** — `LPToken.sol:107,112` — totalSupply only modified by `mint()` and `burn()`, both gated by `onlyPool(tokenId)` modifier (LPToken.sol:84)

**If violated** — Rate calculation returns wrong values; LP minting and withdrawal claims are incorrect.

---

#### X-2

On-chain: **Yes**

> SwapPool assumes factory's LP token references are immutable

**Caller side** — `SwapPool.sol:637-638` — `_lpToken()` returns `factory.marketALpToken()` / `factory.marketBLpToken()`

**Callee side** — `PoolFactory.sol:70-73` — both declared `immutable`, set in constructor only

**If violated** — Pool operates on different LP token instances mid-lifecycle, corrupting all LP accounting.

---

#### X-3

On-chain: **Yes**

> SwapPool's feeCollector is immutable even though factory's feeCollector can change

**Caller side** — `SwapPool.sol:63` — `FeeCollector public immutable feeCollector` set at construction

**Callee side** — `PoolFactory.sol:283-286` — `setFeeCollector()` can change factory's feeCollector. New pools use new collector; existing pools keep the old one.

**If violated** — Not a safety issue. Operational concern: old pools continue sending fees to old collector after factory-level change.

---

#### X-4

On-chain: **No**

> SwapPool assumes ERC-1155 market contracts transfer exact amounts and revert on failure

**Caller side** — `SwapPool.sol:658` — `IERC1155(_marketContract(side)).safeTransferFrom(from, address(this), _tokenId(side), amount, "")` — pool updates internal accounting by `amount` without checking actual balance change

**Callee side** — External ERC-1155 contracts (MarketA, MarketB) — behavior depends on implementation. If the market contract is upgradeable, future behavior may diverge from current.

**If violated** — Internal accounting desyncs from actual token balances, breaking the conservation invariant (I-1) and potentially making the pool insolvent.

---

## 4. Economic Invariants

---

#### E-1

On-chain: **Yes**

> LP share value (rate) is monotonically non-decreasing from swap fees and withdrawal fees

**Follows from** — `I-1` (conservation) + `I-10` (minting ratio) + `I-11` (claim ratio): swap fees increase sideValue without changing supply → rate increases. Same-side JIT withdrawal fees stay on the burning side (or move to opposite side if last LP). Cross-side withdrawal fees credit the receive side. No operation decreases sideValue without proportionally decreasing supply.

**If violated** — LP value loss without impermanent loss or external cause — indicates a fee accounting bug.

---

#### E-2

On-chain: **Yes**

> Total extractable value equals total deposited value plus fees earned minus protocol fees extracted

**Follows from** — `I-1` (conservation) + `I-6` (supply conservation) + `X-1` (totalSupply accuracy): the conservation invariant guarantees tracked value equals physical balance. When all LP is burned, `_flushResidualIfEmpty` sweeps any residual dust to FeeCollector, zeroing both accounting values.

**If violated** — Funds trapped in pool after all LP exits, or more value extractable than was deposited (insolvency).
