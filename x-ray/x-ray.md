# X-Ray Report

> PredictSwap | 808 nSLOC | 98b4e12 (`main`) | Foundry | 23/04/26

---

## 1. Protocol Overview

**What it does:** A 1:1 swap pool for matched ERC-1155 prediction-market outcome shares across two platforms (e.g. Polymarket YES ↔ PredictFun YES for the same event).

- **Users**: LPs deposit single-sided to earn swap fees; swappers exchange equivalent outcome shares cross-platform
- **Core flow**: deposit → swap (1:1 minus fees) → withdraw (same-side or cross-side)
- **Key mechanism**: Simplified value accounting with two scalars (`aSideValue`, `bSideValue`) and per-side LP rates; no constant-product curve
- **Token model**: Two external ERC-1155 prediction-market tokens per pool; two shared ERC-1155 LP tokens (one per side, deployed by factory); LP tokenId mirrors the underlying market tokenId
- **Admin model**: Owner (intended multisig) controls fees and rescue; Operator (EOA) creates pools and manages pause/resolve lifecycle. No timelock. No proxy.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Pool Core | SwapPool | 436 | 1:1 AMM — deposit, swap, withdrawal, pro-rata exit, value accounting |
| Factory & Registry | PoolFactory | 216 | Deploys pools, LP token instances; registry; admin relay |
| LP Positions | LPToken | 105 | Shared ERC-1155 LP token with two-bucket JIT lock |
| Fee Collection | FeeCollector | 51 | Protocol fee accumulator; owner-withdrawable |

### How It Fits Together

The core trick: both sides of a prediction-market outcome are treated as 1:1 in value; the pool tracks two scalar accounting values (`aSideValue`/`bSideValue`) and derives per-side LP rates by dividing each by its LP supply.

### Deposit & LP Minting

```
User
└─ SwapPool.deposit(side, amount)
   ├─ _pullTokens()          *ERC-1155 safeTransferFrom from user*
   ├─ _toNorm()              *normalize to 18-dec*
   ├─ lpMinted = normAmt * supply / sideValue   *or 1:1 if first deposit*
   ├─ _addSideValue(side, normAmount)            *accounting update*
   └─ _mintLp() → LPToken.mint()
      └─ _update()           *fresh bucket bookkeeping on recipient*
```

### Swap (A → B)

```
User
└─ SwapPool.swap(fromSide=A, sharesIn)
   ├─ _computeFees()         *ceil-rounded total, then split LP/protocol*
   ├─ physicalBalanceNorm(B)  *liquidity check*
   ├─ _pullTokens(A)         *pull input shares from user*
   ├─ _pushTokens(A → FeeCollector)   *protocol fee in input-side tokens*
   ├─ _pushTokens(B → User)           *output shares to swapper*
   └─ _addSideValue(B, lpFee)         *LP fee accrues to drained side*
```
*LP fee goes to B-side value because B reserves were consumed — `marketBRate` grows, `marketARate` unchanged.*

### Withdrawal (unified)

```
User
└─ SwapPool.withdrawal(receiveSide, lpAmount, lpSide)
   ├─ _lpToShares()          *claim = lpAmount * rate / 1e18*
   ├─ _freshConsumedForBurn() → LPToken.lockedAmount()
   │                          *JIT fee on fresh portion only (same-side, unresolved)*
   ├─ _subSideValue()        *accounting debit*
   ├─ _burnLp() → LPToken.burn()
   ├─ _pushTokens(receiveSide → User)
   ├─ _pushTokens(receiveSide → FeeCollector)   *protocol fee*
   └─ _flushResidualIfEmpty()  *sweep dust when both LP supplies = 0*
```

### Pool Lifecycle (Operator)

