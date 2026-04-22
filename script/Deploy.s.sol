// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/FeeCollector.sol";
import "../src/LPToken.sol";
import "../src/PoolFactory.sol";

/**
 * @title Deploy
 * @notice Deploys FeeCollector + PoolFactory for ONE marketA↔marketB project pair.
 *         Each factory is hard-bound to its two ERC-1155 market contracts at deploy;
 *         deploy a second factory for a different project pair.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY  — deployer wallet (pays gas)
 *   OWNER_ADDRESS         — protocol owner/multisig (receives ownership)
 *   OPERATOR_ADDRESS      — operator EOA for day-to-day pool admin
 *
 *   MARKET_A_CONTRACT     — ERC-1155 prediction-market contract for marketA side
 *   MARKET_B_CONTRACT     — ERC-1155 prediction-market contract for marketB side
 *
 *   MARKET_A_NAME         — project name for side A, e.g. "Polymarket"
 *   MARKET_B_NAME         — project name for side B, e.g. "PredictFun"
 *   MARKET_A_LP_NAME      — LP ERC-1155 instance name for side A, e.g. "Polymarket LP"
 *   MARKET_B_LP_NAME      — LP ERC-1155 instance name for side B, e.g. "PredictFun LP"
 *
 * Run (dry-run):
 *   forge script script/Deploy.s.sol --rpc-url polygon
 *
 * Run (broadcast):
 *   forge script script/Deploy.s.sol --rpc-url polygon --broadcast --verify
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner       = vm.envAddress("OWNER_ADDRESS");
        address operator    = vm.envAddress("OPERATOR_ADDRESS");

        address marketAContract = vm.envAddress("MARKET_A_CONTRACT");
        address marketBContract = vm.envAddress("MARKET_B_CONTRACT");

        string memory marketAName   = vm.envString("MARKET_A_NAME");
        string memory marketBName   = vm.envString("MARKET_B_NAME");
        string memory marketALpName = vm.envString("MARKET_A_LP_NAME");
        string memory marketBLpName = vm.envString("MARKET_B_LP_NAME");

        address deployer = vm.addr(deployerKey);

        console.log("=== PredictSwap PoolFactory Deploy ===");
        console.log("Deployer:        ", deployer);
        console.log("Owner:           ", owner);
        console.log("Operator:        ", operator);
        console.log("Market A:        ", marketAContract, marketAName);
        console.log("Market B:        ", marketBContract, marketBName);
        console.log("Market A LP name:", marketALpName);
        console.log("Market B LP name:", marketBLpName);
        console.log("");

        vm.startBroadcast(deployerKey);

        // 1. FeeCollector
        FeeCollector feeCollector = new FeeCollector(owner);
        console.log("FeeCollector:    ", address(feeCollector));

        // 2. PoolFactory (deploys two LPToken instances internally, one per side)
        PoolFactory factory = new PoolFactory(
            marketAContract,
            marketBContract,
            address(feeCollector),
            operator,
            owner,
            marketAName,
            marketBName,
            marketALpName,
            marketBLpName
        );
        console.log("PoolFactory:     ", address(factory));
        console.log("MarketA LP:      ", address(factory.marketALpToken()));
        console.log("MarketB LP:      ", address(factory.marketBLpToken()));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deploy complete ===");
        console.log("Save these addresses to your .env:");
        console.log("  FEE_COLLECTOR_ADDRESS=", address(feeCollector));
        console.log("  POOL_FACTORY_ADDRESS= ", address(factory));
    }
}
