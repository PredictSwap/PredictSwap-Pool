# X-Ray Pre-Audit Report -- PredictSwap v3

| Field | Value |
|---|---|
| Protocol | PredictSwap v3 |
| Type | Prediction-market swap pool (DEX/AMM) |
| nSLOC | 823 (4 contracts) |
| Branch / Commit | main / 0432898 |
| Framework | Foundry |
| Solidity | ^0.8.24 |
| Date | 2026-04-23 |

---

## 1 Architecture Overview

See `architecture.json` for the interactive graph.

PredictSwap v3 deploys one **PoolFactory** per project pair (e.g. Polymarket vs PredictFun). The factory creates **SwapPool** instances, each holding two ERC-1155 prediction-market share types (market A, market B) and performing 1:1 swaps minus fees. Two shared **LPToken** ERC-1155 contracts (one per side) are created at factory construction time and serve every pool. A single **FeeCollector** accumulates protocol fee cuts from all pools.

**Key design choices:**

- LP tokenId == underlying market tokenId; strictly non-reusable across pools
- Value accounting in 18-decimal normalized units (aSideValue, bSideValue); physical token composition not tracked per-side
- Two-bucket JIT lock (fresh/matured) on LPToken prevents LP sniping; 24h lock, fee only on fresh portion during same-side withdrawal
- No proxies, no upgradability, no governance, no oracle dependency
- All SwapPool admin functions gated by `msg.sender == address(factory)`; factory gates on owner/operator roles

**Temporal phases:**

1. **Deployment & Initialization** -- PoolFactory constructor deploys LPTokens; createPool deploys SwapPool and calls initialize (one-shot)
2. **Steady State** -- deposits, swaps, withdrawals; operator can pause/resolve; owner can change fees

---

## 2 Trust & Privilege Model

### 2.1 Roles

| Role | Holder | Powers | Timelock |
|---|---|---|---|
| Owner | EOA (Ownable) | setFeeCollector, setOperator, setPoolFees, all rescue operations, FeeCollector withdrawals; can also perform operator actions | None |
| Operator | EOA set by owner | createPool, pause/unpause deposits/swaps, resolve/un-resolve pools, resolvePoolAndPause | None |
| User | Any address | deposit, swap, withdrawal, withdrawProRata | N/A |

### 2.2 Centralization Risks

- **Owner** can change fees instantly (up to hard caps) for any existing pool, can rescue surplus tokens from pools, can change feeCollector (affects only NEW pools), and can withdraw all accumulated protocol fees
- **Operator** can pause deposits/swaps at any time, resolve/un-resolve pools, and create new pools -- all without timelock
- **No multisig or timelock enforced on-chain** -- a compromised owner or operator key can materially affect user funds through fee changes, resolution toggling, or pause manipulation
- setFeeCollector on factory does NOT propagate to existing pools (SwapPool.feeCollector is immutable) -- see [X-4]

---

## 3 Invariant & Guard Catalog

Full invariant tables with derivations are in **[invariants.md](invariants.md)**.

Summary counts:
- **G-N** (Guards): 22 guards across all contracts
- **I-N** (Intra-contract invariants): 9 invariants on SwapPool + LPToken
- **X-N** (Cross-contract invariants): 4 cross-contract invariants
- **E-N** (Economic invariants): 2 economic invariants

---

## 4 Attack Surface Analysis

### 4.1 Value Accounting Divergence on Last-LP Same-Side JIT Withdrawal

**Contracts:** SwapPool.sol L378-382
**Invariant refs:** [I-1], [E-1]

When the last LP on a side withdraws with a JIT fee, the pool executes `_subSideValue(lpSide, shares)` then `_addSideValue(oppositeSide, lpFee)`. The lpFee tokens (~3 tokens) physically remain on lpSide, but oppositeSide's tracked value is inflated by lpFee. Opposite-side LPs now have bSideValue > physicalBalanceNorm(B). They cannot withdraw same-side (InsufficientLiquidity) nor cross-side (physA is only lpFee amount). They are forced to wait for operator to pause swaps so they can use withdrawProRata.

**Impact:** Temporary fund lock for opposite-side LPs until operator intervention (pause swaps).

### 4.2 Cross-Side Withdrawal Value/Physical Divergence

**Contracts:** SwapPool.sol L387-388
**Invariant refs:** [I-1]

On cross-side withdrawal, `_addSideValue(receiveSide, lpFee)` increases receiveSide tracked value while physical receiveSide tokens decrease by (shares - lpFee). Each cross-side withdrawal widens the divergence between tracked value and physical tokens on the receive side. B-side LPs may be forced into cross-side exits with fees.

**Impact:** Progressive value/physical mismatch can prevent same-side withdrawals for later LPs.

### 4.3 Self-Transfer Corrupts LPToken Fresh Bucket

**Contracts:** LPToken.sol L135-189
**Invariant refs:** [I-9]

When from == to, `super._update` is a no-op on balance, but the outflow logic computes `preBalance = balanceOf(from, id) + value`, which overestimates by `value`. Each self-transfer inflates `sf.amount` beyond the actual balance. This is self-harm only (the caller corrupts their own fresh bucket), but it produces persistent state corruption that can affect JIT fee calculations.

**Impact:** Self-harm; corrupted fresh bucket may cause incorrect JIT fee assessment on future withdrawals.