```
Operator
└─ PoolFactory.createPool(marketA, marketB, fees)
   ├─ new SwapPool(...)
   ├─ LPToken.registerPool(pool, lpId)  ×2   *one-shot per side*
   └─ SwapPool.initialize(lpIdA, lpIdB)

Operator
└─ PoolFactory.resolvePoolAndPause(poolId)
   └─ SwapPool.setResolvedAndPaused()
      *resolved=true, depositsPaused=true, swapsPaused=true*
      *users exit via withdrawProRata() — no fees, proportional split*
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **DEX/AMM** — specialized 1:1 swap pool for matched ERC-1155 prediction-market outcome shares

Code signals: `swap()`, `deposit()` (single-sided addLiquidity), `withdrawal()`/`withdrawProRata()` (removeLiquidity), LP token mint/burn, fee tiers, per-side reserves tracking. Not a constant-product AMM — uses fixed 1:1 pricing with fee deduction. No oracle dependency, no borrowing, no leverage.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| User / LP | Untrusted | deposit, swap, withdrawal, withdrawProRata — all permissionless, nonReentrant |
| Operator | Bounded (can only manage pool lifecycle) | createPool, pause deposits/swaps, resolve pools. Cannot change fees, cannot rescue funds. All actions instant — no timelock. |
| Owner | Trusted (intended multisig per README) | setPoolFees (instant, capped at 1% LP + 0.5% protocol), setFeeCollector, setOperator, rescue* functions. All instant — no on-chain timelock or multisig enforcement. |
| FeeCollector Owner | Trusted | withdraw accumulated protocol fees. Separate from PoolFactory owner in deployment (same key possible). |

**Adversary Ranking** (ordered by threat level for this protocol type):

1. **MEV searcher / JIT liquidity attacker** — deposits immediately before a swap to capture fees, withdraws immediately after. The 24h two-bucket lock is the primary defense.
2. **Malicious market contract** — the ERC-1155 market contracts are immutably bound at factory deploy; if one has non-standard transfer behavior or reentrancy, it affects all pools.
3. **Compromised operator** — can resolve pools to waive all fees, pause/unpause to manipulate which withdrawal path is available, create pools with zero fees.
4. **Compromised owner** — can change fees to maximum, redirect fee collector, rescue surplus tokens; no timelock on any action.
5. **First depositor / empty-pool attacker** — exploits the `supply == 0` branch where LP mints 1:1; less severe than ERC4626 inflation since there's no donation vector (internal accounting, not `balanceOf`).

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Factory → SwapPool admin relay** — all SwapPool admin functions check `msg.sender == address(factory)`. Factory is immutable on the pool — if factory has a bug, all pools are affected. No timelock on any operational action.

- **LPToken pool registration** — `pool[tokenId]` is a one-shot latch (`LPToken.sol:101`). Once registered, the pool address cannot change for that tokenId. If a pool must be redeployed, both LPToken instances must also be redeployed. *Git signal: LPToken.sol modified in 6 of 11 source-touching commits.*

- **External ERC-1155 market contracts** — immutably bound at factory deploy (`PoolFactory.sol:165-166`). All `safeTransferFrom` calls trust the market contract to behave per ERC-1155 spec. If the market contract is upgradeable or non-standard, every pool on this factory is exposed.

### Key Attack Surfaces

- **Swap effects-after-interactions ordering** &nbsp;&#91;[I-1](invariants.md#i-1)&#93; — `SwapPool.sol:319` `_addSideValue(toSide, lpFee)` executes after `_pushTokens` at `:316`; `nonReentrant` prevents re-entry but worth confirming no view-function read of stale `bSideValue`/`aSideValue` is possible via ERC-1155 callback during the push.

- **Weighted-average timestamp manipulation in JIT lock** &nbsp;&#91;[I-7](invariants.md#i-7)&#93; — `LPToken.sol:183-186` merges incoming LP into the fresh bucket with a weighted-average timestamp; worth checking whether an attacker can send 1 wei of LP to a victim to shift their fresh timestamp forward, extending their lock and increasing their JIT fee on withdrawal.

- **`_fromNorm` truncation on low-decimal tokens** &nbsp;&#91;[I-1](invariants.md#i-1), [I-11](invariants.md#i-11)&#93; — `SwapPool.sol:653` divides by `10^(18-dec)`; for 6-decimal tokens, repeated deposit/withdraw cycles could accumulate truncation dust. Worth tracing whether the dust always favors the pool (safe) or can favor the user.

- **Operator resolve-to-waive-fees** — `PoolFactory.sol:308-311` `setResolvePool` waives cross-side fees and JIT fees instantly. A compromised operator could resolve an active pool to let a collaborating user withdraw cross-side fee-free, then un-resolve. No on-chain constraint prevents toggling.

- **`rescueERC1155` blocks entire market contract address** &nbsp;&#91;[G-27](invariants.md#g-27)&#93; — `SwapPool.sol:556-558` rejects rescue if `contractAddress_ == mktA || mktB`, regardless of tokenId. Non-pool tokenIds accidentally sent from the same market contract are permanently trapped.

- **`FeeCollector.recordFee` is permissionless** — `FeeCollector.sol:33` anyone can emit `FeeReceived` with arbitrary pool/token/amount. Off-chain indexers that aggregate fees must filter by known SwapPool sender addresses to avoid polluted accounting.

- **Last-LP fee redistribution edge case** &nbsp;&#91;[I-1](invariants.md#i-1)&#93; — `SwapPool.sol:377-384` when the last LP on a side exits with a JIT fee, the fee is credited to the opposite side. Worth checking if an attacker can time a same-side exit as the last LP to redirect their JIT fee to a position they also control on the opposite side.

- **Pro-rata native share calculation precision** — `SwapPool.sol:437` `nativeShare = (lpAmount * availableNative) / totalSupply` performs multiplication before division (safe from truncation), but if both numerators are large, worth confirming no uint256 overflow for realistic token amounts with 18 decimals.

### Protocol-Type Concerns

**As a DEX/AMM:**
- **1:1 pricing assumption without oracle** — the pool assumes both sides are economically equivalent. If the underlying event resolves or one platform depegs, this assumption breaks. The `resolved` flag + `resolvePoolAndPause` is the mitigation, but it depends on timely operator action.
- **LP share inflation at `supply == 0`** — `SwapPool.sol:268-269` first deposit mints 1:1. After `_flushResidualIfEmpty` zeroes everything, the next deposit restarts at 1:1 — worth confirming no state leaks across epochs.

### Temporal Risk Profile

**Deployment & Initialization:**
- `SwapPool.initialize()` is factory-gated (`SwapPool.sol:195`) and one-shot (`SwapPool.sol:196`), called atomically in `createPool` — no front-running window between deploy and init.
- `PoolFactory` constructor validates all addresses non-zero and names non-empty (`PoolFactory.sol:156-163`); ownership set via OZ `Ownable(owner_)` — transfer to multisig must happen post-deploy, creating a window where deployer EOA is owner.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **MarketA / MarketB ERC-1155** — via `SwapPool._pullTokens` / `_pushTokens`
> - Assumes: standard ERC-1155 `safeTransferFrom` — exact amount transferred, reverts on failure, no fee-on-transfer
> - Validates: NONE (trusts `safeTransferFrom` to move exact amount)
> - Mutability: Immutable binding at factory deploy; but the ERC-1155 contract itself may be upgradeable
> - On failure: revert (safeTransferFrom reverts → whole tx reverts)

> **OpenZeppelin Contracts** — via inheritance (ERC1155, Ownable, ReentrancyGuard, SafeERC20)
> - Assumes: standard OZ v5 behavior
> - Validates: N/A (compile-time dependency)
> - Mutability: Submodule pinned in `lib/openzeppelin-contracts`
> - On failure: N/A

**Token Assumptions** (unvalidated):
- ERC-1155 market tokens: assumes no callback reentrancy beyond what `nonReentrant` covers — if market contract implements custom hooks that re-enter through a different contract, cross-contract reentrancy could bypass the per-contract guard
- ERC-1155 market tokens: assumes `balanceOf` is not manipulable by direct transfer (donation). Pool uses internal accounting (`aSideValue`/`bSideValue`) rather than `balanceOf` — donation-immune by design

---

## 3. Invariants

> ### Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **27 Enforced Guards** (`G-1` … `G-27`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **11 Single-Contract Invariants** (`I-1` … `I-11`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **4 Cross-Contract Invariants** (`X-1` … `X-4`) — caller/callee pairs that cross scope boundaries
> - **2 Economic Invariants** (`E-1` … `E-2`) — higher-order properties deriving from `I-N` + `X-N`
>
> Every inferred block cites a concrete Δ-pair, guard-lift + write-sites, state edge, temporal predicate, or NatSpec quote. The **On-chain=No** blocks are the high-signal ones — each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks (e.g. `[X-4]`, `[I-17]`).

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` — thorough: architecture, mechanics, fee math, withdrawal matrix, security properties |
| NatSpec | ~4 annotations | Sparse — title/notice on contracts, but few `@param`/`@return` on functions |
| Spec/Whitepaper | Missing | README serves as informal spec |
| Inline Comments | Adequate | Key design decisions documented (value accounting, fee routing, JIT lock), some NatSpec invariant claims |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 2 | File scan |
| Test functions | 49 | File scan |
| Line coverage | 84.82% (SwapPool), 100% (LPToken), 67.39% (PoolFactory), 10.71% (FeeCollector) | `forge coverage --ir-minimum` |
| Branch coverage | 44.59% (SwapPool), 61.11% (LPToken), 8.00% (PoolFactory), 0% (FeeCollector) | `forge coverage --ir-minimum` |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 49 | SwapPool, LPToken, PoolFactory, FeeCollector (minimal) |
| Stateless Fuzz | 0 | none |
| Stateful Fuzz (Foundry) | 0 | none |
| Stateful Fuzz (Echidna) | 0 | none |
| Stateful Fuzz (Medusa) | 0 | none |
| Formal Verification (Certora) | 0 | none |
| Formal Verification (Halmos) | 0 | none |
| Formal Verification (HEVM) | 0 | none |

