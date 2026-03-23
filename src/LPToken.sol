// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title LPToken
 * @notice ERC-20 LP token representing a user's share of a specific SwapPool.
 *         Two LPToken contracts are deployed per pool by PoolFactory —
 *         one for Polymarket depositors, one for Opinion depositors.
 *         Only the associated SwapPool can mint or burn.
 *
 * ─── Two-step pool assignment ─────────────────────────────────────────────────
 *
 * To avoid the chicken-and-egg problem (SwapPool needs LP address,
 * LPToken needs SwapPool address), the factory is set as a temporary authority
 * at deploy time. After SwapPool is deployed, the factory calls setPool() once
 * to wire the LP token to its pool. setPool() can never be called again.
 *
 * ─── Exchange rate ────────────────────────────────────────────────────────────
 *
 *   Unified rate = SwapPool.totalShares() / (polyLpToken.totalSupply() + opinionLpToken.totalSupply())
 *
 * Both LP tokens share the same exchange rate. The LP token type only determines
 * which side a user deposited from, controlling same-side vs cross-side withdrawal rules.
 *
 * Rate starts at 1.0 for the first depositor and increases as LP fees
 * auto-compound in the pool.
 */
contract LPToken is ERC20 {
    address public pool;
    address public immutable factory;

    error OnlyPool();
    error OnlyFactory();
    error PoolAlreadySet();
    error ZeroAddress();

    event PoolSet(address indexed pool);

    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    constructor(string memory name_, string memory symbol_, address factory_) ERC20(name_, symbol_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /**
     * @notice One-time assignment of the associated SwapPool address.
     *         Called by PoolFactory immediately after deploying the SwapPool.
     *         Cannot be called again once set.
     */
    function setPool(address pool_) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (pool != address(0)) revert PoolAlreadySet();
        if (pool_ == address(0)) revert ZeroAddress();
        pool = pool_;
        emit PoolSet(pool_);
    }

    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }
}