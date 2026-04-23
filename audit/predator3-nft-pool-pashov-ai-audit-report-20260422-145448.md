# 🔐 Security Review — predator3. Nft pool

---

## Scope

|                                  |                                                                                       |
| -------------------------------- | ------------------------------------------------------------------------------------- |
| **Mode**                         | default                                                                               |
| **Files reviewed**               | `FeeCollector.sol` · `LPToken.sol` · `PoolFactory.sol`<br>`SwapPool.sol`              |
| **Confidence threshold (1-100)** | 80                                                                                    |

---

## Findings

[90] **1. Orphan side-value residual is captured by the next depositor on an emptied side**

`SwapPool.deposit` · Confidence: 90

**Description**
When the last LP on a side withdraws same-side with any fresh portion, `withdrawal` retains `lpFee` inside `aSideValue`/`bSideValue` (line 373: `_subSideValue(lpSide, shares - lpFee)`); `_flushResidualIfEmpty` only sweeps when *both* sides are empty (line 465), so if the other side still has LPs the residual persists with `supplyA == 0 && aSideValue > 0`. The next attacker deposit hits the `supply == 0` branch (line 267) and mints 1:1, inflating `marketARate` to `(residual + depositNorm) / 1` — the attacker's single LP can then be burned to extract the entire residual (minus re-JIT fee on ~1% of the now-inflated shares). With a 1% JIT fee, Alice leaves `lpFee = 10` behind; Eve deposits 1 norm unit, `marketARate` becomes 11e18, her burn yields `shares = 11` → payout `= 10` for a 1-unit deposit. Profit compounds over the pool's lifetime whenever a side empties.

**Fix**

```diff
     function _flushResidualIfEmpty() internal {
         uint256 aSupply = factory.marketALpToken().totalSupply(marketALpTokenId);
         uint256 bSupply = factory.marketBLpToken().totalSupply(marketBLpTokenId);
-        if (aSupply + bSupply > 0) return;
-
-        aSideValue = 0;
-        bSideValue = 0;
-
-        uint256 rawA = IERC1155(_marketContract(Side.MARKET_A))
-            .balanceOf(address(this), marketATokenId);
-        uint256 rawB = IERC1155(_marketContract(Side.MARKET_B))
-            .balanceOf(address(this), marketBTokenId);
-
-        if (rawA > 0) {
-            _pushTokens(Side.MARKET_A, address(feeCollector), rawA);
-            feeCollector.recordFee(_marketContract(Side.MARKET_A), marketATokenId, rawA);
-        }
-        if (rawB > 0) {
-            _pushTokens(Side.MARKET_B, address(feeCollector), rawB);
-            feeCollector.recordFee(_marketContract(Side.MARKET_B), marketBTokenId, rawB);
-        }
+        if (aSupply == 0 && aSideValue > 0) {
+            aSideValue = 0;
+            uint256 rawA = IERC1155(_marketContract(Side.MARKET_A))
+                .balanceOf(address(this), marketATokenId);
+            if (rawA > 0) {
+                _pushTokens(Side.MARKET_A, address(feeCollector), rawA);
+                feeCollector.recordFee(_marketContract(Side.MARKET_A), marketATokenId, rawA);
+            }
+        }
+        if (bSupply == 0 && bSideValue > 0) {
+            bSideValue = 0;
+            uint256 rawB = IERC1155(_marketContract(Side.MARKET_B))
+                .balanceOf(address(this), marketBTokenId);
+            if (rawB > 0) {
+                _pushTokens(Side.MARKET_B, address(feeCollector), rawB);
+                feeCollector.recordFee(_marketContract(Side.MARKET_B), marketBTokenId, rawB);
+            }
+        }
     }
```

Side-local flushing also covers the previous "both empty" case.

---

[75] **2. Cross-side withdrawal is fee-free while `resolved && !swapsPaused`, enabling losing-side LPs to drain winning-side reserves 1:1**

`SwapPool.withdrawal` · Confidence: 75