### Gaps

- **No stateless fuzz testing** — fee math, rounding, and decimal normalization are prime targets for property-based fuzzing. The ceiling-rounded fee split and `_toNorm`/`_fromNorm` conversions with varying decimal precision should be fuzzed.
- **No stateful fuzz / invariant testing** — the value conservation invariant (`aSideValue + bSideValue == physicalA + physicalB`) is tested deterministically but never under randomized operation sequences. This is the highest-priority gap.
- **No formal verification** — LP minting/burning rate math and the two-bucket lock timestamp merging are amenable to symbolic analysis.
- **FeeCollector branch coverage is 0%** — `withdrawBatch`, `withdrawAll`, `withdrawAllBatch` are untested.
- **PoolFactory branch coverage is 8%** — most admin paths and error branches are untested.

---

## 6. Developer & Git History

> Repo shape: normal_dev — 26 total commits (11 source-touching) over 49 days by a single developer.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Iurii | 26 | +2830 / -1534 | 100% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-developer project |
| Merge commits | 0 of 26 (0%) | No merge commits — no peer review evidence |
| Repo age | 2026-03-04 → 2026-04-22 | 49 days |
| Recent source activity (30d) | 6 commits | Active — includes major v2 rewrite |
| Test co-change rate | 81.8% | Good — most source changes include test updates |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| src/SwapPool.sol | 11 | Highest churn — core AMM logic |
| src/PoolFactory.sol | 10 | High churn — registry + admin relay |
| src/LPToken.sol | 6 | JIT lock logic modified across versions |
| src/FeeCollector.sol | 5 | Moderate churn |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 00e897d | 2026-03-04 | first full version with tests and deploy | 16 | removes guards, tightens access control, spans 3 security domains |
| 98b4e12 | 2026-04-22 | updated to v2 | 13 | removes 8 guards, loosens access control, 1204 lines changed |
| 0b9d21f | 2026-03-04 | init | 13 | initial codebase — adds 45 guards, 9 access control patterns |
| ba90e05 | 2026-03-23 | updated to two LP version | 11 | architectural shift to two LP tokens per factory |
| 54b2735 | 2026-04-08 | updated Factory and Pool | 9 | loosens access control, 848 lines, no test changes |
| e1740e6 | 2026-03-23 | updated based on audit findings | 8 | rewrites access control — audit-driven fixes |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| fund_flows | 11 | SwapPool.sol, LPToken.sol, FeeCollector.sol |
| state_machines | 11 | SwapPool.sol, PoolFactory.sol |
| access_control | 10 | PoolFactory.sol, LPToken.sol, FeeCollector.sol |

