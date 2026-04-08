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
 *   WITHDRAW_LP_SIDE       — LP token to burn: 0 = marketALpToken, 1 = marketBLpToken
 *   WITHDRAW_RECV_SIDE     — shares to receive: 0 = MARKET_A, 1 = MARKET_B
 *
 * Run:
 *   forge script script/integration_tests/WithdrawSingleSide.s.sol --rpc-url polygon --broadcast
 */
contract WithdrawSingleSide is Script {
    function run() external {
        uint256 key         = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr    = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId      = vm.envUint("POOL_ID");
        uint256 lpAmount    = vm.envUint("WITHDRAW_LP_AMOUNT");
        uint256 lpSideRaw   = vm.envUint("WITHDRAW_LP_SIDE");
        uint256 recvSideRaw = vm.envUint("WITHDRAW_RECV_SIDE");

        address sender = vm.addr(key);
        PoolFactory factory = PoolFactory(factAddr);
        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool = SwapPool(payable(info.swapPool));

        SwapPool.Side lpSide   = SwapPool.Side(lpSideRaw);
        SwapPool.Side recvSide = SwapPool.Side(recvSideRaw);
        bool isCross           = lpSideRaw != recvSideRaw;

        // Resolve LP token, market contracts and token IDs from pool
        address lpAddr          = lpSide == SwapPool.Side.MARKET_A ? info.marketALpToken  : info.marketBLpToken;
        address marketAContract = pool.marketAContract();
        address marketBContract = pool.marketBContract();
        uint256 marketATokenId  = pool.marketATokenId();
        uint256 marketBTokenId  = pool.marketBTokenId();

        string memory lpSideName   = lpSideRaw   == 0 ? info.marketA.name : info.marketB.name;
        string memory recvSideName = recvSideRaw  == 0 ? info.marketA.name : info.marketB.name;

        LPToken lp    = LPToken(lpAddr);
        uint256 lpBal = lp.balanceOf(sender);

        if (lpAmount == 0) lpAmount = lpBal;

        uint256 supply   = pool.totalLpSupply();

        // Gross estimate in normalized space
        uint256 grossOut = supply > 0 ? (lpAmount * pool.totalSharesNorm()) / supply : 0;

        // Fee estimate on cross-side only — read from pool
        uint256 totalFeeBps = pool.lpFeeBps() + pool.protocolFeeBps();
        uint256 feeEstimate = (isCross && !pool.resolved())
            ? (grossOut * totalFeeBps + pool.FEE_DENOMINATOR() - 1) / pool.FEE_DENOMINATOR()
            : 0;
        uint256 netEstimate = grossOut - feeEstimate;

        console.log("=== WithdrawSingleSide ===");
        console.log("Pool ID:              ", poolId);
        console.log("SwapPool:             ", info.swapPool);
        console.log("LP token:             ", lpAddr);
        console.log("LP side:              ", lpSideRaw   == 0 ? "MARKET_A" : "MARKET_B");
        console.log("LP market:            ", lpSideName);
        console.log("Receive side:         ", recvSideRaw == 0 ? "MARKET_A" : "MARKET_B");
        console.log("Receive market:       ", recvSideName);
        console.log("Cross-side:           ", isCross ? "YES" : "NO");
        console.log("Pool resolved:        ", pool.resolved() ? "YES (cross-side free)" : "NO");
        console.log("Pool swapsPaused:     ", pool.swapsPaused() ? "YES" : "NO");
        console.log("LP balance:           ", lpBal);
        console.log("LP to burn:           ", lpAmount);
        console.log("Gross out (norm):     ", grossOut);
        console.log("Fee estimate (norm):  ", feeEstimate);
        console.log("Net estimate (norm):  ", netEstimate);
        console.log("Pool MARKET_A bal:    ", pool.marketABalance());
        console.log("Pool MARKET_B bal:    ", pool.marketBBalance());
        console.log("Exchange rate:        ", pool.exchangeRate());
        console.log("Total LP supply:      ", supply);
        console.log("Wallet MARKET_A:      ", IERC1155(marketAContract).balanceOf(sender, marketATokenId));
        console.log("Wallet MARKET_B:      ", IERC1155(marketBContract).balanceOf(sender, marketBTokenId));
        console.log("");

        require(lpBal >= lpAmount, "Insufficient LP balance");
        require(lpAmount > 0,      "Nothing to withdraw");
        if (isCross) require(!pool.swapsPaused(), "Swaps are paused, cross-side blocked");

        vm.startBroadcast(key);
        uint256 received = pool.withdrawSingleSide(lpAmount, lpSide, recvSide);
        vm.stopBroadcast();

        console.log("=== Done ===");
        console.log("Shares received:       ", received);
        console.log("LP remaining:          ", lp.balanceOf(sender));
        console.log("Wallet MARKET_A after: ", IERC1155(marketAContract).balanceOf(sender, marketATokenId));
        console.log("Wallet MARKET_B after: ", IERC1155(marketBContract).balanceOf(sender, marketBTokenId));
    }
}