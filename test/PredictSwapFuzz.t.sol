// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FeeCollector.sol";
import "../src/LPToken.sol";
import "../src/PoolFactory.sol";
import "../src/SwapPool.sol";
import "./MockERC1155.sol";

contract PredictSwapFuzzTest is Test {

    address owner    = makeAddr("owner");
    address operator = makeAddr("operator");
    address lp1      = makeAddr("lp1");
    address lp2      = makeAddr("lp2");
    address swapper  = makeAddr("swapper");

    uint256 constant MKT_A_ID = 100;
    uint256 constant MKT_B_ID = 200;

    uint256 constant LP_FEE    = 30;
    uint256 constant PROTO_FEE = 10;
    uint256 constant TOTAL_FEE = 40;
    uint256 constant FEE_DEN   = 10_000;

    MockERC1155  mktA;
    MockERC1155  mktB;
    FeeCollector collector;
    PoolFactory  factory;
    SwapPool     pool;
    LPToken      lpA;
    LPToken      lpB;
    uint256      lpIdA;
    uint256      lpIdB;

    function setUp() public {
        mktA = new MockERC1155();
        mktB = new MockERC1155();

        vm.startPrank(owner);
        collector = new FeeCollector(owner);
        factory = new PoolFactory(
            address(mktA), address(mktB), address(collector),
            operator, owner, "A", "B", "A-LP", "B-LP"
        );
        vm.stopPrank();

        lpA = factory.marketALpToken();
        lpB = factory.marketBLpToken();

        vm.prank(operator);
        uint256 pid = factory.createPool(
            PoolFactory.MarketConfig(MKT_A_ID, 18),
            PoolFactory.MarketConfig(MKT_B_ID, 18),
            LP_FEE, PROTO_FEE, "fuzz"
        );
        pool = SwapPool(payable(factory.getPool(pid).swapPool));
        lpIdA = factory.getPool(pid).marketALpTokenId;
        lpIdB = factory.getPool(pid).marketBLpTokenId;

        _fund(lp1);
        _fund(lp2);
        _fund(swapper);
    }

    function _fund(address u) internal {
        uint256 big = 100_000_000 ether;
        mktA.mint(u, MKT_A_ID, big);
        mktB.mint(u, MKT_B_ID, big);
        vm.startPrank(u);
        mktA.setApprovalForAll(address(pool), true);
        mktB.setApprovalForAll(address(pool), true);
        vm.stopPrank();
    }

    function _invariant() internal view {
        uint256 physA = pool.physicalBalanceNorm(SwapPool.Side.MARKET_A);
        uint256 physB = pool.physicalBalanceNorm(SwapPool.Side.MARKET_B);
        assertEq(pool.aSideValue() + pool.bSideValue(), physA + physB, "conservation");
    }

    // ─── Stateless Fuzz: Deposit ──────────────────────────────────────────────

    function testFuzz_Deposit_FirstDeposit1to1(uint256 amount) public {
        amount = bound(amount, 1, 10_000_000 ether);
        vm.prank(lp1);
        uint256 minted = pool.deposit(SwapPool.Side.MARKET_A, amount);
        assertEq(minted, amount, "first deposit 1:1");
        assertEq(pool.aSideValue(), amount);
        _invariant();
    }

    function testFuzz_Deposit_SecondDepositorGetsProportionalLP(uint256 dep1, uint256 dep2) public {
        dep1 = bound(dep1, 1 ether, 50_000_000 ether);
        dep2 = bound(dep2, 1 ether, 50_000_000 ether);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, dep1);

        uint256 supplyBefore = lpA.totalSupply(lpIdA);
        uint256 valueBefore = pool.aSideValue();

        vm.prank(lp2);
        uint256 minted = pool.deposit(SwapPool.Side.MARKET_A, dep2);

        uint256 expected = (dep2 * supplyBefore) / valueBefore;
        assertEq(minted, expected, "proportional mint");
        _invariant();
    }

    function testFuzz_Deposit_BothSidesIndependent(uint256 depA, uint256 depB) public {
        depA = bound(depA, 1, 50_000_000 ether);
        depB = bound(depB, 1, 50_000_000 ether);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, depA);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, depB);

        assertEq(pool.aSideValue(), depA);
        assertEq(pool.bSideValue(), depB);
        _invariant();
    }

    // ─── Stateless Fuzz: Fee Math ─────────────────────────────────────────────

    function testFuzz_FeeCalc_CeilingRound(uint256 amount) public view {
        amount = bound(amount, 1, 100_000_000 ether);

        uint256 totalBps = LP_FEE + PROTO_FEE;
        uint256 expectedTotal = (amount * totalBps + FEE_DEN - 1) / FEE_DEN;

        (uint256 lpFee, uint256 protocolFee) = _computeFees(amount);
        uint256 actualTotal = lpFee + protocolFee;

        assertEq(actualTotal, expectedTotal, "total fee matches ceiling formula");
        assertLe(actualTotal, amount, "fee <= amount");
        assertTrue(lpFee >= protocolFee, "lp fee >= proto fee (30 vs 10 bps)");
    }

    function testFuzz_FeeCalc_SplitConsistency(uint256 amount) public view {
        amount = bound(amount, 1, 100_000_000 ether);
        (uint256 lpFee, uint256 protocolFee) = _computeFees(amount);
        uint256 payout = amount - lpFee - protocolFee;
        assertEq(payout + lpFee + protocolFee, amount, "amount = payout + fees");
    }

    function _computeFees(uint256 normAmount) internal pure returns (uint256 lpFee, uint256 protocolFee) {
        uint256 totalBps = LP_FEE + PROTO_FEE;
        if (totalBps == 0 || normAmount == 0) return (0, 0);
        uint256 totalFee = (normAmount * totalBps + FEE_DEN - 1) / FEE_DEN;
        protocolFee = PROTO_FEE > 0 ? (totalFee * PROTO_FEE) / totalBps : 0;
        lpFee = totalFee - protocolFee;
    }

    // ─── Stateless Fuzz: Swap ─────────────────────────────────────────────────

    function testFuzz_Swap_OutputCorrectness(uint256 liq, uint256 swapAmt) public {
        liq     = bound(liq, 10 ether, 10_000_000 ether);
        swapAmt = bound(swapAmt, 0.01 ether, liq / 2);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, liq);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, liq);

        (uint256 lpFee, uint256 protocolFee) = _computeFees(swapAmt);
        uint256 expectedOut = swapAmt - lpFee - protocolFee;

        vm.prank(swapper);
        uint256 out = pool.swap(SwapPool.Side.MARKET_A, swapAmt);

        assertEq(out, expectedOut, "output matches expected");
        _invariant();
    }

    function testFuzz_Swap_DrainedSideRateGrows(uint256 liq, uint256 swapAmt) public {
        liq     = bound(liq, 10 ether, 10_000_000 ether);
        swapAmt = bound(swapAmt, 1 ether, liq / 2);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, liq);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, liq);

        uint256 bRateBefore = pool.marketBRate();
        uint256 aRateBefore = pool.marketARate();

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, swapAmt);

        assertGe(pool.marketBRate(), bRateBefore, "drained side rate non-decreasing");
        assertEq(pool.marketARate(), aRateBefore, "non-drained side unchanged");
    }

    function testFuzz_Swap_SymmetricFees(uint256 liq, uint256 swapAmt) public {
        liq     = bound(liq, 10 ether, 10_000_000 ether);
        swapAmt = bound(swapAmt, 0.01 ether, liq / 2);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, liq);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, liq);

        uint256 snap = vm.snapshotState();

        vm.prank(swapper);
        uint256 outAtoB = pool.swap(SwapPool.Side.MARKET_A, swapAmt);

        vm.revertToState(snap);

        vm.prank(swapper);
        uint256 outBtoA = pool.swap(SwapPool.Side.MARKET_B, swapAmt);

        assertEq(outAtoB, outBtoA, "symmetric fees for equal decimals");
    }

    // ─── Stateless Fuzz: Withdrawal ───────────────────────────────────────────

    function testFuzz_Withdrawal_SameSideMaturedNoFee(uint256 dep) public {
        dep = bound(dep, 1 ether, 10_000_000 ether);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, dep);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, dep);

        skip(25 hours);

        uint256 lpBal = lpA.balanceOf(lp1, lpIdA);
        uint256 balBefore = mktA.balanceOf(lp1, MKT_A_ID);
        uint256 fcBefore = mktA.balanceOf(address(collector), MKT_A_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, lpBal, SwapPool.Side.MARKET_A);

        assertEq(mktA.balanceOf(lp1, MKT_A_ID) - balBefore, dep, "full claim matured");
        assertEq(mktA.balanceOf(address(collector), MKT_A_ID), fcBefore, "no fee matured");
        _invariant();
    }

    function testFuzz_Withdrawal_DepositWithdrawNoProfit(uint256 dep) public {
        dep = bound(dep, 1 ether, 10_000_000 ether);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, dep);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, dep);

        uint256 lpBal = lpA.balanceOf(lp1, lpIdA);
        uint256 balBefore = mktA.balanceOf(lp1, MKT_A_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, lpBal, SwapPool.Side.MARKET_A);

        uint256 returned = mktA.balanceOf(lp1, MKT_A_ID) - balBefore;
        assertLe(returned, dep, "cannot profit from deposit+withdraw without swaps");
        _invariant();
    }

    function testFuzz_Withdrawal_CrossSideUnresolvedPaysFullFee(uint256 dep) public {
        dep = bound(dep, 1 ether, 10_000_000 ether);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, dep);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, dep);

        skip(25 hours);

        uint256 lpBal = lpA.balanceOf(lp1, lpIdA);
        uint256 bBefore = mktB.balanceOf(lp1, MKT_B_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_B, lpBal, SwapPool.Side.MARKET_A);

        uint256 returned = mktB.balanceOf(lp1, MKT_B_ID) - bBefore;
        uint256 expectedMax = (dep * (FEE_DEN - TOTAL_FEE)) / FEE_DEN;
        assertLe(returned, expectedMax + 1, "cross-side pays fee");
        assertGt(returned, 0, "non-zero return");
        _invariant();
    }

    // ─── Stateless Fuzz: WithdrawProRata ──────────────────────────────────────

    function testFuzz_ProRata_NeverOverpays(uint256 depA, uint256 depB, uint256 swapAmt) public {
        depA = bound(depA, 10 ether, 10_000_000 ether);
        depB = bound(depB, 10 ether, 10_000_000 ether);
        uint256 maxSwap = depB < depA ? depB : depA;
        swapAmt = bound(swapAmt, 0.01 ether, maxSwap / 2);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, depA);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, depB);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, swapAmt);

        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);

        uint256 lpBal = lpA.balanceOf(lp1, lpIdA);
        uint256 aBefore = mktA.balanceOf(lp1, MKT_A_ID);
        uint256 bBefore = mktB.balanceOf(lp1, MKT_B_ID);

        vm.prank(lp1);
        pool.withdrawProRata(lpBal, SwapPool.Side.MARKET_A);

        uint256 gotA = mktA.balanceOf(lp1, MKT_A_ID) - aBefore;
        uint256 gotB = mktB.balanceOf(lp1, MKT_B_ID) - bBefore;

        assertLe(gotA + gotB, depA + swapAmt, "pro-rata total <= deposited + possible swap gains");
        _invariant();
    }

    function testFuzz_ProRata_NoFees(uint256 dep) public {
        dep = bound(dep, 1 ether, 10_000_000 ether);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, dep);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, dep);

        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);

        uint256 fcABefore = mktA.balanceOf(address(collector), MKT_A_ID);
        uint256 fcBBefore = mktB.balanceOf(address(collector), MKT_B_ID);

        uint256 lpBal = lpA.balanceOf(lp1, lpIdA);
        vm.prank(lp1);
        pool.withdrawProRata(lpBal, SwapPool.Side.MARKET_A);

        assertEq(mktA.balanceOf(address(collector), MKT_A_ID), fcABefore, "no A fee");
        assertEq(mktB.balanceOf(address(collector), MKT_B_ID), fcBBefore, "no B fee");
        _invariant();
    }

    // ─── Stateless Fuzz: JIT Lock ─────────────────────────────────────────────

    function testFuzz_Lock_WeightedAvgTimestamp(uint256 amt1, uint256 amt2, uint256 gap) public {
        amt1 = bound(amt1, 1 ether, 10_000_000 ether);
        amt2 = bound(amt2, 1 ether, 10_000_000 ether);
        gap  = bound(gap, 1, 23 hours);

        uint256 t0 = 1_000_000;
        vm.warp(t0);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, amt1);

        vm.warp(t0 + gap);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, amt2);

        (, uint256 ts) = lpA.freshDeposit(lp1, lpIdA);

        assertGe(ts, t0, "weighted avg >= first deposit time");
        assertLe(ts, t0 + gap, "weighted avg <= second deposit time");
    }

    function testFuzz_Lock_MaturationAfter24h(uint256 amt, uint256 extraTime) public {
        amt = bound(amt, 1 ether, 10_000_000 ether);
        extraTime = bound(extraTime, 1, 365 days);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, amt);

        assertTrue(lpA.isLocked(lp1, lpIdA), "locked initially");

        skip(24 hours + extraTime);

        assertFalse(lpA.isLocked(lp1, lpIdA), "matured after 24h");
        assertEq(lpA.lockedAmount(lp1, lpIdA), 0, "locked amount = 0");
    }

    function testFuzz_Lock_TransferAlwaysFresh(uint256 dep, uint256 transferAmt) public {
        dep = bound(dep, 2 ether, 10_000_000 ether);
        transferAmt = bound(transferAmt, 1, dep);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, dep);

        skip(25 hours);
        assertEq(lpA.lockedAmount(lp1, lpIdA), 0, "matured");

        uint256 transferTime = block.timestamp;
        vm.prank(lp1);
        lpA.safeTransferFrom(lp1, lp2, lpIdA, transferAmt, "");

        assertEq(lpA.lockedAmount(lp2, lpIdA), transferAmt, "transfer always fresh");
        (, uint256 ts) = lpA.freshDeposit(lp2, lpIdA);
        assertEq(ts, transferTime, "fresh timestamp = transfer time");
    }

    // ─── Stateless Fuzz: Multi-operation Conservation ─────────────────────────

    function testFuzz_Conservation_DepositSwapWithdraw(
        uint256 depA, uint256 depB, uint256 swapAmt, bool swapDirection
    ) public {
        depA = bound(depA, 10 ether, 10_000_000 ether);
        depB = bound(depB, 10 ether, 10_000_000 ether);
        uint256 maxSwap = depB < depA ? depB : depA;
        swapAmt = bound(swapAmt, 0.01 ether, maxSwap / 2);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, depA);
        _invariant();

        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, depB);
        _invariant();

        SwapPool.Side fromSide = swapDirection ? SwapPool.Side.MARKET_A : SwapPool.Side.MARKET_B;
        vm.prank(swapper);
        pool.swap(fromSide, swapAmt);
        _invariant();

        skip(25 hours);

        uint256 lpBal = lpA.balanceOf(lp1, lpIdA);
        if (lpBal > 0) {
            uint256 shares = (lpBal * pool.marketARate()) / 1e18;
            uint256 physA = pool.physicalBalanceNorm(SwapPool.Side.MARKET_A);
            if (shares <= physA) {
                vm.prank(lp1);
                pool.withdrawal(SwapPool.Side.MARKET_A, lpBal, SwapPool.Side.MARKET_A);
                _invariant();
            }
        }
    }

    // ─── Stateless Fuzz: Rate Monotonicity ────────────────────────────────────

    function testFuzz_Rate_NeverDecreasesFromSwaps(
        uint256 liq, uint256 swap1, uint256 swap2
    ) public {
        liq   = bound(liq, 100 ether, 10_000_000 ether);
        swap1 = bound(swap1, 0.01 ether, liq / 4);
        swap2 = bound(swap2, 0.01 ether, liq / 4);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, liq);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, liq);

        uint256 rateA0 = pool.marketARate();
        uint256 rateB0 = pool.marketBRate();

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, swap1);

        uint256 rateA1 = pool.marketARate();
        uint256 rateB1 = pool.marketBRate();
        assertEq(rateA1, rateA0, "A rate unchanged after A-to-B swap");
        assertGe(rateB1, rateB0, "B rate grew after A-to-B swap");

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_B, swap2);

        assertGe(pool.marketARate(), rateA1, "A rate grew after B-to-A swap");
        assertEq(pool.marketBRate(), rateB1, "B rate unchanged after B-to-A swap");
    }

    // ─── Stateless Fuzz: Full Drain & Refill ──────────────────────────────────

    function testFuzz_FlushResidual_FullExit(uint256 depA, uint256 depB, uint256 swapAmt) public {
        depA = bound(depA, 1 ether, 1_000_000 ether);
        depB = bound(depB, 1 ether, 1_000_000 ether);
        uint256 maxSwap = depB < depA ? depB : depA;
        swapAmt = bound(swapAmt, 0.01 ether, maxSwap / 3);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, depA);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, depB);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, swapAmt);

        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);

        uint256 lpBalA = lpA.balanceOf(lp1, lpIdA);
        uint256 lpBalB = lpB.balanceOf(lp2, lpIdB);

        vm.prank(lp1);
        pool.withdrawProRata(lpBalA, SwapPool.Side.MARKET_A);
        vm.prank(lp2);
        pool.withdrawProRata(lpBalB, SwapPool.Side.MARKET_B);

        assertEq(lpA.totalSupply(lpIdA), 0, "A supply zero");
        assertEq(lpB.totalSupply(lpIdB), 0, "B supply zero");
        assertEq(pool.aSideValue(), 0, "aSideValue zero");
        assertEq(pool.bSideValue(), 0, "bSideValue zero");
        assertEq(mktA.balanceOf(address(pool), MKT_A_ID), 0, "pool A clean");
        assertEq(mktB.balanceOf(address(pool), MKT_B_ID), 0, "pool B clean");
    }
}
