// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./SwapPool.sol";
import "./LPToken.sol";
import "./FeeCollector.sol";

/**
 * @title PoolFactory
 * @notice Deploys SwapPools and serves as the on-chain registry of all active pools
 *         for ONE specific marketA ↔ marketB contract pair.
 *
 *         Both underlying ERC-1155 prediction-market contracts (marketA, marketB)
 *         are fixed at deploy time as immutable addresses. Pools are identified by
 *         the outcome/event tokenIds on each side; the contract addresses are shared.
 *
 *         A single shared ERC-1155 LPToken is deployed once per side in the
 *         constructor and serves every pool. Each pool registers two LP
 *         positions at creation time; the LP tokenId on each side equals the
 *         underlying prediction-market tokenId. Market tokenIds are
 *         strictly non-reusable across pools on either side within this
 *         factory — enforced via usedMarketATokenId / usedMarketBTokenId.
 *
 *         Fees are set per-pool at creation time and stored on the pool itself.
 *         The factory only holds the FeeCollector address — the destination for
 *         protocol fees across all pools.
 *
 * ─── Roles ────────────────────────────────────────────────────────────────────
 *
 *   Owner:    setFeeCollector, setOperator, setPoolFees, rescuePool*
 *   Operator: createPool, setPoolDepositsPaused, setPoolSwapsPaused,
 *             setResolvePool, resolvePoolAndPause
 *   Owner can always perform operator actions too.
 */
