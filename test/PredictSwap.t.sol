// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FeeCollector.sol";
import "../src/LPToken.sol";
import "../src/PoolFactory.sol";
import "../src/SwapPool.sol";
import "./MockERC1155.sol";

/**
 * @title PredictSwap Test Suite
 *
 * Covers:
 *   FeeCollector  — recordFee, withdraw, withdrawAll, withdrawAllBatch, access control
 *   LPToken       — setPool, mint, burn, access control
 *   PoolFactory   — createPool, registry reads, setFees, resolve/unresolve
 *   SwapPool      — deposit, withdrawSingleSide (same-side / cross-side / resolved),
 *                   withdrawBothSides, swap, exchange rate, fee math, rescue, pausing
 */
contract PredictSwapTest is Test {
    // ─── Actors ───────────────────────────────────────────────────────────────
    address owner    = makeAddr("owner");
    address lp1      = makeAddr("lp1");
    address lp2      = makeAddr("lp2");
    address swapper  = makeAddr("swapper");
    address attacker = makeAddr("attacker");

    // ─── Token IDs ────────────────────────────────────────────────────────────
    uint256 constant POLY_ID    = 1;
    uint256 constant OPINION_ID = 511515;

    // ─── Contracts ────────────────────────────────────────────────────────────
    MockERC1155  polyToken;
    MockERC1155  opinionToken;
    FeeCollector feeCollector;
    PoolFactory  factory;
    SwapPool     pool;
    LPToken      polyLp;
    LPToken      opinionLp;

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        polyToken    = new MockERC1155();
        opinionToken = new MockERC1155();

        vm.startPrank(owner);
        feeCollector = new FeeCollector(owner);
        factory = new PoolFactory(
            address(polyToken),
            address(opinionToken),
            address(feeCollector),
            owner
        );

        uint256 poolId = factory.createPool(
            POLY_ID, OPINION_ID,
            "PredictSwap BTC-YES PolyLP",    "PS-BTC-YES-POLY",
            "PredictSwap BTC-YES OpinionLP", "PS-BTC-YES-OP"
        );
        vm.stopPrank();

        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        pool      = SwapPool(payable(info.swapPool));
        polyLp    = LPToken(info.polyLpToken);
        opinionLp = LPToken(info.opinionLpToken);

        _fundAndApprove(lp1,     10_000, 10_000);
        _fundAndApprove(lp2,     10_000, 10_000);
        _fundAndApprove(swapper,  5_000,  5_000);
    }

    function _fundAndApprove(address user, uint256 polyAmt, uint256 opinionAmt) internal {
        polyToken.mint(user, POLY_ID, polyAmt);
        opinionToken.mint(user, OPINION_ID, opinionAmt);
        vm.startPrank(user);
        polyToken.setApprovalForAll(address(pool), true);
        opinionToken.setApprovalForAll(address(pool), true);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FeeCollector
    // ═══════════════════════════════════════════════════════════════════════════

    function test_FeeCollector_recordFee_emitsEvent() public {
        polyToken.mint(address(feeCollector), POLY_ID, 100);
        vm.expectEmit(true, true, false, true);
        emit FeeCollector.FeeReceived(address(this), address(polyToken), POLY_ID, 100);
        feeCollector.recordFee(address(polyToken), POLY_ID, 100);
    }

    function test_FeeCollector_recordFee_revertsOnZero() public {
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.recordFee(address(polyToken), POLY_ID, 0);
    }

    function test_FeeCollector_withdraw_success() public {
        polyToken.mint(address(feeCollector), POLY_ID, 500);
        vm.prank(owner);
        feeCollector.withdraw(address(polyToken), POLY_ID, 500, owner);
        assertEq(polyToken.balanceOf(owner, POLY_ID), 500);
    }

    function test_FeeCollector_withdraw_revertsNonOwner() public {
        polyToken.mint(address(feeCollector), POLY_ID, 100);
        vm.prank(attacker);
        vm.expectRevert();
        feeCollector.withdraw(address(polyToken), POLY_ID, 100, attacker);
    }

    function test_FeeCollector_withdraw_revertsZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.withdraw(address(polyToken), POLY_ID, 0, owner);
    }

    function test_FeeCollector_withdrawAll_success() public {
        polyToken.mint(address(feeCollector), POLY_ID, 300);
        vm.prank(owner);
        feeCollector.withdrawAll(address(polyToken), POLY_ID, owner);
        assertEq(polyToken.balanceOf(owner, POLY_ID), 300);
        assertEq(polyToken.balanceOf(address(feeCollector), POLY_ID), 0);
    }

    function test_FeeCollector_withdrawAll_revertsIfEmpty() public {
        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.withdrawAll(address(polyToken), POLY_ID, owner);
    }

    function test_FeeCollector_withdrawAllBatch_skipsZeroBalanceIds() public {
        MockERC1155 multi = new MockERC1155();
        multi.mint(address(feeCollector), 1, 100);
        // id 2 has zero balance — should not revert
        multi.mint(address(feeCollector), 3, 300);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 1; ids[1] = 2; ids[2] = 3;

        vm.prank(owner);
        feeCollector.withdrawAllBatch(address(multi), ids, owner);

        assertEq(multi.balanceOf(owner, 1), 100);
        assertEq(multi.balanceOf(owner, 2), 0);
        assertEq(multi.balanceOf(owner, 3), 300);
    }

    function test_FeeCollector_withdrawAllBatch_success() public {
        MockERC1155 multi = new MockERC1155();
        multi.mint(address(feeCollector), 1, 100);
        multi.mint(address(feeCollector), 2, 200);
        multi.mint(address(feeCollector), 3, 300);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 1; ids[1] = 2; ids[2] = 3;

        vm.prank(owner);
        feeCollector.withdrawAllBatch(address(multi), ids, owner);

        assertEq(multi.balanceOf(owner, 1), 100);
        assertEq(multi.balanceOf(owner, 2), 200);
        assertEq(multi.balanceOf(owner, 3), 300);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LPToken
    // ═══════════════════════════════════════════════════════════════════════════

    function test_LPToken_setPool_onlyFactory() public {
        LPToken newLp = new LPToken("Test", "T", address(this));
        newLp.setPool(address(pool));
        assertEq(newLp.pool(), address(pool));
    }

    function test_LPToken_setPool_revertsIfCalledTwice() public {
        LPToken newLp = new LPToken("Test", "T", address(this));
        newLp.setPool(makeAddr("pool1"));
        vm.expectRevert(LPToken.PoolAlreadySet.selector);
        newLp.setPool(makeAddr("pool2"));
    }

    function test_LPToken_setPool_revertsNonFactory() public {
        LPToken newLp = new LPToken("Test", "T", address(this));
        vm.prank(attacker);
        vm.expectRevert(LPToken.OnlyFactory.selector);
        newLp.setPool(makeAddr("pool"));
    }

    function test_LPToken_setPool_revertsZeroAddress() public {
        LPToken newLp = new LPToken("Test", "T", address(this));
        vm.expectRevert(LPToken.ZeroAddress.selector);
        newLp.setPool(address(0));
    }

    function test_LPToken_mint_onlyPool() public {
        vm.prank(attacker);
        vm.expectRevert(LPToken.OnlyPool.selector);
        polyLp.mint(attacker, 100);
    }

    function test_LPToken_burn_onlyPool() public {
        vm.prank(attacker);
        vm.expectRevert(LPToken.OnlyPool.selector);
        polyLp.burn(attacker, 100);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PoolFactory
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Factory_createPool_registersCorrectly() public view {
        PoolFactory.PoolInfo memory info = factory.getPool(0);
        assertEq(info.polymarketTokenId, POLY_ID);
        assertEq(info.opinionTokenId, OPINION_ID);
        assertTrue(info.swapPool      != address(0));
        assertTrue(info.polyLpToken   != address(0));
        assertTrue(info.opinionLpToken != address(0));
    }

    function test_Factory_createPool_twoDistinctLpTokens() public view {
        PoolFactory.PoolInfo memory info = factory.getPool(0);
        assertTrue(info.polyLpToken != info.opinionLpToken);
    }

    function test_Factory_createPool_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.createPool(99, 88, "X", "X", "Y", "Y");
    }

    function test_Factory_createPool_revertsDuplicate() public {
        vm.prank(owner);
        vm.expectRevert();
        factory.createPool(POLY_ID, OPINION_ID, "Dup", "D", "Dup2", "D2");
    }

    function test_Factory_createPool_multiplePools() public {
        vm.startPrank(owner);
        factory.createPool(2, 511516, "Pool2", "P2", "Pool2Op", "P2O");
        factory.createPool(3, 511517, "Pool3", "P3", "Pool3Op", "P3O");
        vm.stopPrank();

        assertEq(factory.poolCount(), 3);
        assertEq(factory.getAllPools().length, 3);
    }

    function test_Factory_findPool_found() public view {
        (bool found, uint256 poolId) = factory.findPool(POLY_ID, OPINION_ID);
        assertTrue(found);
        assertEq(poolId, 0);
    }

    function test_Factory_findPool_notFound() public view {
        (bool found,) = factory.findPool(999, 888);
        assertFalse(found);
    }

    function test_Factory_setFees_success() public {
        vm.prank(owner);
        factory.setFees(50, 20);
        assertEq(factory.lpFeeBps(), 50);
        assertEq(factory.protocolFeeBps(), 20);
        assertEq(factory.totalFeeBps(), 70);
    }

    function test_Factory_setFees_revertsAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(PoolFactory.FeeTooHigh.selector);
        factory.setFees(101, 10);

        vm.prank(owner);
        vm.expectRevert(PoolFactory.FeeTooHigh.selector);
        factory.setFees(50, 51);
    }

    function test_Factory_setFees_revertsNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.setFees(10, 5);
    }

    function test_Factory_setFees_canSetZero() public {
        vm.prank(owner);
        factory.setFees(0, 0);
        assertEq(factory.lpFeeBps(), 0);
        assertEq(factory.protocolFeeBps(), 0);
    }

    function test_Factory_pauseDeposits() public {
        vm.prank(owner);
        factory.setPoolDepositsPaused(0, true);
        assertTrue(pool.depositsPaused());

        vm.prank(lp1);
        vm.expectRevert(SwapPool.DepositsPaused.selector);
        pool.deposit(SwapPool.Side.POLYMARKET, 100);
    }

    function test_Factory_pauseSwaps() public {
        vm.prank(owner);
        factory.setPoolSwapsPaused(0, true);
        assertTrue(pool.swapsPaused());

        vm.prank(swapper);
        vm.expectRevert(SwapPool.SwapsPaused.selector);
        pool.swap(SwapPool.Side.POLYMARKET, 100);
    }

    function test_Factory_resolvePool_pausesDeposits() public {
        vm.prank(owner);
        factory.resolvePoolAndPausedDeposits(0);

        assertTrue(pool.resolved());
        assertTrue(pool.depositsPaused());
    }

    function test_Factory_unresolvePool_unpausesDeposits() public {
        vm.prank(owner);
        factory.resolvePoolAndPausedDeposits(0);

        vm.prank(owner);
        factory.unresolvePool(0);

        assertFalse(pool.resolved());
        assertFalse(pool.depositsPaused());
    }

    function test_Factory_resolvePool_revertsIfAlreadyResolved() public {
        vm.prank(owner);
        factory.resolvePoolAndPausedDeposits(0);

        vm.prank(owner);
        vm.expectRevert(SwapPool.AlreadyResolved.selector);
        factory.resolvePoolAndPausedDeposits(0);
    }

    function test_Factory_unresolvePool_revertsIfNotResolved() public {
        vm.prank(owner);
        vm.expectRevert(SwapPool.NotResolved.selector);
        factory.unresolvePool(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SwapPool — Deposit
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Deposit_poly_mintsPolyLp() public {
        vm.prank(lp1);
        uint256 minted = pool.deposit(SwapPool.Side.POLYMARKET, 1000);

        assertEq(minted, 1000);
        assertEq(polyLp.balanceOf(lp1), 1000);
        assertEq(opinionLp.balanceOf(lp1), 0);
        assertEq(pool.polymarketBalance(), 1000);
    }

    function test_Deposit_opinion_mintsOpinionLp() public {
        vm.prank(lp1);
        uint256 minted = pool.deposit(SwapPool.Side.OPINION, 1000);

        assertEq(minted, 1000);
        assertEq(opinionLp.balanceOf(lp1), 1000);
        assertEq(polyLp.balanceOf(lp1), 0);
        assertEq(pool.opinionBalance(), 1000);
    }

    function test_Deposit_firstDepositor_oneToOne() public {
        vm.prank(lp1);
        uint256 minted = pool.deposit(SwapPool.Side.POLYMARKET, 1000);

        assertEq(minted, 1000);
        assertEq(pool.totalLpSupply(), 1000);
        assertEq(pool.exchangeRate(), 1e18);
    }

    function test_Deposit_secondDepositor_cleanPool() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);

        vm.prank(lp2);
        uint256 minted = pool.deposit(SwapPool.Side.OPINION, 1000);

        assertEq(minted, 1000);
        assertEq(pool.totalLpSupply(), 2000);
        assertEq(pool.totalShares(), 2000);
    }

    function test_Deposit_secondDepositor_afterFeeAccrual() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 1000);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.POLYMARKET, 1000);

        uint256 rateAfter = pool.exchangeRate();
        assertGt(rateAfter, 1e18, "rate should increase after fee");

        vm.prank(lp2);
        uint256 minted = pool.deposit(SwapPool.Side.OPINION, 1000);
        assertLt(minted, 1000, "lp2 should get fewer LP tokens after fee accrual");
    }

    function test_Deposit_totalLpSupply_sumsBothTokens() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 600);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 400);

        assertEq(polyLp.totalSupply(), 600);
        assertEq(opinionLp.totalSupply(), 400);
        assertEq(pool.totalLpSupply(), 1000);
    }

    function test_Deposit_revertsZeroAmount() public {
        vm.prank(lp1);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.deposit(SwapPool.Side.POLYMARKET, 0);
    }

    function test_Deposit_revertsWhenPaused() public {
        vm.prank(owner);
        factory.setPoolDepositsPaused(0, true);

        vm.prank(lp1);
        vm.expectRevert(SwapPool.DepositsPaused.selector);
        pool.deposit(SwapPool.Side.POLYMARKET, 100);
    }

    function test_Deposit_emitsEvent() public {
        vm.prank(lp1);
        vm.expectEmit(true, false, false, true);
        emit SwapPool.Deposited(lp1, SwapPool.Side.POLYMARKET, 500, 500);
        pool.deposit(SwapPool.Side.POLYMARKET, 500);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SwapPool — withdrawSingleSide
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WithdrawSingleSide_sameSide_poly_free() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);

        uint256 polyBefore = polyToken.balanceOf(lp1, POLY_ID);

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.POLYMARKET, SwapPool.Side.POLYMARKET);

        assertEq(polyToken.balanceOf(lp1, POLY_ID), polyBefore + 1000);
        assertEq(polyLp.balanceOf(lp1), 0);
        assertEq(pool.polymarketBalance(), 0);
        // No fee collector balance — same-side is free
        assertEq(polyToken.balanceOf(address(feeCollector), POLY_ID), 0);
    }

    function test_WithdrawSingleSide_sameSide_opinion_free() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 1000);

        uint256 opinionBefore = opinionToken.balanceOf(lp1, OPINION_ID);

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.OPINION, SwapPool.Side.OPINION);

        assertEq(opinionToken.balanceOf(lp1, OPINION_ID), opinionBefore + 1000);
        assertEq(opinionLp.balanceOf(lp1), 0);
    }

    function test_WithdrawSingleSide_crossSide_chargesFee() public {
        // Pool needs Opinion liquidity to pay out cross-side
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        uint256 opinionBefore = opinionToken.balanceOf(lp1, OPINION_ID);

        // lp1 burns polyLp and receives Opinion (cross-side)
        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.POLYMARKET, SwapPool.Side.OPINION);

        // sharesOut = 1000 * 10000 / 10000 = 1000
        // lpFee = 1000 * 30 / 10000 = 3, protocolFee = 1000 * 10 / 10000 = 1
        // actualOut = 996
        assertEq(opinionToken.balanceOf(lp1, OPINION_ID), opinionBefore + 996);
        assertEq(opinionToken.balanceOf(address(feeCollector), OPINION_ID), 1);
        // LP fee (3) stays in opinionBalance implicitly
    }

    function test_WithdrawSingleSide_crossSide_resolved_free() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        vm.prank(owner);
        factory.resolvePoolAndPausedDeposits(0);

        uint256 opinionBefore = opinionToken.balanceOf(lp1, OPINION_ID);

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.POLYMARKET, SwapPool.Side.OPINION);

        // After resolution: no fee
        assertEq(opinionToken.balanceOf(lp1, OPINION_ID), opinionBefore + 1000);
        assertEq(opinionToken.balanceOf(address(feeCollector), OPINION_ID), 0);
    }

    function test_WithdrawSingleSide_revertsInsufficientLiquidity_crossSide() public {
        // lp1 has 1000 polyLp but pool has 0 Opinion
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);

        vm.prank(lp1);
        vm.expectRevert(); // InsufficientLiquidity
        pool.withdrawSingleSide(1000, SwapPool.Side.POLYMARKET, SwapPool.Side.OPINION);
    }

    function test_WithdrawSingleSide_revertsInsufficientLiquidity_sameSide() public {
        // lp1 and lp2 both deposit POLY, then swapper drains POLY
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        // Drain all poly via swap (opinion→poly)
        _fundAndApprove(swapper, 0, 5000);
        vm.prank(swapper);
        pool.swap(SwapPool.Side.OPINION, 990); // takes ~986 poly

        // lp1 tries same-side withdraw but poly balance is depleted
        vm.prank(lp1);
        vm.expectRevert();
        pool.withdrawSingleSide(1000, SwapPool.Side.POLYMARKET, SwapPool.Side.POLYMARKET);
    }

    function test_WithdrawSingleSide_revertsZeroAmount() public {
        vm.prank(lp1);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.withdrawSingleSide(0, SwapPool.Side.POLYMARKET, SwapPool.Side.POLYMARKET);
    }

    function test_WithdrawSingleSide_ratePreservedAfterSameSideWithdraw() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 1000);

        uint256 rateBefore = pool.exchangeRate();

        vm.prank(lp1);
        pool.withdrawSingleSide(500, SwapPool.Side.POLYMARKET, SwapPool.Side.POLYMARKET);

        assertEq(pool.exchangeRate(), rateBefore, "rate should be unchanged after same-side withdraw");
    }

    function test_WithdrawSingleSide_lpFeeRemainsInPool_crossSide() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.POLYMARKET, SwapPool.Side.OPINION);

        // LP fee stays in pool → remaining LPs (lp2) benefit
        // opinionBalance reduced by (actualOut + protocolFee) = 996 + 1 = 997
        // lpFee = 3 stays in opinionBalance
        assertEq(pool.opinionBalance(), 5000 - 997);

        // Rate should have increased slightly for remaining LP holders
        // (lp1's polyLp burned but pool still has their contribution minus fees)
        // Not strictly required but validate pool is consistent
        assertEq(pool.totalLpSupply(), opinionLp.totalSupply()); // only opinionLp remains
    }

    function test_WithdrawSingleSide_emitsSameSideEvent() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);

        vm.prank(lp1);
        vm.expectEmit(true, false, false, true);
        emit SwapPool.WithdrawnSingleSide(lp1, SwapPool.Side.POLYMARKET, SwapPool.Side.POLYMARKET, 1000, 1000, 0, 0);
        pool.withdrawSingleSide(1000, SwapPool.Side.POLYMARKET, SwapPool.Side.POLYMARKET);
    }

    function test_WithdrawSingleSide_emitsCrossSideEvent() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        vm.prank(lp1);
        vm.expectEmit(true, false, false, true);
        // actualOut=996, lpFee=3, protocolFee=1
        emit SwapPool.WithdrawnSingleSide(lp1, SwapPool.Side.POLYMARKET, SwapPool.Side.OPINION, 1000, 996, 3, 1);
        pool.withdrawSingleSide(1000, SwapPool.Side.POLYMARKET, SwapPool.Side.OPINION);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SwapPool — withdrawBothSides
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WithdrawBothSides_exactSplit() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        // lp1 has 5000 polyLp, grossOut = 5000 * 10000 / 10000 = 5000
        // split: 4000 same-side (POLY, free), 1000 cross-side (OPINION, fee)
        uint256 polyBefore   = polyToken.balanceOf(lp1, POLY_ID);
        uint256 opinionBefore = opinionToken.balanceOf(lp1, OPINION_ID);

        vm.prank(lp1);
        pool.withdrawBothSides(5000, SwapPool.Side.POLYMARKET, 8000);

        // Same-side: 4000 POLY, no fee
        assertEq(polyToken.balanceOf(lp1, POLY_ID), polyBefore + 4000);

        // Cross-side: 1000 Opinion minus fee
        // lpFee=3, protocolFee=1, actualOut=996
        assertEq(opinionToken.balanceOf(lp1, OPINION_ID), opinionBefore + 996);
        assertEq(opinionToken.balanceOf(address(feeCollector), OPINION_ID), 1);
    }

    function test_WithdrawBothSides_allSameSide_equivalentToSingleSide() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);

        uint256 polyBefore = polyToken.balanceOf(lp1, POLY_ID);

        vm.prank(lp1);
        pool.withdrawBothSides(1000, SwapPool.Side.POLYMARKET, 10000);

        assertEq(polyToken.balanceOf(lp1, POLY_ID), polyBefore + 1000);
        assertEq(polyLp.balanceOf(lp1), 0);
    }

    function test_WithdrawBothSides_resolved_crossSideFree() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        vm.prank(owner);
        factory.resolvePoolAndPausedDeposits(0);

        uint256 opinionBefore = opinionToken.balanceOf(lp1, OPINION_ID);

        vm.prank(lp1);
        pool.withdrawBothSides(5000, SwapPool.Side.POLYMARKET, 8000);

        // Cross-side resolved → no fee, full 1000 Opinion
        assertEq(opinionToken.balanceOf(lp1, OPINION_ID), opinionBefore + 1000);
        assertEq(opinionToken.balanceOf(address(feeCollector), OPINION_ID), 0);
    }

    function test_WithdrawBothSides_revertsInvalidSplit() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);

        vm.prank(lp1);
        vm.expectRevert(SwapPool.InvalidSplit.selector);
        // grossOut = 1000, but 600 + 600 = 1200 ≠ 1000
        pool.withdrawBothSides(1000, SwapPool.Side.POLYMARKET, 5000);
    }

    function test_WithdrawBothSides_revertsZeroAmount() public {
        vm.prank(lp1);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.withdrawBothSides(0, SwapPool.Side.POLYMARKET, 0);
    }

    function test_WithdrawBothSides_revertsInsufficientCrossSideLiquidity() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);
        // Pool has 0 Opinion — cross-side portion should fail

        vm.prank(lp1);
        vm.expectRevert(); // InsufficientLiquidity
        pool.withdrawBothSides(1000, SwapPool.Side.POLYMARKET, 50000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SwapPool — Swap
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Swap_polyToOpinion_basicFees() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        uint256 opinionBefore = opinionToken.balanceOf(swapper, OPINION_ID);

        vm.prank(swapper);
        uint256 amountOut = pool.swap(SwapPool.Side.POLYMARKET, 1000);

        // lpFee=3, protocolFee=1, amountOut=996
        assertEq(amountOut, 996);
        assertEq(opinionToken.balanceOf(swapper, OPINION_ID), opinionBefore + 996);
        assertEq(polyToken.balanceOf(address(feeCollector), POLY_ID), 1);
    }

    function test_Swap_opinionToPoly_basicFees() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        uint256 polyBefore = polyToken.balanceOf(swapper, POLY_ID);

        vm.prank(swapper);
        uint256 amountOut = pool.swap(SwapPool.Side.OPINION, 1000);

        assertEq(amountOut, 996);
        assertEq(polyToken.balanceOf(swapper, POLY_ID), polyBefore + 996);
        assertEq(opinionToken.balanceOf(address(feeCollector), OPINION_ID), 1);
    }

    function test_Swap_lpFeeAutoCompounds_noNewLpMinted() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        uint256 supplyBefore = pool.totalLpSupply();
        uint256 rateBefore   = pool.exchangeRate();

        vm.prank(swapper);
        pool.swap(SwapPool.Side.POLYMARKET, 1000);

        assertEq(pool.totalLpSupply(), supplyBefore, "LP supply should not change");
        assertGt(pool.exchangeRate(), rateBefore, "rate should increase from LP fee");
    }

    function test_Swap_feesUpdatePoolBalanceCorrectly() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.POLYMARKET, 1000);

        // fromSide POLY: +1000 deposited, -1 protocol fee out → net +999
        // toSide OPINION: -996 to swapper
        assertEq(pool.polymarketBalance(), 5000 + 999);
        assertEq(pool.opinionBalance(), 5000 - 996);
    }

    function test_Swap_revertsInsufficientLiquidity() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 100);

        vm.prank(swapper);
        vm.expectRevert();
        pool.swap(SwapPool.Side.POLYMARKET, 200);
    }

    function test_Swap_revertsZeroAmount() public {
        vm.prank(swapper);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.swap(SwapPool.Side.POLYMARKET, 0);
    }

    function test_Swap_revertsWhenPaused() public {
        vm.prank(owner);
        factory.setPoolSwapsPaused(0, true);

        vm.prank(swapper);
        vm.expectRevert(SwapPool.SwapsPaused.selector);
        pool.swap(SwapPool.Side.POLYMARKET, 100);
    }

    function test_Swap_emitsEvent() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        vm.prank(swapper);
        vm.expectEmit(true, false, false, true);
        emit SwapPool.Swapped(swapper, SwapPool.Side.POLYMARKET, 1000, 996, 3, 1);
        pool.swap(SwapPool.Side.POLYMARKET, 1000);
    }

    function test_Swap_zeroFee_fullAmountOut() public {
        vm.prank(owner);
        factory.setFees(0, 0);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        vm.prank(swapper);
        uint256 amountOut = pool.swap(SwapPool.Side.POLYMARKET, 1000);

        assertEq(amountOut, 1000);
    }

    function test_Swap_customFee_correctCalculation() public {
        vm.prank(owner);
        factory.setFees(100, 50); // 1% LP + 0.5% protocol

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        // lpFee = 5000 * 100 / 10000 = 50
        // protocolFee = 5000 * 50 / 10000 = 25
        // amountOut = 5000 - 50 - 25 = 4925
        vm.prank(swapper);
        uint256 amountOut = pool.swap(SwapPool.Side.POLYMARKET, 5000);

        assertEq(amountOut, 4925);
        assertEq(polyToken.balanceOf(address(feeCollector), POLY_ID), 25);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Exchange rate integrity
    // ═══════════════════════════════════════════════════════════════════════════

    function test_ExchangeRate_startsAtOne() public view {
        assertEq(pool.exchangeRate(), 1e18);
    }

    function test_ExchangeRate_unchangedAfterDeposit() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);
        assertEq(pool.exchangeRate(), 1e18);

        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 500);
        assertEq(pool.exchangeRate(), 1e18);
    }

    function test_ExchangeRate_increasesAfterSwapFee() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.POLYMARKET, 1000);

        assertGt(pool.exchangeRate(), 1e18);
    }

    function test_ExchangeRate_multipleSwapsIncreaseRate() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.POLYMARKET, 1000);
        uint256 rateAfterFirst = pool.exchangeRate();

        vm.prank(swapper);
        pool.swap(SwapPool.Side.OPINION, 1000);
        uint256 rateAfterSecond = pool.exchangeRate();

        assertGt(rateAfterSecond, rateAfterFirst);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Rescue functions
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Rescue_surplusPoolTokens() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);

        // Someone sends tokens directly to pool without depositing
        polyToken.mint(address(pool), POLY_ID, 50);

        // surplus = 50, tracked = 1000, actual = 1050
        vm.prank(owner);
        factory.rescuePoolTokens(0, SwapPool.Side.POLYMARKET, 50, owner);

        assertEq(polyToken.balanceOf(owner, POLY_ID), 50);
        assertEq(pool.polymarketBalance(), 1000); // tracked balance unchanged
    }

    function test_Rescue_revertsIfAmountExceedsSurplus() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);

        // No surplus — trying to rescue 1 should revert
        vm.prank(owner);
        vm.expectRevert(SwapPool.NothingToRescue.selector);
        factory.rescuePoolTokens(0, SwapPool.Side.POLYMARKET, 1, owner);
    }

    function test_Rescue_foreignERC1155() public {
        MockERC1155 foreign = new MockERC1155();
        foreign.mint(address(pool), 99, 500);

        vm.prank(owner);
        factory.rescuePoolERC1155(0, address(foreign), 99, 500, owner);

        assertEq(foreign.balanceOf(owner, 99), 500);
    }

    function test_Rescue_foreignERC1155_revertsOnPoolToken() public {
        vm.prank(owner);
        vm.expectRevert(SwapPool.CannotRescuePoolTokens.selector);
        factory.rescuePoolERC1155(0, address(polyToken), POLY_ID, 1, owner);
    }

    function test_Rescue_ETH() public {
        vm.deal(address(pool), 1 ether);
        uint256 balBefore = owner.balance;

        vm.prank(owner);
        factory.rescuePoolETH(0, payable(owner));

        assertEq(owner.balance, balBefore + 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Integration — full LP lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Integration_fullLpLifecycle_sameSideWithdraw() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.OPINION, 1000);

        assertEq(polyLp.balanceOf(lp1), 1000);
        assertEq(opinionLp.balanceOf(lp1), 1000);

        // Swap to accumulate fees
        vm.prank(swapper);
        pool.swap(SwapPool.Side.POLYMARKET, 1000);

        assertGt(pool.exchangeRate(), 1e18);

        // Withdraw each LP type same-side (free)
        uint256 polyBefore   = polyToken.balanceOf(lp1, POLY_ID);
        uint256 opBefore     = opinionToken.balanceOf(lp1, OPINION_ID);
        uint256 totalShares  = pool.totalShares();
        uint256 totalLpSup   = pool.totalLpSupply();

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.POLYMARKET, SwapPool.Side.POLYMARKET);

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.OPINION, SwapPool.Side.OPINION);

        // lp1 should have received shares proportional to their LP holding
        uint256 expectedShares = (2000 * totalShares) / totalLpSup;
        uint256 actualReceived = (polyToken.balanceOf(lp1, POLY_ID) - polyBefore)
                               + (opinionToken.balanceOf(lp1, OPINION_ID) - opBefore);

        assertApproxEqAbs(actualReceived, expectedShares, 2, "received shares should match expected");
    }

    function test_Integration_twoLps_proportionalFeeShare() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 1000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 1000);

        assertEq(polyLp.balanceOf(lp1),    opinionLp.balanceOf(lp2));
        assertEq(pool.totalLpSupply(), 2000);

        // Multiple swaps to accumulate fees
        for (uint256 i; i < 5; i++) {
            vm.prank(swapper);
            pool.swap(SwapPool.Side.POLYMARKET, 500);
            vm.prank(swapper);
            pool.swap(SwapPool.Side.OPINION, 500);
        }

        // Both hold 1000 / 2000 = 50% of pool each
        uint256 lp1Shares = (polyLp.balanceOf(lp1) * pool.totalShares()) / pool.totalLpSupply();
        uint256 lp2Shares = (opinionLp.balanceOf(lp2) * pool.totalShares()) / pool.totalLpSupply();
        assertEq(lp1Shares, lp2Shares, "both LPs should have equal share");
    }

    function test_Integration_crossSideBypassPrevented() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        uint256 opinionBefore = opinionToken.balanceOf(lp1, OPINION_ID);

        // Cross-side withdraw must pay fee — not free like a same-side withdraw
        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.POLYMARKET, SwapPool.Side.OPINION);

        uint256 received = opinionToken.balanceOf(lp1, OPINION_ID) - opinionBefore;

        // Must be less than 1000 (fee was charged)
        assertLt(received, 1000, "cross-side withdraw must not bypass fee");
        assertEq(received, 996);
    }

    function test_Integration_resolvedPool_crossSideFreeForBoth() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.POLYMARKET, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.OPINION, 5000);

        vm.prank(owner);
        factory.resolvePoolAndPausedDeposits(0);

        uint256 opinionBefore = opinionToken.balanceOf(lp1, OPINION_ID);
        uint256 polyBefore    = polyToken.balanceOf(lp2, POLY_ID);

        // Both LP types can cross-side withdraw for free after resolution
        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.POLYMARKET, SwapPool.Side.OPINION);
        vm.prank(lp2);
        pool.withdrawSingleSide(1000, SwapPool.Side.OPINION, SwapPool.Side.POLYMARKET);

        assertEq(opinionToken.balanceOf(lp1, OPINION_ID), opinionBefore + 1000);
        assertEq(polyToken.balanceOf(lp2, POLY_ID), polyBefore + 1000);
        assertEq(opinionToken.balanceOf(address(feeCollector), OPINION_ID), 0);
        assertEq(polyToken.balanceOf(address(feeCollector), POLY_ID), 0);
    }
}