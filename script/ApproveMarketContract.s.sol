// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PoolFactory.sol";

/**
 * @title ApproveMarketContract
 * @notice Approves an ERC-1155 prediction market contract for use in pools.
 *         Must be called before createPool() for any new market contract.
 *         Caller must be the factory owner.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY      — must be factory owner
 *   POOL_FACTORY_ADDRESS      — deployed PoolFactory address
 *   MARKET_CONTRACT           — ERC-1155 market contract address to approve
 *
 * Run:
 *   forge script script/ApproveMarketContract.s.sol --rpc-url polygon --broadcast
 */
contract ApproveMarketContract is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factoryAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        address marketContract_1 = vm.envAddress("POLYMARKET_TOKEN_ADDRESS");
        address marketContract_2 = vm.envAddress("OPINION_TOKEN_ADDRESS");

        PoolFactory factory = PoolFactory(factoryAddr);

        console.log("=== ApproveMarketContract ===");
        console.log("Factory:         ", factoryAddr);
        console.log("Market contract: ", marketContract_1);
        console.log("Market contract: ", marketContract_2);
        console.log("");

        vm.startBroadcast(deployerKey);
        factory.approveMarketContract(marketContract_1);
        factory.approveMarketContract(marketContract_2);
        vm.stopBroadcast();

        console.log("=== Approved ===");
        console.log("Market contract approved: ", marketContract_1);
        console.log("Market contract approved: ", marketContract_2);
    }
}