// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PoolFactory.sol";
import "../src/SwapPool.sol";

/**
 * @title SetPoolFees
 * @notice Updates the swap fee config for a specific pool.
 *         Changes take effect immediately for that pool only.
 *         Caller must be the factory owner.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY  — must be the factory owner
 *   POOL_FACTORY_ADDRESS  — deployed PoolFactory address
 *   POOL_ID               — zero-indexed pool ID to update
 *   LP_FEE_BPS            — new LP fee in basis points       (max 100 = 1.00%)
 *   PROTOCOL_FEE_BPS      — new protocol fee in basis points (max  50 = 0.50%)
 *
 * Run:
 *   forge script script/SetPoolFees.s.sol --rpc-url polygon --broadcast
 */
contract SetPoolFees is Script {
    function run() external {
        uint256 ownerKey    = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factoryAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId      = vm.envUint("POOL_ID");
        uint256 lpFee       = vm.envUint("LP_FEE_BPS");
        uint256 protocolFee = vm.envUint("PROTOCOL_FEE_BPS");

        PoolFactory factory = PoolFactory(factoryAddr);

        // Read current pool state for pre-flight logging
        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool = SwapPool(payable(info.swapPool));

        console.log("=== SetPoolFees ===");
        console.log("Factory:              ", factoryAddr);
        console.log("Pool ID:              ", poolId);
        console.log("SwapPool:             ", info.swapPool);
        console.log("Market A:             ", factory.marketAName());
        console.log("Market B:             ", factory.marketBName());
        console.log("Market A tokenId:     ", info.marketA.tokenId);
        console.log("Market B tokenId:     ", info.marketB.tokenId);
        console.log("Current LP fee:       ", pool.lpFeeBps(), "bps");
        console.log("Current protocol fee: ", pool.protocolFeeBps(), "bps");
        console.log("New LP fee:           ", lpFee, "bps");
        console.log("New protocol fee:     ", protocolFee, "bps");
        console.log("");

        vm.startBroadcast(ownerKey);
        factory.setPoolFees(poolId, lpFee, protocolFee);
        vm.stopBroadcast();

        console.log("Done. Total fee: ", lpFee + protocolFee, "bps");
    }
}