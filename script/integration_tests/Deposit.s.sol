// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../src/SwapPool.sol";
import "../../src/PoolFactory.sol";
import "../../src/LPToken.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title Deposit
 * @notice Deposits ERC-1155 shares into a SwapPool and receives the matching LP token.
 *
 *         Depositing marketA shares → mints on factory.marketALpToken() under
 *                                      info.marketALpTokenId (== marketA.tokenId).
 *         Depositing marketB shares → symmetric on the B side.
 *
 *         Per-side rate = sideValue * 1e18 / sideSupply. Starts at 1e18,
 *         grows from fees attributed to that side.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY   — wallet holding the ERC-1155 shares
 *   POOL_FACTORY_ADDRESS   — deployed PoolFactory address
 *   POOL_ID                — pool index (0-based, from factory registry)
 *   DEPOSIT_SIDE           — "0" for MARKET_A, "1" for MARKET_B
 *   DEPOSIT_AMOUNT         — number of raw shares to deposit (native token decimals)
 *
 * Run:
 *   forge script script/integration_tests/Deposit.s.sol --rpc-url polygon --broadcast
 */
contract Deposit is Script {
    function run() external {
        uint256 key      = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId   = vm.envUint("POOL_ID");
        uint256 sideRaw  = vm.envUint("DEPOSIT_SIDE");
        uint256 amount   = vm.envUint("DEPOSIT_AMOUNT");
        address sender   = vm.addr(key);

        PoolFactory factory = PoolFactory(factAddr);
        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool = SwapPool(payable(info.swapPool));
        SwapPool.Side side = SwapPool.Side(sideRaw);

        // Resolve LP contract + tokenId + market contract for the chosen side.
        LPToken lp         = side == SwapPool.Side.MARKET_A ? factory.marketALpToken() : factory.marketBLpToken();
        uint256 lpTokenId  = side == SwapPool.Side.MARKET_A ? info.marketALpTokenId     : info.marketBLpTokenId;
        address tokenAddr  = side == SwapPool.Side.MARKET_A ? factory.marketAContract() : factory.marketBContract();
        uint256 marketTid  = side == SwapPool.Side.MARKET_A ? pool.marketATokenId()     : pool.marketBTokenId();
        string memory mktName = side == SwapPool.Side.MARKET_A ? factory.marketAName() : factory.marketBName();

        uint256 tokenBalance = IERC1155(tokenAddr).balanceOf(sender, marketTid);
        uint256 lpBefore     = lp.balanceOf(sender, lpTokenId);
        uint256 rateBefore   = side == SwapPool.Side.MARKET_A ? pool.marketARate() : pool.marketBRate();

        console.log("=== Deposit ===");
        console.log("Pool ID:           ", poolId);
        console.log("SwapPool:          ", info.swapPool);
        console.log("Side:              ", sideRaw == 0 ? "MARKET_A" : "MARKET_B");
        console.log("Market name:       ", mktName);
        console.log("Market contract:   ", tokenAddr);
        console.log("Market tokenId:    ", marketTid);
        console.log("LP contract:       ", address(lp));
        console.log("LP tokenId:        ", lpTokenId);
        console.log("Wallet balance:    ", tokenBalance);
        console.log("Deposit amount:    ", amount);
        console.log("LP before:         ", lpBefore);
        console.log("Side rate before:  ", rateBefore);
        console.log("Side LP supply:    ", lp.totalSupply(lpTokenId));
        console.log("");

        require(tokenBalance >= amount, "Insufficient token balance");

        vm.startBroadcast(key);

        if (!IERC1155(tokenAddr).isApprovedForAll(sender, info.swapPool)) {
            IERC1155(tokenAddr).setApprovalForAll(info.swapPool, true);
            console.log("Approved SwapPool to transfer tokens");
        }

        uint256 lpMinted = pool.deposit(side, amount);

        vm.stopBroadcast();

        uint256 rateAfter = side == SwapPool.Side.MARKET_A ? pool.marketARate() : pool.marketBRate();

        console.log("=== Done ===");
        console.log("LP minted:         ", lpMinted);
        console.log("LP after:          ", lp.balanceOf(sender, lpTokenId));
        console.log("aSideValue:        ", pool.aSideValue());
        console.log("bSideValue:        ", pool.bSideValue());
        console.log("Side LP supply:    ", lp.totalSupply(lpTokenId));
        console.log("Side rate after:   ", rateAfter);
    }
}
