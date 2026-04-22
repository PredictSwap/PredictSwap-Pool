// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PoolFactory.sol";

/**
 * @title CreatePool
 * @notice Creates a new SwapPool under an existing PoolFactory for a matched
 *         marketA↔marketB tokenId pair. The factory's two market contracts are
 *         already immutable; this script only needs per-side tokenId + decimals
 *         plus a free-form event-description string for the PoolCreated event.
 *
 *         Caller must be the factory operator or owner. Market tokenIds are
 *         strictly non-reusable across pools on either side within a factory.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY    — must be factory operator or owner
 *   POOL_FACTORY_ADDRESS    — deployed PoolFactory address
 *
 *   MARKET_A_TOKEN_ID       — outcome/event ID on the marketA side
 *   MARKET_A_DECIMALS       — decimal precision of marketA shares (≤18)
 *
 *   MARKET_B_TOKEN_ID       — outcome/event ID on the marketB side
 *   MARKET_B_DECIMALS       — decimal precision of marketB shares (≤18)
 *
 *   LP_FEE_BPS              — LP fee in basis points, e.g. 30 = 0.30%
 *   PROTOCOL_FEE_BPS        — protocol fee in basis points, e.g. 10 = 0.10%
 *
 *   EVENT_DESCRIPTION       — human-readable event label, e.g. "Trump out 2028 - YES"
 *                             Emitted in PoolCreated only; never stored on-chain.
 *
 * Run:
 *   forge script script/CreatePool.s.sol --rpc-url polygon --broadcast
 */
contract CreatePool is Script {
    function run() external {
        uint256 deployerKey  = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factoryAddr  = vm.envAddress("POOL_FACTORY_ADDRESS");

        uint256 marketATokenId  = vm.envUint("MARKET_A_TOKEN_ID");
        uint8   marketADecimals = uint8(vm.envUint("MARKET_A_DECIMALS"));

        uint256 marketBTokenId  = vm.envUint("MARKET_B_TOKEN_ID");
        uint8   marketBDecimals = uint8(vm.envUint("MARKET_B_DECIMALS"));

        uint256 lpFeeBps        = vm.envUint("LP_FEE_BPS");
        uint256 protocolFeeBps  = vm.envUint("PROTOCOL_FEE_BPS");

        string memory eventDescription = vm.envString("EVENT_DESCRIPTION");

        PoolFactory factory = PoolFactory(factoryAddr);

        console.log("=== CreatePool ===");
        console.log("Factory:             ", factoryAddr);
        console.log("Market A:            ", factory.marketAName(), factory.marketAContract());
        console.log("Market A token ID:   ", marketATokenId);
        console.log("Market A decimals:   ", marketADecimals);
        console.log("Market B:            ", factory.marketBName(), factory.marketBContract());
        console.log("Market B token ID:   ", marketBTokenId);
        console.log("Market B decimals:   ", marketBDecimals);
        console.log("LP fee bps:          ", lpFeeBps);
        console.log("Protocol fee bps:    ", protocolFeeBps);
        console.log("Event description:   ", eventDescription);
        console.log("");

        PoolFactory.MarketConfig memory marketA = PoolFactory.MarketConfig({
            tokenId:  marketATokenId,
            decimals: marketADecimals
        });

        PoolFactory.MarketConfig memory marketB = PoolFactory.MarketConfig({
            tokenId:  marketBTokenId,
            decimals: marketBDecimals
        });

        vm.startBroadcast(deployerKey);

        uint256 poolId = factory.createPool(
            marketA,
            marketB,
            lpFeeBps,
            protocolFeeBps,
            eventDescription
        );

        vm.stopBroadcast();

        PoolFactory.PoolInfo memory info = factory.getPool(poolId);

        console.log("=== Pool created ===");
        console.log("Pool ID:             ", poolId);
        console.log("SwapPool:            ", info.swapPool);
        console.log("Market A LP tokenId: ", info.marketALpTokenId);
        console.log("Market B LP tokenId: ", info.marketBLpTokenId);
        console.log("Market A LP contract:", address(factory.marketALpToken()));
        console.log("Market B LP contract:", address(factory.marketBLpToken()));
    }
}
