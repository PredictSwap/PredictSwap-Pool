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
 *   WITHDRAW_LP_SIDE        — LP token to burn: 0 = marketALpToken, 1 = marketBLpToken
 *   WITHDRAW_SAMESIDE_BPS   — same-side fraction in bps (0–10000)
 *
 * Run:
 *   forge script script/integration_tests/WithdrawBothSides.s.sol --rpc-url polygon --broadcast
 */
contract WithdrawBothSides is Script {
    function run() external {
        uint256 key         = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr    = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId      = vm.envUint("POOL_ID");
        uint256 lpAmount    = vm.envUint("WITHDRAW_LP_AMOUNT");
        uint256 lpSideRaw   = vm.envUint("WITHDRAW_LP_SIDE");
        uint256 samesideBps = vm.envUint("WITHDRAW_SAMESIDE_BPS");

        address sender = vm.addr(key);
        PoolFactory factory = PoolFactory(factAddr);
        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool = SwapPool(payable(info.swapPool));

        SwapPool.Side lpSide = SwapPool.Side(lpSideRaw);

        // Resolve LP token, market contracts and token IDs from pool
        address lpAddr          = lpSide == SwapPool.Side.MARKET_A ? info.marketALpToken   : info.marketBLpToken;
        address marketAContract = pool.marketAContract();
        address marketBContract = pool.marketBContract();
        uint256 marketATokenId  = pool.marketATokenId();
        uint256 marketBTokenId  = pool.marketBTokenId();

        LPToken lp    = LPToken(lpAddr);
        uint256 lpBal = lp.balanceOf(sender);

        if (lpAmount == 0) lpAmount = lpBal;

        uint256 denom    = pool.FEE_DENOMINATOR();
        uint256 supply   = pool.totalLpSupply();

        // Gross estimates use normalised shares space
        uint256 grossOut     = supply > 0 ? (lpAmount * pool.totalSharesNorm()) / supply : 0;
        uint256 samesideEst  = (grossOut * samesideBps) / denom;
        uint256 crosssideEst = grossOut - samesideEst;

        // Fee estimate on cross-side portion only — read from pool
        uint256 totalFeeBps = pool.lpFeeBps() + pool.protocolFeeBps();
        uint256 crossFeeEst = (crosssideEst > 0 && !pool.resolved())
            ? (crosssideEst * totalFeeBps + denom - 1) / denom
            : 0;
        uint256 crossNetEst = crosssideEst - crossFeeEst;

        string memory lpSideName    = lpSideRaw == 0 ? "MARKET_A" : "MARKET_B";
        string memory samesideName  = lpSideRaw == 0 ? info.marketA.name : info.marketB.name;
        string memory crosssideName = lpSideRaw == 0 ? info.marketB.name : info.marketA.name;

        console.log("=== WithdrawBothSides ===");
        console.log("Pool ID:                 ", poolId);
        console.log("SwapPool:                ", info.swapPool);
        console.log("LP token:                ", lpAddr);
        console.log("LP side:                 ", lpSideName);
        console.log("Same-side market:        ", samesideName);
        console.log("Cross-side market:       ", crosssideName);
        console.log("samesideBps:             ", samesideBps);
        console.log("Pool resolved:           ", pool.resolved() ? "YES (cross-side free)" : "NO");
        console.log("Pool swapsPaused:        ", pool.swapsPaused() ? "YES" : "NO");
        console.log("LP balance:              ", lpBal);
        console.log("LP to burn:              ", lpAmount);
        console.log("Gross out (norm):        ", grossOut);
        console.log("Same-side estimate:      ", samesideEst);
        console.log("Cross-side gross est:    ", crosssideEst);
        console.log("Cross-side fee est:      ", crossFeeEst);
        console.log("Cross-side net est:      ", crossNetEst);
        console.log("Pool MARKET_A bal:       ", pool.marketABalance());
        console.log("Pool MARKET_B bal:       ", pool.marketBBalance());
        console.log("Exchange rate:           ", pool.exchangeRate());
        console.log("Total LP supply:         ", supply);
        console.log("Wallet MARKET_A:         ", IERC1155(marketAContract).balanceOf(sender, marketATokenId));
        console.log("Wallet MARKET_B:         ", IERC1155(marketBContract).balanceOf(sender, marketBTokenId));
        console.log("");

        require(lpBal >= lpAmount,        "Insufficient LP balance");
        require(lpAmount > 0,             "Nothing to withdraw");
        require(samesideBps <= denom,     "samesideBps exceeds 10000");
        if (crosssideEst > 0) require(!pool.swapsPaused(), "Swaps are paused, cross-side blocked");

        vm.startBroadcast(key);
        (uint256 samesideReceived, uint256 crosssideReceived) =
            pool.withdrawBothSides(lpAmount, lpSide, samesideBps);
        vm.stopBroadcast();

        console.log("=== Done ===");
        console.log("Same-side received:      ", samesideReceived);
        console.log("Cross-side received:     ", crosssideReceived);
        console.log("LP remaining:            ", lp.balanceOf(sender));
        console.log("Wallet MARKET_A after:   ", IERC1155(marketAContract).balanceOf(sender, marketATokenId));
        console.log("Wallet MARKET_B after:   ", IERC1155(marketBContract).balanceOf(sender, marketBTokenId));
    }
}