// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PoolFactory.sol";

/**
 * @title CreatePool
 * @notice Creates a new SwapPool + two LPToken contracts for a matched event-outcome.
 *
 *         Each pool has two LP tokens:
 *           polyLpToken    — minted when depositing Polymarket shares
 *           opinionLpToken — minted when depositing WrappedOpinion shares
 *         Both share the same unified exchange rate.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY    — must be the factory owner
 *   POOL_FACTORY_ADDRESS    — deployed PoolFactory address
 *   POLY_TOKEN_ID           — Polymarket ERC-1155 token ID for this event
 *   OPINION_TOKEN_ID        — WrappedOpinion ERC-1155 token ID for this event
 *   POLY_LP_NAME            — ERC-20 name for Poly LP    e.g. "PredictSwap BTC-YES PolyLP"
 *   POLY_LP_SYMBOL          — ERC-20 symbol              e.g. "PS-BTC-YES-POLY"
 *   OPINION_LP_NAME         — ERC-20 name for Opinion LP e.g. "PredictSwap BTC-YES OpinionLP"
 *   OPINION_LP_SYMBOL       — ERC-20 symbol              e.g. "PS-BTC-YES-OP"
 *
 * Run:
 *   forge script script/CreatePool.s.sol --rpc-url polygon --broadcast
 */
contract CreatePool is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factoryAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 polyId = vm.envUint("POLY_TOKEN_ID");
        uint256 opinionId = vm.envUint("OPINION_TOKEN_ID");
        string memory polyLpName = vm.envString("POLY_LP_NAME");
        string memory polyLpSym  = vm.envString("POLY_LP_SYMBOL");
        string memory opinionLpName = vm.envString("OPINION_LP_NAME");
        string memory opinionLpSym  = vm.envString("OPINION_LP_SYMBOL");

        PoolFactory factory = PoolFactory(factoryAddr);

        console.log("=== CreatePool ===");
        console.log("Factory:           ", factoryAddr);
        console.log("Poly token ID:     ", polyId);
        console.log("Opinion token ID:  ", opinionId);
        console.log("Poly LP name:      ", polyLpName);
        console.log("Poly LP symbol:    ", polyLpSym);
        console.log("Opinion LP name:   ", opinionLpName);
        console.log("Opinion LP symbol: ", opinionLpSym);
        console.log("");

        vm.startBroadcast(ownerKey);

        uint256 poolId = factory.createPool(
            polyId,
            opinionId,
            polyLpName,
            polyLpSym,
            opinionLpName,
            opinionLpSym
        );

        vm.stopBroadcast();

        PoolFactory.PoolInfo memory info = factory.getPool(poolId);

        console.log("=== Pool created ===");
        console.log("Pool ID:          ", poolId);
        console.log("SwapPool:         ", info.swapPool);
        console.log("Poly LP token:    ", info.polyLpToken);
        console.log("Opinion LP token: ", info.opinionLpToken);
    }
}