// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/**
 * @title LPToken
 * @notice Generic ERC-1155 LP token used by SwapPools. One deployment per market
 *         side (the factory deploys two instances: one for marketA-LP holders,
 *         one for marketB-LP holders). The same contract definition is reusable
 *         across any market — the instance-level `name` distinguishes them.
 *
 *         Each deployed instance serves ALL pools on its side. Per-pool LP
 *         positions are distinguished by a tokenId set equal to the underlying
 *         prediction-market tokenId (supplied by the factory at registration
 *         time). Only the registered pool can mint or burn that tokenId.
 *         
 *         It is not possible to change tokenID <> poolAddress connction for 
 *         security reason. If for some reason you have to redeploy pool 
 *         you will need to redeploy LP token also
 *
 * ─── Two-bucket JIT lock ──────────────────────────────────────────────────────
 *
 *   Each user's LP position is implicitly split into two buckets:
 *
 *     • MATURED  — tokens deposited > 24h ago (no fee on withdrawal)
 *     • FRESH    — tokens deposited ≤ 24h ago (0.4% quick-exit fee applies)
 *
 *   Only the fresh bucket is stored explicitly as (amount, timestamp). The
 *   matured amount is derived: totalBalance − fresh.amount.
 *
 *   On any inflow (mint or transfer-in):
 *     1. Graduate the recipient's existing fresh bucket if ≥ 24h old.
 *     2. Merge the incoming amount into the fresh bucket with a
 *        weighted-average timestamp. Transfers-in are always treated as
 *        fresh — maturity does not carry across wallets.
 *     NOTE Transfered tokens would also be FRESH for LOCK_PERIOD, users who 
 *      for somne reason decided to move their position would also need to wait
 *      before withdrawal
 *
 *   On any outflow (burn or transfer-out):
 *     1. Graduate if matured.
 *     2. Consume matured tokens first; only reduce the fresh bucket if the
 *        outflow exceeds the matured portion.
 *
 *   The SwapPool calls lockedAmount(user, tokenId) before a withdrawal to
 *   compute what portion of the burn is subject to the quick-exit fee.
 *   
 */
contract LPToken is ERC1155 {
    uint256 public constant LOCK_PERIOD = 24 hours;

    struct FreshDeposit {
        uint256 amount;
        uint256 timestamp;
    }

    /// @notice Authorized registrar (the PoolFactory that deployed this instance).
    address public immutable factory;

    /// @notice Human-readable name for this LP token instance, set at deploy time.
    ///         E.g. "Polymarket LP in  Polymarket:PredictFun pool".
    string public name;

    /// @notice Authorized pool per tokenId. Assigned once at registerPool().
    ///         tokenId 0 is reserved as "unassigned" and rejected at registration.
    mapping(uint256 tokenId => address) public pool;

    /// @notice Total supply per tokenId (for rate math in SwapPool).
    mapping(uint256 tokenId => uint256) public totalSupply;

    /// @notice Fresh (locked) deposit bucket, per user per tokenId.
    mapping(address user => mapping(uint256 tokenId => FreshDeposit)) public freshDeposit;

    error OnlyPool();
    error OnlyFactory();
    error ZeroAddress();
    error InvalidTokenId();
    error TokenIdAlreadyRegistered();

    event PoolRegistered(uint256 indexed tokenId, address indexed pool);

    modifier onlyPool(uint256 tokenId) {
        if (msg.sender != pool[tokenId]) revert OnlyPool();
        _;
    }

    constructor(address factory_, string memory name_) ERC1155("") {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        name = name_;
    }

    /// @notice Factory registers a new pool on this LP instance under the given tokenId.
    ///         The factory mirrors the underlying prediction-market tokenId here; collisions
    ///         are the factory's responsibility to avoid, but we reject them defensively.
    function registerPool(address pool_, uint256 tokenId) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (pool_ == address(0)) revert ZeroAddress();
        if (tokenId == 0) revert InvalidTokenId();
        if (pool[tokenId] != address(0)) revert TokenIdAlreadyRegistered();
        pool[tokenId] = pool_;
        emit PoolRegistered(tokenId, pool_);
    }

    function mint(address to, uint256 tokenId, uint256 amount) external onlyPool(tokenId) {
        totalSupply[tokenId] += amount;
        _mint(to, tokenId, amount, "");
    }

    function burn(address from, uint256 tokenId, uint256 amount) external onlyPool(tokenId) {
        totalSupply[tokenId] -= amount;
        _burn(from, tokenId, amount);
    }

    /// @notice Currently-locked (fresh) LP for `user` on `tokenId`. Returns 0 once the
    ///         fresh bucket has aged past LOCK_PERIOD, even if it has not yet been
    ///         graduated by a touch.
    function lockedAmount(address user, uint256 tokenId) external view returns (uint256) {
        FreshDeposit memory f = freshDeposit[user][tokenId];
        if (f.amount == 0 || block.timestamp >= f.timestamp + LOCK_PERIOD) {
            return 0;
        }
        return f.amount;
    }

    /// @notice Convenience check — true if any portion of the position is still fresh.
    function isLocked(address user, uint256 tokenId) external view returns (bool) {
        FreshDeposit memory f = freshDeposit[user][tokenId];
        return f.amount > 0 && block.timestamp < f.timestamp + LOCK_PERIOD;
    }

    /// @dev OZ v5 single hook for mint/burn/transfer (single & batch).
    ///      Maintains the per-user fresh-deposit bucket on every balance change.
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override {
        super._update(from, to, ids, values);

        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            uint256 value = values[i];
            if (value == 0) continue;

            // ── Outflow (burn or transfer-out): consume matured first. ──
            if (from != address(0)) {
                FreshDeposit storage sf = freshDeposit[from][id];
                if (sf.amount > 0) {
                    if (block.timestamp >= sf.timestamp + LOCK_PERIOD) {
                        sf.amount = 0;
                        sf.timestamp = 0;
                    } else {
                        uint256 preBalance = balanceOf(from, id) + value;
                        uint256 matured = preBalance > sf.amount
                            ? preBalance - sf.amount
                            : 0;
                        if (value > matured) {
                            sf.amount -= (value - matured);
                        }
                        if (sf.amount == 0) {
                            sf.timestamp = 0;
                        }
                    }
                }
            }

            // ── Inflow (mint or transfer-in): grow recipient's fresh bucket. ──
            if (to != address(0)) {
                FreshDeposit storage tf = freshDeposit[to][id];

                if (tf.amount > 0 && block.timestamp >= tf.timestamp + LOCK_PERIOD) {
                    tf.amount = 0;
                    tf.timestamp = 0;
                }

                if (tf.amount == 0) {
                    tf.amount = value;
                    tf.timestamp = block.timestamp;
                } else {
                    tf.timestamp =
                        (tf.amount * tf.timestamp + value * block.timestamp)
                        / (tf.amount + value);
                    tf.amount += value;
                }
            }
        }
    }
}
