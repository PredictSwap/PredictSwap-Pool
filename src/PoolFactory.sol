// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./SwapPool.sol";
import "./LPToken.sol";
import "./FeeCollector.sol";

/**
 * @title PoolFactory
 * @notice Team-only factory that deploys SwapPool + LPToken pairs and serves
 *         as the on-chain registry of all active pools.
 *
 *         Both the Polymarket ERC-1155 contract and WrappedOpinionToken contract
 *         are fixed at construction — only token IDs vary per pool.
 *
 *         Swap fees are global and configurable by owner, capped by hard limits.
 *         All pools read fees from here at swap time.
 */
contract PoolFactory is Ownable {

    // ─── Types ────────────────────────────────────────────────────────────────

    struct PoolInfo {
        address swapPool;
        address lpToken;
        uint256 polymarketTokenId;
        uint256 opinionTokenId;
        uint256 resolutionDate;
        bool    isActive;
    }

    // ─── Immutable config ─────────────────────────────────────────────────────

    /// @notice The single Polymarket ERC-1155 contract on Polygon
    address public immutable polymarketToken;
    /// @notice The single WrappedOpinionToken ERC-1155 contract on Polygon
    address public immutable opinionToken;
    /// @notice Protocol fee recipient
    FeeCollector public immutable feeCollector;

    // ─── Configurable fees ────────────────────────────────────────────────────

    uint256 public lpFeeBps       = 30;  // 0.30% default
    uint256 public protocolFeeBps = 10;  // 0.10% default

    uint256 public constant FEE_DENOMINATOR  = 10_000;
    uint256 public constant MAX_LP_FEE       = 100;   // 1.00% hard cap
    uint256 public constant MAX_PROTOCOL_FEE = 50;    // 0.50% hard cap

    // ─── State ────────────────────────────────────────────────────────────────

    PoolInfo[] public pools;

    /// @notice (polymarketTokenId, opinionTokenId) → poolId, 1-indexed; 0 = not found
    mapping(bytes32 => uint256) public poolIndex;

    // ─── Events ───────────────────────────────────────────────────────────────

    event PoolCreated(
        uint256 indexed poolId,
        address swapPool,
        address lpToken,
        uint256 polymarketTokenId,
        uint256 opinionTokenId,
        uint256 resolutionDate
    );
    event PoolDeactivated(uint256 indexed poolId);
    event FeesUpdated(uint256 lpFeeBps, uint256 protocolFeeBps);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error PoolAlreadyExists(bytes32 key);
    error PoolNotFound(uint256 poolId);
    error InvalidAddress();
    error FeeTooHigh();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address polymarketToken_,
        address opinionToken_,
        address feeCollector_,
        address owner_
    ) Ownable(owner_) {
        if (polymarketToken_ == address(0) ||
            opinionToken_    == address(0) ||
            feeCollector_    == address(0)) revert InvalidAddress();

        polymarketToken = polymarketToken_;
        opinionToken    = opinionToken_;
        feeCollector    = FeeCollector(feeCollector_);
    }

    // ─── Fee config ───────────────────────────────────────────────────────────

    /**
     * @notice Update swap fees. Changes take effect immediately for all pools.
     * @param lpFeeBps_        New LP fee in basis points (max 100 = 1.00%)
     * @param protocolFeeBps_  New protocol fee in basis points (max 50 = 0.50%)
     */
    function setFees(uint256 lpFeeBps_, uint256 protocolFeeBps_) external onlyOwner {
        if (lpFeeBps_ > MAX_LP_FEE || protocolFeeBps_ > MAX_PROTOCOL_FEE) revert FeeTooHigh();
        lpFeeBps       = lpFeeBps_;
        protocolFeeBps = protocolFeeBps_;
        emit FeesUpdated(lpFeeBps_, protocolFeeBps_);
    }

    /// @notice Total fee in basis points (LP + protocol)
    function totalFeeBps() external view returns (uint256) {
        return lpFeeBps + protocolFeeBps;
    }

    // ─── Pool creation ────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new SwapPool + LPToken for a matched event-outcome pair.
     *         Only token IDs are needed — token contracts are fixed at construction.
     *
     * @param polymarketTokenId_  Token ID on the Polymarket ERC-1155 contract
     * @param opinionTokenId_     Token ID on the WrappedOpinionToken contract
     * @param resolutionDate_     Expected resolution timestamp (informational)
     * @param lpName              ERC-20 name   e.g. "PredictSwap BTC-YES LP"
     * @param lpSymbol            ERC-20 symbol e.g. "PS-BTC-YES"
     *
     * @return poolId  Zero-indexed pool ID
     */
    function createPool(
        uint256 polymarketTokenId_,
        uint256 opinionTokenId_,
        uint256 resolutionDate_,
        string calldata lpName,
        string calldata lpSymbol
    ) external onlyOwner returns (uint256 poolId) {
        bytes32 key = _poolKey(polymarketTokenId_, opinionTokenId_);
        if (poolIndex[key] != 0) revert PoolAlreadyExists(key);

        // Step 1: Deploy LPToken with factory as temporary authority
        LPToken lp = new LPToken(lpName, lpSymbol, address(this));

        // Step 2: Deploy SwapPool — LP address is now known
        SwapPool pool_ = new SwapPool(
            address(this),
            polymarketTokenId_,
            opinionTokenId_,
            address(lp),
            address(feeCollector)
        );

        // Step 3: Wire LP token to its SwapPool (one-time, irreversible)
        lp.setPool(address(pool_));

        // Register
        poolId = pools.length;
        pools.push(PoolInfo({
            swapPool:          address(pool_),
            lpToken:           address(lp),
            polymarketTokenId: polymarketTokenId_,
            opinionTokenId:    opinionTokenId_,
            resolutionDate:    resolutionDate_,
            isActive:          true
        }));
        poolIndex[key] = poolId + 1;

        emit PoolCreated(
            poolId,
            address(pool_),
            address(lp),
            polymarketTokenId_,
            opinionTokenId_,
            resolutionDate_
        );
    }

    // ─── Registry reads ───────────────────────────────────────────────────────

    function getPool(uint256 poolId) external view returns (PoolInfo memory) {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        return pools[poolId];
    }

    function getAllPools() external view returns (PoolInfo[] memory) {
        return pools;
    }

    function getActivePools() external view returns (PoolInfo[] memory) {
        uint256 count;
        for (uint256 i; i < pools.length; i++) {
            if (pools[i].isActive) count++;
        }
        PoolInfo[] memory active = new PoolInfo[](count);
        uint256 j;
        for (uint256 i; i < pools.length; i++) {
            if (pools[i].isActive) active[j++] = pools[i];
        }
        return active;
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function findPool(
        uint256 polymarketTokenId_,
        uint256 opinionTokenId_
    ) external view returns (bool found, uint256 poolId) {
        uint256 idx = poolIndex[_poolKey(polymarketTokenId_, opinionTokenId_)];
        if (idx == 0) return (false, 0);
        return (true, idx - 1);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function deactivatePool(uint256 poolId) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        pools[poolId].isActive = false;
        emit PoolDeactivated(poolId);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _poolKey(uint256 polyId, uint256 opId) internal pure returns (bytes32) {
        return keccak256(abi.encode(polyId, opId));
    }
}