### Forked Dependencies

| Library | Path | Upstream | Status | Notes |
|---------|------|----------|--------|-------|
| openzeppelin-contracts | lib/openzeppelin-contracts | OpenZeppelin | Submodule | Multiple pragma versions detected (^0.8.20 → ^0.8.24); standard upstream, not internalized |

### Security Observations

- **Single-developer project** — 100% of code by one author (Iurii), 0 merge commits across 26 commits.
- **Major v2 rewrite 1 day before analysis** — commit `98b4e12` (2026-04-22) changed 1204 lines across 3 source files, loosened access control, removed 8 runtime guards.
- **848-line commit without tests** — `54b2735` (2026-04-08) "updated Factory and Pool" has `test_changed: false`.
- **Audit-driven fix commit without tests** — `e1740e6` "updated based on audit findings" has `test_changed: false`, rewrites access control.
- **SwapPool.sol is the dominant hotspot** — 11 modifications, 675 lines, core of all value flows.
- **FeeCollector coverage near zero** — 10.71% line / 0% branch; withdrawal paths untested.

### Cross-Reference Synthesis

- **SwapPool.sol is #1 in BOTH churn AND attack-surface priority** — all top surfaces route through it (fee math, value accounting, LP interactions, ERC-1155 callbacks) → highest-leverage review target.
- **v2 rewrite (98b4e12) loosened access control + removed guards** — this is the newest and largest commit, touching 3/4 source files. Combined with zero fuzz testing, the new code paths are the least validated.
- **Audit findings commit (e1740e6) rewrites access control without test updates** — residual risk that fixes were incomplete or introduced new issues.

---

## X-Ray Verdict

**FRAGILE** — Unit tests exist (49 functions, 81.8% test co-change rate) but no fuzz, invariant, or formal verification testing for a protocol whose core security property (value conservation) is highly amenable to property-based and stateful testing.

**Structural facts:**
1. 808 nSLOC across 4 contracts, single subsystem — compact and reviewable
2. Single developer wrote 100% of code with 0 merge commits — no evidence of peer review
3. Major 1204-line v2 rewrite committed 1 day before this analysis, including loosened access control and removed guards
4. No timelock or on-chain multisig enforcement — all admin/operator actions are instant
5. FeeCollector has 0% branch coverage and 10.71% line coverage; PoolFactory branch coverage is 8%
