// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../src/SwapPool.sol";
import "../../src/PoolFactory.sol";
import "../../src/LPToken.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title WithdrawBothSides
 * @notice Burns LP tokens and receives a split of both underlying assets.
 *
 * ─── Split ────────────────────────────────────────────────────────────────────
 *
 *   WITHDRAW_SAMESIDE_BPS controls what fraction of the gross output goes to
 *   the same-side token (basis points out of 10,000):
 *
 *     10000  →  100% same-side   (no cross-side fee, equivalent to withdrawSingleSide same-side)
 *      5000  →  50% / 50% split
 *         0  →  100% cross-side  (full fee on everything)
 *
 *   The split is computed on-chain at execution time from the actual grossOut,
 *   so the transaction never reverts due to a stale off-chain grossOut estimate.
 *
 * ─── Fees ─────────────────────────────────────────────────────────────────────
 *
 *   Fees apply only to the cross-side portion, unless the pool is resolved.
 *   Same-side portion is always free.
 *   Cross-side portion is blocked when swapsPaused = true.
 *
 * ─── Amount ───────────────────────────────────────────────────────────────────
 *
 *   Set WITHDRAW_LP_AMOUNT=0 to burn your entire balance of the chosen LP token.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY    — wallet holding LP tokens
 *   POOL_FACTORY_ADDRESS    — deployed PoolFactory address
 *   POOL_ID                 — pool index (0-based)
 *   WITHDRAW_LP_AMOUNT      — LP tokens to burn (0 = withdraw all)
 *   WITHDRAW_LP_SIDE        — LP token to burn: 0 = polyLpToken, 1 = opinionLpToken
 *   WITHDRAW_SAMESIDE_BPS   — same-side fraction in bps (0–10000)
 *
 * Run:
 *   forge script script/integration_tests/WithdrawBothSides.s.sol --rpc-url polygon --broadcast
 */
contract WithdrawBothSides is Script {
    function run() external {
        uint256 key           = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr      = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId        = vm.envUint("POOL_ID");
        uint256 lpAmount      = vm.envUint("WITHDRAW_LP_AMOUNT");
        uint256 lpSideRaw     = vm.envUint("WITHDRAW_LP_SIDE");
        uint256 samesideBps   = vm.envUint("WITHDRAW_SAMESIDE_BPS");

        address sender = vm.addr(key);
        PoolFactory factory   = PoolFactory(factAddr);
        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool         = SwapPool(payable(info.swapPool));

        SwapPool.Side lpSide  = SwapPool.Side(lpSideRaw);

        address lpAddr = lpSide == SwapPool.Side.POLYMARKET ? info.polyLpToken : info.opinionLpToken;
        LPToken lp     = LPToken(lpAddr);
        uint256 lpBal  = lp.balanceOf(sender);

        if (lpAmount == 0) lpAmount = lpBal;

        uint256 denom    = factory.FEE_DENOMINATOR();
        uint256 supply   = pool.totalLpSupply();
        uint256 grossOut = supply > 0 ? (lpAmount * pool.totalShares()) / supply : 0;

        uint256 samesideEst  = (grossOut * samesideBps) / denom;
        uint256 crosssideEst = grossOut - samesideEst;

        // Fee estimate on cross-side portion only
        uint256 totalFeeBps = factory.lpFeeBps() + factory.protocolFeeBps();
        uint256 crossFeeEst = (crosssideEst > 0 && !pool.resolved())
            ? (crosssideEst * totalFeeBps + denom - 1) / denom
            : 0;
        uint256 crossNetEst = crosssideEst - crossFeeEst;

        console.log("=== WithdrawBothSides ===");
        console.log("Pool ID:                 ", poolId);
        console.log("SwapPool:                ", info.swapPool);
        console.log("LP token:                ", lpAddr);
        console.log("LP side:                 ", lpSideRaw == 0 ? "POLYMARKET" : "OPINION");
        console.log("samesideBps:             ", samesideBps);
        console.log("Pool resolved:           ", pool.resolved() ? "YES (cross-side free)" : "NO");
        console.log("Pool swapsPaused:        ", pool.swapsPaused() ? "YES" : "NO");
        console.log("LP balance:              ", lpBal);
        console.log("LP to burn:              ", lpAmount);
        console.log("Gross out:               ", grossOut);
        console.log("Same-side estimate:      ", samesideEst);
        console.log("Cross-side gross est:    ", crosssideEst);
        console.log("Cross-side fee est:      ", crossFeeEst);
        console.log("Cross-side net est:      ", crossNetEst);
        console.log("Pool POLY bal:           ", pool.polymarketBalance());
        console.log("Pool OPINION bal:        ", pool.opinionBalance());
        console.log("Exchange rate:           ", pool.exchangeRate());
        console.log("Total LP supply:         ", supply);
        console.log("Wallet POLY:             ", IERC1155(factory.polymarketToken()).balanceOf(sender, info.polymarketTokenId));
        console.log("Wallet OPINION:          ", IERC1155(factory.opinionToken()).balanceOf(sender, info.opinionTokenId));
        console.log("");

        require(lpBal >= lpAmount, "Insufficient LP balance");
        require(lpAmount > 0, "Nothing to withdraw");
        require(samesideBps <= denom, "samesideBps exceeds 10000");
        if (crosssideEst > 0) require(!pool.swapsPaused(), "Swaps are paused. cross-side blocked");

        vm.startBroadcast(key);
        (uint256 samesideReceived, uint256 crosssideReceived) =
            pool.withdrawBothSides(lpAmount, lpSide, samesideBps);
        vm.stopBroadcast();

        console.log("=== Done ===");
        console.log("Same-side received:       ", samesideReceived);
        console.log("Cross-side received:      ", crosssideReceived);
        console.log("LP remaining:             ", lp.balanceOf(sender));
        console.log("Wallet POLY after:        ", IERC1155(factory.polymarketToken()).balanceOf(sender, info.polymarketTokenId));
        console.log("Wallet OPINION after:     ", IERC1155(factory.opinionToken()).balanceOf(sender, info.opinionTokenId));
    }
}