contract PoolFactory is Ownable {

    // ─── Types ────────────────────────────────────────────────────────────────

    /**
     * @notice Description of one market side in a pool.
     *
     * @param tokenId   Outcome/event ID within the corresponding factory-level contract
     * @param decimals  Decimal precision of the shares (max 18)
     */
    struct MarketConfig {
        uint256 tokenId;
        uint8   decimals;
    }

    struct PoolInfo {
        address swapPool;
        uint256 marketALpTokenId;
        uint256 marketBLpTokenId;
        MarketConfig marketA;
        MarketConfig marketB;
    }

    // ─── Immutable config ─────────────────────────────────────────────────────

    /// @notice ERC-1155 prediction-market contract used on the marketA side of every pool.
    address public immutable marketAContract;

    /// @notice ERC-1155 prediction-market contract used on the marketB side of every pool.
    address public immutable marketBContract;

    /// @notice ERC-1155 LP token instance for marketA-side LP positions across all pools.
    ///         Same generic LPToken contract as marketBLpToken — distinguished only by
    ///         the human-readable name stored in each instance.
    LPToken public immutable marketALpToken;

    /// @notice ERC-1155 LP token instance for marketB-side LP positions across all pools.
    LPToken public immutable marketBLpToken;

    /// @notice Human-readable name of the marketA project (e.g. "Polymarket"). Set once at
    ///         deployment — this factory only ever serves this project on its marketA side.
    string public marketAName;

    /// @notice Human-readable name of the marketB project (e.g. "PredictFun"). Set once at
    ///         deployment — this factory only ever serves this project on its marketB side.
    string public marketBName;

    // ─── Roles ────────────────────────────────────────────────────────────────

    address public operator;

    // ─── Fee collector ────────────────────────────────────────────────────────

    FeeCollector public feeCollector;

    // ─── State ────────────────────────────────────────────────────────────────

    PoolInfo[] public pools;

    /// @notice keccak256(marketATokenId, marketBTokenId) → poolId, 1-indexed; 0 = not found
    mapping(bytes32 => uint256) public poolIndex;

    /// @notice Tracks marketA-side tokenIds already consumed by a pool in this factory.
    mapping(uint256 tokenId => bool) public usedMarketATokenId;

    /// @notice Tracks marketB-side tokenIds already consumed by a pool in this factory.
    mapping(uint256 tokenId => bool) public usedMarketBTokenId;

    // ─── Events ───────────────────────────────────────────────────────────────

    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    event PoolCreated(
        uint256 indexed poolId,
        address swapPool,
        uint256 marketATokenId,
        uint256 marketALpTokenId,
        uint256 marketBTokenId,
        uint256 marketBLpTokenId,
        uint256 lpFeeBps,
        uint256 protocolFeeBps,
        string  eventDescription
    );
    event PoolDepositsPaused(uint256 indexed poolId, bool isPaused);
    event PoolSwapsPaused(uint256 indexed poolId, bool isPaused);
    event PoolResolved(uint256 indexed poolId, bool isResolved);
    event FeeCollectorUpdated(address indexed oldFeeCollector, address indexed newFeeCollector);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error PoolAlreadyExists(bytes32 key);
    error PoolNotFound(uint256 poolId);
    error ZeroAddress();
    error InvalidTokenID();
    error MarketATokenIdAlreadyUsed(uint256 tokenId);
    error MarketBTokenIdAlreadyUsed(uint256 tokenId);
    error InvalidDecimals();
    error MissingName();
    error NotOperator();

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner()) revert NotOperator();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address marketAContract_,
        address marketBContract_,
        address feeCollector_,
        address operator_,
        address owner_,
        string memory marketAName_,
        string memory marketBName_,
        string memory marketALpName_,
        string memory marketBLpName_
    ) Ownable(owner_) {
        if (marketAContract_ == address(0)) revert ZeroAddress();
        if (marketBContract_ == address(0)) revert ZeroAddress();
        if (feeCollector_ == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();
        if (bytes(marketAName_).length == 0 || bytes(marketBName_).length == 0)
            revert MissingName();
        if (bytes(marketALpName_).length == 0 || bytes(marketBLpName_).length == 0)
            revert MissingName();

        marketAContract = marketAContract_;
        marketBContract = marketBContract_;
        feeCollector    = FeeCollector(feeCollector_);
        operator        = operator_;
        marketAName     = marketAName_;
        marketBName     = marketBName_;

        marketALpToken = new LPToken(address(this), marketALpName_);
        marketBLpToken = new LPToken(address(this), marketBLpName_);
    }

    // ─── Pool creation (operator) ─────────────────────────────────────────────

    /**
     * @notice Deploy a new SwapPool for a matched marketA↔marketB tokenId pair and
     *         register its LP positions on the two LP token instances.
     *
     * @param marketA_           MarketA config (tokenId, decimals)
     * @param marketB_           MarketB config (tokenId, decimals)
     * @param lpFeeBps_          LP fee in basis points, e.g. 30 = 0.30%
     * @param protocolFeeBps_    Protocol fee in basis points, e.g. 10 = 0.10%
     * @param eventDescription_  Human-readable label for this pool's event/outcome, e.g.
     *                           "Trump out 2028 - YES". Emitted in PoolCreated for logging;
     *                           never stored on-chain.
     *
     * @return poolId  Zero-indexed pool ID
     */
    function createPool(
        MarketConfig calldata marketA_,
        MarketConfig calldata marketB_,
        uint256 lpFeeBps_,
        uint256 protocolFeeBps_,
        string   calldata eventDescription_
    ) external onlyOperator returns (uint256 poolId) {
        if (marketA_.tokenId == 0 || marketB_.tokenId == 0) revert InvalidTokenID();
        if (marketA_.decimals > 18 || marketB_.decimals > 18) revert InvalidDecimals();

        bytes32 key = _poolKey(marketA_.tokenId, marketB_.tokenId);
        if (poolIndex[key] != 0) revert PoolAlreadyExists(key);
        if (usedMarketATokenId[marketA_.tokenId]) revert MarketATokenIdAlreadyUsed(marketA_.tokenId);
        if (usedMarketBTokenId[marketB_.tokenId]) revert MarketBTokenIdAlreadyUsed(marketB_.tokenId);

        SwapPool pool_ = new SwapPool(
            address(this),
            marketA_,
            marketB_,
            lpFeeBps_,
            protocolFeeBps_,
            address(feeCollector)
        );

        // LP tokenIds mirror the underlying market tokenIds. Side-level uniqueness is enforced
        // above, so registration on the LP contract cannot collide.
        uint256 lpIdA = marketA_.tokenId;
        uint256 lpIdB = marketB_.tokenId;
        usedMarketATokenId[lpIdA] = true;
        usedMarketBTokenId[lpIdB] = true;
        marketALpToken.registerPool(address(pool_), lpIdA);
        marketBLpToken.registerPool(address(pool_), lpIdB);

        pool_.initialize(lpIdA, lpIdB);

        poolId = pools.length;
        pools.push(PoolInfo({
            swapPool:         address(pool_),
            marketALpTokenId: lpIdA,
            marketBLpTokenId: lpIdB,
            marketA:          marketA_,
            marketB:          marketB_
        }));
        poolIndex[key] = poolId + 1;

        emit PoolCreated(
            poolId,
            address(pool_),
            marketA_.tokenId,
            lpIdA,
            marketB_.tokenId,
            lpIdB,
            lpFeeBps_,
            protocolFeeBps_,
            eventDescription_
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

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function findPool(uint256 marketATokenId_, uint256 marketBTokenId_)
        external
        view
        returns (bool found, uint256 poolId)
    {
        uint256 idx = poolIndex[_poolKey(marketATokenId_, marketBTokenId_)];
        if (idx == 0) return (false, 0);
        return (true, idx - 1);
    }

    // ─── Admin — owner only ───────────────────────────────────────────────────

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        emit OperatorUpdated(operator, operator_);
        operator = operator_;
    }

    function setFeeCollector(address feeCollector_) external onlyOwner {
        if (feeCollector_ == address(0)) revert ZeroAddress();
        emit FeeCollectorUpdated(address(feeCollector), feeCollector_);
        feeCollector = FeeCollector(feeCollector_);
    }

    function setPoolFees(uint256 poolId, uint256 lpFeeBps_, uint256 protocolFeeBps_) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).setFees(lpFeeBps_, protocolFeeBps_);
    }

    // ─── Admin — operator ─────────────────────────────────────────────────────

    function setPoolDepositsPaused(uint256 poolId, bool paused_) external onlyOperator {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).setDepositsPaused(paused_);
        emit PoolDepositsPaused(poolId, paused_);
    }

    function setPoolSwapsPaused(uint256 poolId, bool paused_) external onlyOperator {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).setSwapsPaused(paused_);
        emit PoolSwapsPaused(poolId, paused_);
    }

    function setResolvePool(uint256 poolId, bool resolved_) external onlyOperator {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).setResolved(resolved_);
        emit PoolResolved(poolId, resolved_);
    }

    // NOTE it should be fired as soon as any side of the pool resolved, so users can not drain 
    // by swapping to or withdrawing from it
    function resolvePoolAndPause(uint256 poolId) external onlyOperator {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).setResolvedAndPaused();
        emit PoolResolved(poolId, true);
        emit PoolDepositsPaused(poolId, true);
        emit PoolSwapsPaused(poolId, true);
    }

    // ─── Rescue — owner only ──────────────────────────────────────────────────

    function rescuePoolTokens(uint256 poolId, SwapPool.Side side, uint256 amount, address to)
        external onlyOwner
    {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).rescueTokens(side, amount, to);
    }

    function rescuePoolERC1155(uint256 poolId, address contractAddress, uint256 tokenId, uint256 amount, address to)
        external onlyOwner
    {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).rescueERC1155(contractAddress, tokenId, amount, to);
    }

    function rescuePoolERC20(uint256 poolId, address token, uint256 amount, address to)
        external onlyOwner
    {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).rescueERC20(token, amount, to);
    }

    function rescuePoolETH(uint256 poolId, address payable to) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).rescueETH(to);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _poolKey(uint256 marketATokenId_, uint256 marketBTokenId_) internal pure returns (bytes32) {
        return keccak256(abi.encode(marketATokenId_, marketBTokenId_));
    }
}
