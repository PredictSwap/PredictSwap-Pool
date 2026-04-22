// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../src/SwapPool.sol";
import "../../src/PoolFactory.sol";
import "../../src/LPToken.sol";

/**
 * @title Withdraw
 * @notice Unified withdrawal script for PredictSwap v3.
 *
 *         Two paths, picked automatically by the pool's swapsPaused flag:
 *
 *           swapsPaused == false → pool.withdrawal(receiveSide, lpAmount, lpSide)
 *             - Same-side (receiveSide == lpSide): no fee, except the JIT fee on
 *               the *fresh* portion of the burn when !resolved.
 *             - Cross-side (receiveSide != lpSide): full 0.4% fee on claim when
 *               !resolved; free when resolved. Fee is credited to receiveSide.
 *             - Reverts InsufficientLiquidity if physical(receiveSide) < outflow.
 *
 *           swapsPaused == true  → pool.withdrawProRata(lpAmount, lpSide)
 *             - Proportional share of native reserves, cross remainder. Never fees.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY   — wallet holding the LP tokens
 *   POOL_FACTORY_ADDRESS   — deployed PoolFactory address
 *   POOL_ID                — pool index (0-based)
 *   LP_SIDE                — "0" for MARKET_A-LP, "1" for MARKET_B-LP
 *   RECEIVE_SIDE           — "0" for MARKET_A, "1" for MARKET_B
 *                              (ignored when swaps are paused — pro-rata splits both)
 *   LP_AMOUNT              — LP tokens to burn (0 = full balance)
 *
 * Run:
 *   forge script script/integration_tests/Withdraw.s.sol --rpc-url polygon --broadcast
 */
contract Withdraw is Script {
    function run() external {
        uint256 key      = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId   = vm.envUint("POOL_ID");
        uint256 lpSideRaw  = vm.envUint("LP_SIDE");
        uint256 recvSideRaw = vm.envUint("RECEIVE_SIDE");
        uint256 lpAmount = vm.envUint("LP_AMOUNT");
        address sender   = vm.addr(key);

        PoolFactory factory = PoolFactory(factAddr);
        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool = SwapPool(payable(info.swapPool));
        SwapPool.Side lpSide      = SwapPool.Side(lpSideRaw);
        SwapPool.Side receiveSide = SwapPool.Side(recvSideRaw);

        LPToken lp        = lpSide == SwapPool.Side.MARKET_A ? factory.marketALpToken() : factory.marketBLpToken();
        uint256 lpTokenId = lpSide == SwapPool.Side.MARKET_A ? info.marketALpTokenId     : info.marketBLpTokenId;
        uint256 lpBal     = lp.balanceOf(sender, lpTokenId);

        if (lpAmount == 0) lpAmount = lpBal;
        require(lpBal >= lpAmount, "Insufficient LP balance");

        console.log("=== Withdraw ===");
        console.log("Pool ID:             ", poolId);
        console.log("SwapPool:            ", info.swapPool);
        console.log("LP side:             ", lpSideRaw == 0 ? "MARKET_A" : "MARKET_B");
        console.log("LP tokenId:          ", lpTokenId);
        console.log("LP wallet balance:   ", lpBal);
        console.log("LP burn amount:      ", lpAmount);
        console.log("Pool resolved:       ", pool.resolved() ? "YES" : "NO");
        console.log("Swaps paused:        ", pool.swapsPaused() ? "YES" : "NO");
        console.log("aSideValue:          ", pool.aSideValue());
        console.log("bSideValue:          ", pool.bSideValue());
        console.log("Physical A (norm):   ", pool.physicalBalanceNorm(SwapPool.Side.MARKET_A));
        console.log("Physical B (norm):   ", pool.physicalBalanceNorm(SwapPool.Side.MARKET_B));
        console.log("Locked LP (fresh):   ", lp.lockedAmount(sender, lpTokenId));
        console.log("");

        vm.startBroadcast(key);

        if (pool.swapsPaused()) {
            console.log("Swaps are paused -> using withdrawProRata (no fee, proportional split)");
            (uint256 nativeOut, uint256 crossOut) = pool.withdrawProRata(lpAmount, lpSide);
            console.log("Native out:        ", nativeOut);
            console.log("Cross  out:        ", crossOut);
        } else {
            console.log("Swaps active -> using withdrawal");
            console.log("Receive side:      ", recvSideRaw == 0 ? "MARKET_A" : "MARKET_B");
            console.log("Kind:              ", lpSide == receiveSide ? "same-side" : "cross-side");
            uint256 received = pool.withdrawal(receiveSide, lpAmount, lpSide);
            console.log("Received:          ", received);
        }

        vm.stopBroadcast();

        console.log("=== Done ===");
        console.log("LP balance after:    ", lp.balanceOf(sender, lpTokenId));
        console.log("aSideValue after:    ", pool.aSideValue());
        console.log("bSideValue after:    ", pool.bSideValue());
    }
}
