// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../src/SwapPool.sol";
import "../../src/PoolFactory.sol";
import "../../src/LPToken.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title WithdrawAll
 * @notice Convenience script: burns the caller's full balance of BOTH LP tokens
 *         (polyLpToken and opinionLpToken) in two same-side withdrawals.
 *
 *         Both withdrawals are same-side and therefore always free and never
 *         blocked by swapsPaused.
 *
 *         Useful for a clean full exit without paying cross-side fees:
 *           polyLP  → POLYMARKET shares   (same-side, free)
 *           opinionLP → OPINION shares    (same-side, free)
 *
 *         If one LP balance is zero the corresponding withdrawal is skipped.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY   — wallet holding LP tokens
 *   POOL_FACTORY_ADDRESS   — deployed PoolFactory address
 *   POOL_ID                — pool index (0-based)
 *
 * Run:
 *   forge script script/integration_tests/WithdrawAll.s.sol --rpc-url polygon --broadcast
 */
contract WithdrawAll is Script {
    function run() external {
        uint256 key      = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId   = vm.envUint("POOL_ID");

        address sender = vm.addr(key);
        PoolFactory factory  = PoolFactory(factAddr);
        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool        = SwapPool(payable(info.swapPool));

        LPToken polyLp    = LPToken(info.polyLpToken);
        LPToken opinionLp = LPToken(info.opinionLpToken);

        uint256 polyLpBal    = polyLp.balanceOf(sender);
        uint256 opinionLpBal = opinionLp.balanceOf(sender);

        uint256 supply   = pool.totalLpSupply();
        uint256 polyGross    = (supply > 0 && polyLpBal > 0)
            ? (polyLpBal    * pool.totalShares()) / supply : 0;
        uint256 opinionGross = (supply > 0 && opinionLpBal > 0)
            ? (opinionLpBal * pool.totalShares()) / supply : 0;

        console.log("=== WithdrawAll (same-side, free) ===");
        console.log("Pool ID:              ", poolId);
        console.log("SwapPool:             ", info.swapPool);
        console.log("Pool resolved:        ", pool.resolved() ? "YES" : "NO");
        console.log("Pool depositsPaused:  ", pool.depositsPaused() ? "YES" : "NO");
        console.log("Pool swapsPaused:     ", pool.swapsPaused() ? "YES (no effect on same-side)" : "NO");
        console.log("polyLP balance:       ", polyLpBal);
        console.log("opinionLP balance:    ", opinionLpBal);
        console.log("POLY gross out est:   ", polyGross);
        console.log("OPINION gross out est:", opinionGross);
        console.log("Pool POLY bal:        ", pool.polymarketBalance());
        console.log("Pool OPINION bal:     ", pool.opinionBalance());
        console.log("Exchange rate:        ", pool.exchangeRate());
        console.log("Total LP supply:      ", supply);
        console.log("Wallet POLY:          ", IERC1155(factory.polymarketToken()).balanceOf(sender, info.polymarketTokenId));
        console.log("Wallet OPINION:       ", IERC1155(factory.opinionToken()).balanceOf(sender, info.opinionTokenId));
        console.log("");

        require(polyLpBal > 0 || opinionLpBal > 0, "No LP tokens to withdraw");

        vm.startBroadcast(key);

        uint256 polyReceived;
        uint256 opinionReceived;

        if (polyLpBal > 0) {
            polyReceived = pool.withdrawSingleSide(
                polyLpBal,
                SwapPool.Side.POLYMARKET,
                SwapPool.Side.POLYMARKET
            );
        }

        if (opinionLpBal > 0) {
            opinionReceived = pool.withdrawSingleSide(
                opinionLpBal,
                SwapPool.Side.OPINION,
                SwapPool.Side.OPINION
            );
        }

        vm.stopBroadcast();

        console.log("=== Done ===");
        console.log("POLY received:        ", polyReceived);
        console.log("OPINION received:     ", opinionReceived);
        console.log("polyLP remaining:     ", polyLp.balanceOf(sender));
        console.log("opinionLP remaining:  ", opinionLp.balanceOf(sender));
        console.log("Wallet POLY after:    ", IERC1155(factory.polymarketToken()).balanceOf(sender, info.polymarketTokenId));
        console.log("Wallet OPINION after: ", IERC1155(factory.opinionToken()).balanceOf(sender, info.opinionTokenId));
    }
}
