// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../src/SwapPool.sol";
import "../../src/PoolFactory.sol";
import "../../src/LPToken.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title WithdrawSingleSide
 * @notice Burns LP tokens and receives shares on one side only.
 *
 * ─── Same-side vs Cross-side ──────────────────────────────────────────────────
 *
 *   Same-side  (LP_SIDE == RECV_SIDE): free, no fee.
 *   Cross-side (LP_SIDE != RECV_SIDE): swap fee deducted from gross shares out,
 *               unless the pool is marked resolved (fee-free after settlement).
 *
 *   Cross-side withdrawals are blocked when swapsPaused = true.
 *   Same-side withdrawals are never blocked.
 *
 * ─── Amount ───────────────────────────────────────────────────────────────────
 *
 *   Set WITHDRAW_LP_AMOUNT=0 to burn your entire balance of the chosen LP token.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY   — wallet holding LP tokens
 *   POOL_FACTORY_ADDRESS   — deployed PoolFactory address
 *   POOL_ID                — pool index (0-based)
 *   WITHDRAW_LP_AMOUNT     — LP tokens to burn (0 = withdraw all)
 *   WITHDRAW_LP_SIDE       — LP token to burn: 0 = polyLpToken, 1 = opinionLpToken
 *   WITHDRAW_RECV_SIDE     — shares to receive: 0 = POLYMARKET, 1 = OPINION
 *
 * Run:
 *   forge script script/integration_tests/WithdrawSingleSide.s.sol --rpc-url polygon --broadcast
 */
contract WithdrawSingleSide is Script {
    function run() external {
        uint256 key          = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr     = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId       = vm.envUint("POOL_ID");
        uint256 lpAmount     = vm.envUint("WITHDRAW_LP_AMOUNT");
        uint256 lpSideRaw    = vm.envUint("WITHDRAW_LP_SIDE");
        uint256 recvSideRaw  = vm.envUint("WITHDRAW_RECV_SIDE");

        address sender = vm.addr(key);
        PoolFactory factory  = PoolFactory(factAddr);
        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool        = SwapPool(payable(info.swapPool));

        SwapPool.Side lpSide   = SwapPool.Side(lpSideRaw);
        SwapPool.Side recvSide = SwapPool.Side(recvSideRaw);
        bool isCross           = lpSideRaw != recvSideRaw;

        address lpAddr = lpSide == SwapPool.Side.POLYMARKET ? info.polyLpToken : info.opinionLpToken;
        LPToken lp     = LPToken(lpAddr);
        uint256 lpBal  = lp.balanceOf(sender);

        if (lpAmount == 0) lpAmount = lpBal;

        uint256 supply   = pool.totalLpSupply();
        uint256 grossOut = supply > 0 ? (lpAmount * pool.totalShares()) / supply : 0;

        // Fee estimate (display only — uses floor division like old code intentionally for estimate)
        uint256 totalFeeBps = factory.lpFeeBps() + factory.protocolFeeBps();
        uint256 feeEstimate = (isCross && !pool.resolved())
            ? (grossOut * totalFeeBps + factory.FEE_DENOMINATOR() - 1) / factory.FEE_DENOMINATOR()
            : 0;
        uint256 netEstimate = grossOut - feeEstimate;

        console.log("=== WithdrawSingleSide ===");
        console.log("Pool ID:             ", poolId);
        console.log("SwapPool:            ", info.swapPool);
        console.log("LP token:            ", lpAddr);
        console.log("LP side:             ", lpSideRaw   == 0 ? "POLYMARKET" : "OPINION");
        console.log("Receive side:        ", recvSideRaw == 0 ? "POLYMARKET" : "OPINION");
        console.log("Cross-side:          ", isCross ? "YES" : "NO");
        console.log("Pool resolved:       ", pool.resolved() ? "YES (cross-side free)" : "NO");
        console.log("Pool swapsPaused:    ", pool.swapsPaused() ? "YES" : "NO");
        console.log("LP balance:          ", lpBal);
        console.log("LP to burn:          ", lpAmount);
        console.log("Gross shares out:    ", grossOut);
        console.log("Fee estimate:        ", feeEstimate);
        console.log("Net shares estimate: ", netEstimate);
        console.log("Pool POLY bal:       ", pool.polymarketBalance());
        console.log("Pool OPINION bal:    ", pool.opinionBalance());
        console.log("Exchange rate:       ", pool.exchangeRate());
        console.log("Total LP supply:     ", supply);
        console.log("Wallet POLY:         ", IERC1155(factory.polymarketToken()).balanceOf(sender, info.polymarketTokenId));
        console.log("Wallet OPINION:      ", IERC1155(factory.opinionToken()).balanceOf(sender, info.opinionTokenId));
        console.log("");

        require(lpBal >= lpAmount, "Insufficient LP balance");
        require(lpAmount > 0, "Nothing to withdraw");
        if (isCross) require(!pool.swapsPaused(), "Swaps are paused. cross-side blocked");

        vm.startBroadcast(key);
        uint256 received = pool.withdrawSingleSide(lpAmount, lpSide, recvSide);
        vm.stopBroadcast();

        console.log("=== Done ===");
        console.log("Shares received:      ", received);
        console.log("LP remaining:         ", lp.balanceOf(sender));
        console.log("Wallet POLY after:    ", IERC1155(factory.polymarketToken()).balanceOf(sender, info.polymarketTokenId));
        console.log("Wallet OPINION after: ", IERC1155(factory.opinionToken()).balanceOf(sender, info.opinionTokenId));
    }
}
