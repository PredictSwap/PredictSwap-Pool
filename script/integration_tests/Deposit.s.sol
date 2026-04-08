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
 *         Depositing marketA shares → receives marketALpToken
 *         Depositing marketB shares → receives marketBLpToken
 *
 *         Both LP tokens share the same unified exchange rate:
 *           rate = totalSharesNorm() / totalLpSupply()
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
        uint256 key     = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId  = vm.envUint("POOL_ID");
        uint256 sideRaw = vm.envUint("DEPOSIT_SIDE");
        uint256 amount  = vm.envUint("DEPOSIT_AMOUNT");
        address sender  = vm.addr(key);

        PoolFactory factory = PoolFactory(factAddr);
        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool = SwapPool(payable(info.swapPool));
        SwapPool.Side side = SwapPool.Side(sideRaw);

        // Resolve LP token, market contract, and token ID for the chosen side
        address lpAddr    = side == SwapPool.Side.MARKET_A ? info.marketALpToken    : info.marketBLpToken;
        address tokenAddr = side == SwapPool.Side.MARKET_A ? pool.marketAContract()   : pool.marketBContract();
        uint256 tokenId   = side == SwapPool.Side.MARKET_A ? pool.marketATokenId()    : pool.marketBTokenId();
        string memory marketName = side == SwapPool.Side.MARKET_A ? info.marketA.name : info.marketB.name;

        LPToken lp = LPToken(lpAddr);

        uint256 tokenBalance = IERC1155(tokenAddr).balanceOf(sender, tokenId);
        uint256 lpBefore     = lp.balanceOf(sender);
        uint256 rateBefore   = pool.exchangeRate();

        console.log("=== Deposit ===");
        console.log("Pool ID:           ", poolId);
        console.log("SwapPool:          ", info.swapPool);
        console.log("Side:              ", sideRaw == 0 ? "MARKET_A" : "MARKET_B");
        console.log("Market name:       ", marketName);
        console.log("Market contract:   ", tokenAddr);
        console.log("Token ID:          ", tokenId);
        console.log("LP token:          ", lpAddr);
        console.log("Wallet balance:    ", tokenBalance);
        console.log("Deposit amount:    ", amount);
        console.log("LP before:         ", lpBefore);
        console.log("Exchange rate:     ", rateBefore);
        console.log("Total LP supply:   ", pool.totalLpSupply());
        console.log("");

        require(tokenBalance >= amount, "Insufficient token balance");

        vm.startBroadcast(key);

        if (!IERC1155(tokenAddr).isApprovedForAll(sender, info.swapPool)) {
            IERC1155(tokenAddr).setApprovalForAll(info.swapPool, true);
            console.log("Approved SwapPool to transfer tokens");
        }

        uint256 lpMinted = pool.deposit(side, amount);

        vm.stopBroadcast();

        console.log("=== Done ===");
        console.log("LP minted:         ", lpMinted);
        console.log("LP after:          ", lp.balanceOf(sender));
        console.log("Pool shares norm:  ", pool.totalSharesNorm());
        console.log("Pool total LP:     ", pool.totalLpSupply());
        console.log("Exchange rate now: ", pool.exchangeRate());
    }
}