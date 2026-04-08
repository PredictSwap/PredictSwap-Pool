// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PoolFactory.sol";

/**
 * @title CreatePool
 * @notice Creates a new SwapPool + two LPToken contracts for a matched event-outcome.
 *
 *         Each pool has two LP tokens:
 *           marketALpToken — minted when depositing marketA shares
 *           marketBLpToken — minted when depositing marketB shares
 *         Both share the same unified exchange rate.
 *
 *         Both market contracts must be pre-approved on the factory via
 *         approveMarketContract() before this script is run.
 *
 *         Caller must be the factory operator or owner.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY      — must be factory operator or owner
 *   POOL_FACTORY_ADDRESS      — deployed PoolFactory address
 *
 *   MARKET_A_CONTRACT         — ERC-1155 prediction market contract address (e.g. Polymarket)
 *   MARKET_A_TOKEN_ID         — outcome/event ID within that contract
 *   MARKET_A_DECIMALS         — decimal precision of the shares
 *   MARKET_A_NAME             — human-readable platform name, e.g. "Polymarket"
 *
 *   MARKET_B_CONTRACT         — ERC-1155 prediction market contract address (e.g. Opinion)
 *   MARKET_B_TOKEN_ID         — outcome/event ID within that contract
 *   MARKET_B_DECIMALS         — decimal precision of the shares
 *   MARKET_B_NAME             — human-readable platform name, e.g. "Opinion"
 *
 *   LP_FEE_BPS                — LP fee in basis points, e.g. 30 = 0.30%
 *   PROTOCOL_FEE_BPS          — Protocol fee in basis points, e.g. 10 = 0.10%
 *
 *   MARKET_A_LP_NAME          — ERC-20 name for marketA LP, e.g. "PredictSwap BTC-YES PolyLP"
 *   MARKET_A_LP_SYMBOL        — ERC-20 symbol,              e.g. "PS-BTC-YES-POLY"
 *   MARKET_B_LP_NAME          — ERC-20 name for marketB LP, e.g. "PredictSwap BTC-YES OpinionLP"
 *   MARKET_B_LP_SYMBOL        — ERC-20 symbol,              e.g. "PS-BTC-YES-OPN"
 *
 * Run:
 *   forge script script/CreatePool.s.sol --rpc-url polygon --broadcast
 */
contract CreatePool is Script {
    function run() external {
        uint256 deployerKey  = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factoryAddr  = vm.envAddress("POOL_FACTORY_ADDRESS");

        // Market A config
        address marketAContract = vm.envAddress("MARKET_A_CONTRACT");
        uint256 marketATokenId  = vm.envUint("MARKET_A_TOKEN_ID");
        uint8   marketADecimals = uint8(vm.envUint("MARKET_A_DECIMALS"));
        string memory marketAName = vm.envString("MARKET_A_NAME");

        // Market B config
        address marketBContract = vm.envAddress("MARKET_B_CONTRACT");
        uint256 marketBTokenId  = vm.envUint("MARKET_B_TOKEN_ID");
        uint8   marketBDecimals = uint8(vm.envUint("MARKET_B_DECIMALS"));
        string memory marketBName = vm.envString("MARKET_B_NAME");

        // Fees
        uint256 lpFeeBps       = vm.envUint("LP_FEE_BPS");
        uint256 protocolFeeBps = vm.envUint("PROTOCOL_FEE_BPS");

        // LP token metadata
        string memory marketALpName   = vm.envString("MARKET_A_LP_NAME");
        string memory marketALpSymbol = vm.envString("MARKET_A_LP_SYMBOL");
        string memory marketBLpName   = vm.envString("MARKET_B_LP_NAME");
        string memory marketBLpSymbol = vm.envString("MARKET_B_LP_SYMBOL");

        PoolFactory factory = PoolFactory(factoryAddr);

        console.log("=== CreatePool ===");
        console.log("Factory:                ", factoryAddr);
        console.log("Market A contract:      ", marketAContract);
        console.log("Market A token ID:      ", marketATokenId);
        console.log("Market A decimals:      ", marketADecimals);
        console.log("Market A name:          ", marketAName);
        console.log("Market B contract:      ", marketBContract);
        console.log("Market B token ID:      ", marketBTokenId);
        console.log("Market B decimals:      ", marketBDecimals);
        console.log("Market B name:          ", marketBName);
        console.log("LP fee bps:             ", lpFeeBps);
        console.log("Protocol fee bps:       ", protocolFeeBps);
        console.log("Market A LP name:       ", marketALpName);
        console.log("Market A LP symbol:     ", marketALpSymbol);
        console.log("Market B LP name:       ", marketBLpName);
        console.log("Market B LP symbol:     ", marketBLpSymbol);
        console.log("");

        PoolFactory.MarketConfig memory marketA = PoolFactory.MarketConfig({
            marketContract: marketAContract,
            tokenId:        marketATokenId,
            decimals:       marketADecimals,
            name:           marketAName
        });

        PoolFactory.MarketConfig memory marketB = PoolFactory.MarketConfig({
            marketContract: marketBContract,
            tokenId:        marketBTokenId,
            decimals:       marketBDecimals,
            name:           marketBName
        });

        vm.startBroadcast(deployerKey);

        uint256 poolId = factory.createPool(
            marketA,
            marketB,
            lpFeeBps,
            protocolFeeBps,
            marketALpName,
            marketALpSymbol,
            marketBLpName,
            marketBLpSymbol
        );

        vm.stopBroadcast();

        PoolFactory.PoolInfo memory info = factory.getPool(poolId);

        console.log("=== Pool created ===");
        console.log("Pool ID:               ", poolId);
        console.log("SwapPool:              ", info.swapPool);
        console.log("Market A LP token:     ", info.marketALpToken);
        console.log("Market B LP token:     ", info.marketBLpToken);
    }
}