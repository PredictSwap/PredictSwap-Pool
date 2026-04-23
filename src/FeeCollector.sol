// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/**
 * @title FeeCollector
 * @notice Accumulates the protocol's fee cut from all SwapPool swaps and
 *         cross-side withdrawals. Fees are held as raw ERC-1155 shares
 *         (both Polymarket and WrappedOpinion). Only the owner (team) can withdraw.
 */
contract FeeCollector is Ownable, ERC1155Holder {
    event FeeReceived(address indexed pool, address indexed token, uint256 tokenId, uint256 amount);
    event FeeWithdrawn(address indexed token, uint256 tokenId, uint256 amount, address indexed to);

    error ZeroAmount();
    error ZeroAddress();

    constructor(address owner_) Ownable(owner_) {}

    // ─── Fee receipt (called by SwapPool) ────────────────────────────────────

    /**
     * @notice Called by SwapPool after transferring protocol fee shares here.
     *         Emits an accounting event. The actual token transfer is done by
     *         the pool before calling this function.
     *
     * @dev NOTE: Anyone can call this and emit a FeeReceived event.
     *      When indexing, filter by msg.sender being a known SwapPool address.
     */
    function recordFee(address token, uint256 tokenId, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        emit FeeReceived(msg.sender, token, tokenId, amount);
    }

    // ─── Withdrawal (team only) ───────────────────────────────────────────────

    function withdraw(address token, uint256 tokenId, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC1155(token).safeTransferFrom(address(this), to, tokenId, amount, "");
        emit FeeWithdrawn(token, tokenId, amount, to);
    }

    function withdrawBatch(
        address token,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts,
        address to
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        for (uint256 i; i < tokenIds.length; i++) {
            if (amounts[i] == 0) revert ZeroAmount();
            emit FeeWithdrawn(token, tokenIds[i], amounts[i], to);
        }
        IERC1155(token).safeBatchTransferFrom(address(this), to, tokenIds, amounts, "");
    }

    /// @notice Withdraw the entire balance of a single token ID.
    function withdrawAll(address token, uint256 tokenId, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC1155(token).balanceOf(address(this), tokenId);
        if (amount == 0) revert ZeroAmount();
        IERC1155(token).safeTransferFrom(address(this), to, tokenId, amount, "");
        emit FeeWithdrawn(token, tokenId, amount, to);
    }

    /// @notice Withdraw the entire balance of multiple token IDs in one call.
    ///         Token IDs with zero balance are silently skipped.
    function withdrawAllBatch(address token, uint256[] calldata tokenIds, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        // First pass: count non-zero entries
        uint256 count;
        for (uint256 i; i < tokenIds.length; i++) {
            if (IERC1155(token).balanceOf(address(this), tokenIds[i]) > 0) count++;
        }
        if (count == 0) revert ZeroAmount();

        // Second pass: build compact arrays
        uint256[] memory ids = new uint256[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 j;
        for (uint256 i; i < tokenIds.length; i++) {
            uint256 bal = IERC1155(token).balanceOf(address(this), tokenIds[i]);
            if (bal == 0) continue;
            ids[j] = tokenIds[i];
            amounts[j] = bal;
            emit FeeWithdrawn(token, tokenIds[i], bal, to);
            j++;
        }

        IERC1155(token).safeBatchTransferFrom(address(this), to, ids, amounts, "");
    }
}