**Description**
`withdrawal` skips fees on cross-side claims when `resolved` (lines 356–361): `if (!resolved) { (lpFee, protocolFee) = _computeFees(shares); }`. The operator can reach `resolved && !swapsPaused` by calling `PoolFactory.setResolvePool` (line 308) instead of the paired `resolvePoolAndPause` (line 316). In that state any holder of the losing-side LP burns it and receives `shares` of the *winning*-side physical tokens at 1:1 (post-resolution prediction-market tokens on opposite outcomes are not 1:1 in market value), draining winning-side liquidity from LPs who hold the valuable side. The author flagged this in-source (`PoolFactory.sol:314` "it should be fired as soon as any side of the pool resolved, so users can not drain…"); the footgun is exposed as a first-class operator action.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | Orphan side-value residual is captured by the next depositor on an emptied side |
| 2 | [75] | Cross-side withdrawal is fee-free while `resolved && !swapsPaused`, draining winning-side reserves |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Self-transfer inflates `freshDeposit.amount` above `balanceOf`** — `LPToken._update` — Code smells: `balanceOf(from, id) + value` at line 156 overstates pre-balance when `from == to` (super already balanced at net-zero), and the subsequent inflow branch still runs `tf.amount += value` at line 186, producing `freshDeposit.amount == balance + value` after a self-transfer. Unverified: whether any reachable integration reads `isLocked`/`lockedAmount` in a way that misbehaves when the invariant is broken — SwapPool itself clamps via `matured = balance > locked ? balance-locked : 0`, so within this repo it is only self-harm (over-charges the self-transferrer's JIT fee until maturity).

- **Per-pool `feeCollector` is immutable; factory rotation is non-propagating** — `SwapPool.feeCollector` — Code smells: `SwapPool.feeCollector` is `immutable` (line 63), initialized from `address(factory.feeCollector)` at construction. `PoolFactory.setFeeCollector` (line 283) rotates the factory's reference but every pre-existing pool keeps routing `recordFee`/`rescue` flows to the old collector. Unverified: whether any upgrade plan exists that relies on in-place rotation — if so, fees from existing pools continue flowing to the retired contract silently.

- **`rescueTokens` surplus check sums both sides' tracked value against one-side physical** — `SwapPool.rescueTokens` — Code smells: `tracked = aSideValue + bSideValue` (line 532) is compared to `physicalBalanceNorm(side)` (single side), so legitimate cross-side physical surplus (e.g. LP fees collected in `swap` that exceed the drained side's physical reserves) can be un-rescuable even when aggregate is balanced. Unverified: whether any real operational state will actually need to call rescue; impact is admin-only (cannot reclaim funds that ended up on one side), no user harm.

- **Swap and withdrawal push `0` raw tokens when low-decimal rounding zeroes `_fromNorm`** — `SwapPool.swap`, `SwapPool.withdrawal` — Code smells: `rawOut = _fromNorm(toSide, normOut)` (SwapPool:313) and `rawPayout = _fromNorm(receiveSide, payout)` (SwapPool:384) both guard `if (rawOut > 0)`/`if (rawPayout > 0)` after already `_pullTokens`-ing the full input, so on 6-decimal (or other sub-18) tokens a dust-size action accepts input/burns LP without pushing output. Unverified: whether any intended deployment pairs a low-decimal market — current testing uses 18-decimal mocks; on Polymarket (6 decimals) this becomes a user-visible self-harm trap.

- **Weighted-average timestamp can be moved backward by a dust transfer, marginally extending the recipient's lock** — `LPToken._update` — Code smells: `tf.timestamp = (tf.amount * tf.timestamp + value * block.timestamp) / (tf.amount + value)` (line 183) is monotone non-decreasing in `block.timestamp` (so lock extension is bounded by `LOCK_PERIOD`), but transferring non-negligible `value` to a victim refreshes their effective lock by up to `value / (tf.amount + value) * (now − oldTs)`. Unverified: attacker must surrender the transferred LP permanently (cost ≈ transferred value), while victim's grief is at most 0.4% of the extended portion — net unprofitable, but worth flagging if LP tokens ever become cheap to acquire (e.g. secondary markets).

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