### 4.4 JIT Fee Base Rounding to Zero

**Contracts:** SwapPool.sol L356
**Invariant refs:** [I-5], [G-14]

`feeBase = (shares * freshBurned) / lpAmount` truncates down. When `freshBurned` is small relative to `lpAmount`, feeBase rounds to zero, exempting the user from the JIT fee entirely.

**Impact:** Small LP positions can bypass JIT fee via rounding.

### 4.5 Protocol Fee Truncation on Low-Decimal Tokens

**Contracts:** SwapPool.sol L308
**Invariant refs:** [I-2], [I-3]

`_fromNorm` truncates protocolFee to zero for small swap amounts with low-decimal tokens. The fee is deducted from the user's normalized amount, but the feeCollector receives zero raw tokens. The fee is effectively burned.

**Impact:** Protocol fee leakage (lost, not stolen) on small swaps with low-decimal tokens.

### 4.6 Operator Privilege -- No Timelock

**Contracts:** PoolFactory.sol L296-322
**Invariant refs:** [G-3], [G-4]

Operator can pause swaps, deposits, resolve, or un-resolve pools instantly. resolvePoolAndPause is atomic. A compromised operator can front-run user transactions by resolving a pool (removing cross-side fees) then immediately pausing -- or vice versa.

**Impact:** Trust assumption on operator; no on-chain delay for users to react.

### 4.7 recordFee Permissionless Spoofing

**Contracts:** FeeCollector.sol L33-36
**Invariant refs:** [G-22]

Anyone can call `recordFee` and emit a `FeeReceived` event with arbitrary parameters. Off-chain indexers that do not filter by known pool addresses will record spoofed fee data.

**Impact:** Off-chain accounting corruption; no on-chain fund risk.

### 4.8 rescueTokens Global Surplus Check

**Contracts:** SwapPool.sol L548-554
**Invariant refs:** [I-1]

rescueTokens uses global surplus = totalPhysical(A+B) - totalTracked. This means surplus tokens on side A can be "rescued" even if side A's physical balance equals or is less than its obligation, as long as side B has excess. The rescue can drain tokens from a side that needs them for LP withdrawals.

**Impact:** Owner can inadvertently (or maliciously) extract tokens obligated to one side by exploiting surplus on the other side.

### 4.9 setFeeCollector Does Not Propagate

**Contracts:** PoolFactory.sol L283-287, SwapPool.sol L63
**Invariant refs:** [X-4]

SwapPool.feeCollector is immutable, set at construction. Calling setFeeCollector on the factory only affects pools created after the change. Existing pools continue sending fees to the old address.

**Impact:** Operational surprise if the old FeeCollector is decommissioned; fees from existing pools become inaccessible unless old collector remains functional.

---

## 5 Coverage & Testing Gaps

### 5.1 Coverage Summary

| Contract | Lines | Stmts | Branches | Funcs |
|---|---|---|---|---|
| FeeCollector | 37.84% | 22.22% | 0% | 60% |
| LPToken | 100% | 90% | 61.11% | 100% |
| PoolFactory | 67.39% | 59.26% | 8% | 52.63% |
| SwapPool | 86.26% | 79.56% | 45.45% | 86.84% |

### 5.2 Key Gaps

- **FeeCollector branch coverage is 0%** -- no branch paths tested; withdrawAllBatch compact-array logic untested
- **PoolFactory branch coverage is 8%** -- nearly all revert paths (duplicate tokenId, duplicate pool key, zero address) untested
- **SwapPool branch coverage at 45%** -- last-LP JIT fee path (L378-382), cross-side withdrawal fee path, rescueTokens surplus logic likely undertested
- **No self-transfer test on LPToken** -- the from==to corruption path is not covered
- **No low-decimal token tests** -- protocol fee truncation path untested
- **No fork tests, no stateful fuzzing (echidna/medusa), no formal verification (certora/halmos)**
- **19 stateless fuzz tests, 6 foundry invariant tests** -- invariant tests likely do not cover cross-contract value conservation

### 5.3 Git Signals

- Single developer, 30 commits, 50 days
- 98b4e12 "updated to v2" touched 1204 lines -- large refactor with high regression risk
- 54b2735 "updated Factory and Pool" (848 lines) had no test changes
- fix_without_test_rate: 20%
- 4 late commits (last 30 days) including the v2 refactor

---

## X-Ray Verdict

**FRAGILE** — Unit tests, stateless fuzz, and Foundry invariant tests exist (76 functions, 19 fuzz, 6 invariant), but branch coverage is low (FeeCollector 0%, PoolFactory 8%, SwapPool 45%), no formal verification or advanced stateful fuzzing is present, and all admin/operator actions are instant with no timelock — the protocol's core value-conservation property needs stronger coverage.

**Structural facts:**
1. 823 nSLOC across 4 contracts in a single subsystem — compact and reviewable
2. Single developer wrote 100% of code with 0 merge commits — no evidence of peer review
3. Major 1204-line v2 rewrite committed in the last 30 days, including access control changes
4. No timelock or on-chain multisig enforcement — all admin/operator actions are instant
5. Key audit fixes applied since last review: `resolved` check added to `swap()`, zero-payout revert in `withdrawal()`, global surplus in `rescueTokens()`, compact arrays in `withdrawAllBatch()`
6. Last-LP same-side JIT fee value accounting remains an open concern across multiple prior audit runs
