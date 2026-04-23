# 🔐 Security Review — PredictSwap v3

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | `src/FeeCollector.sol` · `src/LPToken.sol`<br>`src/PoolFactory.sol` · `src/SwapPool.sol` |
| **Files reviewed**               | `FeeCollector.sol` · `LPToken.sol`<br>`PoolFactory.sol` · `SwapPool.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

---

## Findings

[90] **1. Last-LP same-side JIT withdrawal permanently locks opposite-side LP funds**

`SwapPool.withdrawal` · Confidence: 90

**Description**
When the last LP on a side exits same-side with a JIT fee, `_addSideValue(_oppositeSide(lpSide), lpFee)` inflates the opposite side's tracked value by `lpFee`, but the only physical tokens backing it are `lpFee` worth of native-side tokens (e.g. 3 A-tokens). The opposite-side LP holders cannot withdraw same-side (`bSideValue=1003 > physB=1000`) nor cross-side (`payout≈999 > physA=3`), permanently locking their funds until the operator pauses swaps to enable `withdrawProRata`.

**Fix**

```diff
  if (isLastLp && lpFee > 0) {
      _subSideValue(lpSide, shares);
-     _addSideValue(_oppositeSide(lpSide), lpFee);
  } else {
```

---

[75] **2. `recordFee` is callable by anyone, enabling off-chain accounting manipulation**

`FeeCollector.recordFee` · Confidence: 75 · [agents: 6]

**Description**
`recordFee` has no access control — any address can call it with arbitrary `token`, `tokenId`, and `amount` parameters to emit spoofed `FeeReceived` events, corrupting off-chain fee dashboards and indexers that don't filter by known SwapPool addresses.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | Last-LP same-side JIT withdrawal permanently locks opposite-side LP funds |
| 2 | [75] | `recordFee` callable by anyone — off-chain accounting manipulation |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Cross-side withdrawal LP fee inflates receive-side value beyond physical backing** — `SwapPool.withdrawal` — Code smells: `_addSideValue(receiveSide, lpFee)` increases tracked value while physical tokens decrease by `shares - lpFee` — Over many cross-side withdrawals, `bSideValue` can exceed `physicalB`, forcing B-LPs into cross-side exits with unexpected fees. [agents: 5]

- **`withdrawProRata` does not decrement cross-side value** — `SwapPool.withdrawProRata` — Code smells: `_subSideValue(lpSide, shares)` only reduces native-side value; cross-side physical tokens leave without adjusting cross-side tracked value — Creates per-side value/physical divergence that compounds with each pro-rata exit. [agents: 2]

- **Self-transfer corrupts LPToken fresh-deposit tracking** — `LPToken._update` — Code smells: when `from == to`, `super._update` is a no-op on balance, so `preBalance = balanceOf + value` overestimates by `value`; each self-transfer inflates `sf.amount` above actual balance — Forces full JIT fee on future withdrawals and leaves stale non-zero `freshDeposit` state after full exit. [agents: 1]

- **Protocol fee truncates to zero on small swaps with low-decimal tokens** — `SwapPool.swap` — Code smells: `_fromNorm(fromSide, protocolFee)` truncates to 0 when `protocolFee < 10^(18-dec)` — Fee deducted from user output but feeCollector receives nothing; untracked dust accumulates. [agents: 2]

- **`setFeeCollector` doesn't propagate to existing pools** — `PoolFactory.setFeeCollector` — Code smells: `SwapPool.feeCollector` is `immutable` — Existing pools permanently route fees to old collector after factory update. [agents: 2]

- **LP transfer griefing extends victim's JIT lock period** — `LPToken._update` — Code smells: inflow weighted-average timestamp `(tf.amount * tf.timestamp + value * block.timestamp) / (tf.amount + value)` — Transferring LP to a victim near maturity can extend their lock, forcing JIT fee on their next withdrawal; cost scales with victim's position size. [agents: 3]

- **`withdrawProRata` first-mover advantage under imbalanced pools** — `SwapPool.withdrawProRata` — Code smells: first withdrawer consumes cross-side tokens, potentially leaving opposite side with `InsufficientLiquidity` — Ordering of exits determines who can successfully withdraw when swaps are paused. [agents: 1]

- **JIT fee base rounds down, exempting fresh LP from fee for small fractions** — `SwapPool.withdrawal` — Code smells: `feeBase = (shares * freshBurned) / lpAmount` truncates; when `freshBurned * shares < lpAmount`, fee base rounds to zero — Users with small fresh portions relative to total withdrawal pay no JIT fee. [agents: 1]

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
