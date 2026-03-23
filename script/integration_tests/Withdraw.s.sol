// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../src/SwapPool.sol";
import "../../src/PoolFactory.sol";
import "../../src/LPToken.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title Withdraw
 * @notice Burns LP tokens and withdraws underlying shares from a SwapPool.
 *
 * ─── Two-LP withdrawal rules ──────────────────────────────────────────────────
 *
 *   WITHDRAW_LP_SIDE   — which LP token to burn (must match what you deposited)
 *   WITHDRAW_RECV_SIDE — which ERC-1155 token to receive
 *
 *   Same-side  (LP_SIDE == RECV_SIDE): free, instant, no fee.
 *   Cross-side (LP_SIDE != RECV_SIDE): swap fee deducted from sharesOut,
 *               unless the pool is resolved (fee-free after market settlement).
 *
 * ─── Amount ───────────────────────────────────────────────────────────────────
 *
 *   Set WITHDRAW_LP_AMOUNT=0 to burn your entire balance of the chosen LP token.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY   — wallet holding LP tokens
 *   POOL_FACTORY_ADDRESS   — deployed PoolFactory address
 *   POOL_ID                — pool index (0-based)
 *   WITHDRAW_LP_AMOUNT     — LP tokens to burn (0 = withdraw all of that LP type)
 *   WITHDRAW_LP_SIDE       — LP token to burn: "0" = polyLpToken, "1" = opinionLpToken
 *   WITHDRAW_RECV_SIDE     — shares to receive: "0" = POLYMARKET, "1" = OPINION
 *
 * Run:
 *   forge script script/integration_tests/Withdraw.s.sol --rpc-url polygon --broadcast
 */
contract Withdraw is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId = vm.envUint("POOL_ID");
        uint256 lpAmount = vm.envUint("WITHDRAW_LP_AMOUNT");
        uint256 lpSideRaw = vm.envUint("WITHDRAW_LP_SIDE");
        uint256 recvSideRaw = vm.envUint("WITHDRAW_RECV_SIDE");

        address sender = vm.addr(key);
        PoolFactory factory = PoolFactory(factAddr);

        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool = SwapPool(payable(info.swapPool));

        SwapPool.Side lpSide   = SwapPool.Side(lpSideRaw);
        SwapPool.Side recvSide = SwapPool.Side(recvSideRaw);
        bool isCrossSide = lpSideRaw != recvSideRaw;

        // Resolve LP token for the burn side
        address lpAddr = lpSide == SwapPool.Side.POLYMARKET ? info.polyLpToken : info.opinionLpToken;
        LPToken lp = LPToken(lpAddr);

        uint256 lpBalance = lp.balanceOf(sender);

        // 0 means "withdraw everything"
        if (lpAmount == 0) lpAmount = lpBalance;

        // Calculate expected gross shares out for display
        uint256 totalLpSupply = pool.totalLpSupply();
        uint256 grossOut = totalLpSupply > 0 ? (lpAmount * pool.totalShares()) / totalLpSupply : 0;

        // Estimate net out after fee for cross-side (display only)
        uint256 totalFeeBps = factory.lpFeeBps() + factory.protocolFeeBps();
        uint256 estimatedNet = (isCrossSide && !pool.resolved())
            ? grossOut - (grossOut * totalFeeBps / factory.FEE_DENOMINATOR())
            : grossOut;

        uint256 polyBal   = IERC1155(factory.polymarketToken()).balanceOf(sender, info.polymarketTokenId);
        uint256 opinionBal = IERC1155(factory.opinionToken()).balanceOf(sender, info.opinionTokenId);

        console.log("=== Withdraw ===");
        console.log("Pool ID:             ", poolId);
        console.log("SwapPool:            ", info.swapPool);
        console.log("LP token burned:     ", lpAddr);
        console.log("LP side:             ", lpSideRaw   == 0 ? "POLYMARKET" : "OPINION");
        console.log("Receive side:        ", recvSideRaw == 0 ? "POLYMARKET" : "OPINION");
        console.log("Cross-side:          ", isCrossSide ? "YES (fee applies)" : "NO (free)");
        console.log("Pool resolved:       ", pool.resolved() ? "YES (cross-side free)" : "NO");
        console.log("LP balance:          ", lpBalance);
        console.log("LP to burn:          ", lpAmount);
        console.log("Gross shares out:    ", grossOut);
        console.log("Est. net shares out: ", estimatedNet);
        console.log("Pool POLY bal:       ", pool.polymarketBalance());
        console.log("Pool OPINION bal:    ", pool.opinionBalance());
        console.log("Exchange rate:       ", pool.exchangeRate());
        console.log("Total LP supply:     ", totalLpSupply);
        console.log("Wallet POLY:         ", polyBal);
        console.log("Wallet OPINION:      ", opinionBal);
        console.log("");

        require(lpBalance >= lpAmount, "Insufficient LP balance");
        require(lpAmount > 0, "Nothing to withdraw");

        vm.startBroadcast(key);

        pool.withdrawSingleSide(lpAmount, lpSide, recvSide);

        vm.stopBroadcast();

        console.log("=== Done ===");
        console.log("LP remaining:         ", lp.balanceOf(sender));
        console.log("Wallet POLY after:    ", IERC1155(factory.polymarketToken()).balanceOf(sender, info.polymarketTokenId));
        console.log("Wallet OPINION after: ", IERC1155(factory.opinionToken()).balanceOf(sender, info.opinionTokenId));
    }
}